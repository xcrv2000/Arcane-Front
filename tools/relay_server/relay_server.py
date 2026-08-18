#!/usr/bin/env python3
# V0.4 (P3) 奥术前线联机中继服务器
# 设计约束（按 V0.4 计划）：
#   - 纯 Python 标准库 asyncio / json / random / string，无第三方依赖
#   - 仅承担：房间码创建/加入、双方命令中继、对局结果持久化
#   - 不运行战斗逻辑、不校验命令内容、不保存房间状态到磁盘（重启清空）
#   - 协议：TCP 文本行（JSON Lines，每包以 \n 分隔）
#
# 协议包（client → server）：
#   {"type": "CREATE_ROOM"}
#       → {"type":"ROOM_CREATED","room_code":"XXXX","my_side":"host"}
#   {"type": "JOIN_ROOM", "room_code": "XXXX"}
#       → {"type":"ROOM_JOINED","room_code":"XXXX","my_side":"guest"}
#       或 {"type":"ERROR","message":"..."}
#   {"type": "READY", "ready": true, "deck": ["c1",...,"c6"]}
#       当双方均 ready：服务器广播
#       {"type":"START","seed":12345,"host_deck":[...],"guest_deck":[...]}
#   {"type": "COMMAND","payload": {...command dict...}}
#       → 对端原样转发：{"type":"COMMAND","payload":{...}}
#   {"type": "RESULT","winner":"host_or_guest_or_draw","room_code":"XXXX"}
#       → 持久化到 match_results.jsonl，广播给双方
#
# 断线通知：任一方断开 → 对端收到 {"type":"PEER_DISCONNECT"}
#
# 启动：
#   python relay_server.py --host 0.0.0.0 --port 8765
#
# 生产部署建议：
#   systemd 守护 + 裸 IP + PORT，firewalld/iptables 放行端口，无需 HTTPS/域名（V0.4 约定）
from __future__ import annotations

import argparse
import asyncio
import json
import random
import string
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

MATCH_RESULTS_PATH = Path(__file__).parent / "match_results.jsonl"

# 房间码字母表：去掉易混字符 0/O/1/I
ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
ROOM_CODE_LENGTH = 4
DISCONNECT_GRACE_SECONDS = 30.0
HEARTBEAT_TIMEOUT_SECONDS = 10.0
HEARTBEAT_SWEEP_INTERVAL = 5.0
CLIENT_ID_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CLIENT_ID_LENGTH = 16


def gen_room_code(existing_codes: set) -> str:
    while True:
        code = "".join(random.choices(ROOM_CODE_ALPHABET, k=ROOM_CODE_LENGTH))
        if code not in existing_codes:
            return code


def gen_client_id() -> str:
    return "".join(random.choices(CLIENT_ID_ALPHABET, k=CLIENT_ID_LENGTH))


class Client:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, server: "RelayServer"):
        self.reader = reader
        self.writer = writer
        self.server = server
        self.addr = writer.get_extra_info("peername")
        self.room_code: Optional[str] = None
        self.my_side: Optional[str] = None  # "host" / "guest"
        self.ready: bool = False
        self.deck: List[str] = []
        self._disconnect_task: Optional[asyncio.Task] = None
        # 断线重连：客户端身份令牌与最近活跃时间
        self.client_id: str = ""
        self.last_seen: float = time.time()
        # 已被新连接替换（重连成功）后，旧连接的 EOF 不应再清理房间槽位
        self.replaced: bool = False

    async def send(self, obj: dict) -> None:
        """发送 JSON Lines 包。失败时静默（不递归触发 disconnect，避免超时协程中连锁断开）"""
        try:
            data = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
            self.writer.write(data)
            await self.writer.drain()
        except Exception:
            # 只关闭本地写端，不触发 _disconnect_client（断开逻辑由 reader.at_eof 统一触发）
            try:
                self.writer.close()
            except Exception:
                pass

    async def handle_message(self, msg: dict) -> None:
        t = str(msg.get("type", ""))
        if t == "CREATE_ROOM":
            await self.server.handle_create(self, str(msg.get("client_id", "")))
        elif t == "JOIN_ROOM":
            code = str(msg.get("room_code", "")).strip().upper()
            await self.server.handle_join(self, code, str(msg.get("client_id", "")))
        elif t == "READY":
            self.ready = bool(msg.get("ready", False))
            self.deck = list(msg.get("deck", []))
            await self.server.handle_ready_tick(self)
        elif t == "REMATCH":
            await self.server.handle_rematch(self, msg)
        elif t == "LEAVE_ROOM":
            await self.server.handle_leave_room(self)
        elif t == "HEARTBEAT":
            pass  # last_seen 已在 _client_loop 每次收到合法消息时刷新
        elif t == "RESYNC":
            await self.server.handle_resync(self, msg)
        elif t == "COMMAND":
            await self.server.handle_command(self, dict(msg.get("payload", {})))
        elif t == "RESULT":
            await self.server.handle_result(self, msg)
        else:
            await self.send({"type": "ERROR", "message": f"unknown type {t!r}"})


class Room:
    def __init__(self, code: str, host: Client):
        self.code = code
        self.host: Client = host
        self.guest: Optional[Client] = None
        self.started: bool = False
        self.seed: int = 0
        self.created_at = time.time()
        # 存储双方牌组（即使客户端断线重连，房间仍保留牌组用于再战/重开）
        self.host_deck: List[str] = []
        self.guest_deck: List[str] = []
        # 断线重连：槽位为空时仍保留原客户端令牌，用于重连认领
        self.host_client_id: str = host.client_id
        self.guest_client_id: str = ""
        # 断线超时任务引用（重连时可取消）
        self.disconnect_task: Optional[asyncio.Task] = None
        # desync 重同步：记录请求的目标 tick 与双方都能恢复的 base_tick，并防止重复广播
        self.resync_tick: Optional[int] = None
        self.resync_base_tick: Optional[int] = None
        self.resync_pending: bool = False
        # 命令日志：存储本局所有命令，供断线重连/desync 重同步回放恢复战场状态
        self.command_log: List[dict] = []
        # 命令日志索引：(tick, side) -> command_log 下标，用于 O(1) 收敛最终命令
        self.command_log_index: Dict[Tuple[int, str], int] = {}

    def peers(self, me: Client) -> List[Client]:
        out: List[Client] = []
        if self.host is not None and self.host is not me:
            out.append(self.host)
        if self.guest is not None and self.guest is not me:
            out.append(self.guest)
        return out

    def all_ready(self) -> bool:
        return (
            self.host is not None
            and self.guest is not None
            and self.host.ready
            and self.guest.ready
        )


class RelayServer:
    def __init__(self):
        self.rooms: Dict[str, Room] = {}
        self.clients: List[Client] = []
        self._lock = asyncio.Lock()

    async def handle_create(self, c: Client, client_id: str = "") -> None:
        async with self._lock:
            if c.room_code is not None:
                await c.send({"type": "ERROR", "message": "already in a room"})
                return
            c.client_id = client_id.strip() if client_id.strip() else gen_client_id()
            code = gen_room_code(set(self.rooms.keys()))
            room = Room(code, c)
            self.rooms[code] = room
            c.room_code = code
            c.my_side = "host"
            c.ready = False
            c.deck = []
        await c.send({"type": "ROOM_CREATED", "room_code": code, "my_side": "host", "client_id": c.client_id})

    async def handle_join(self, c: Client, code: str, client_id: str = "") -> None:
        if not code:
            await c.send({"type": "ERROR", "message": "room_code required"})
            return
        async with self._lock:
            room = self.rooms.get(code)
            if room is None:
                await c.send({"type": "ERROR", "message": "room not found"})
                return
            if c.room_code is not None:
                await c.send({"type": "ERROR", "message": "already in a room"})
                return
            c.client_id = client_id.strip() if client_id.strip() else gen_client_id()

            # 断线重连认领：同 token 可替换仍占位的旧连接，或在槽位为空时重进同一房间
            joining_side: Optional[str] = None
            old_client: Optional[Client] = None
            was_reconnect: bool = False
            if room.host is not None and room.host is not c and room.host.client_id == c.client_id:
                old_client = room.host
                room.host = c
                joining_side = "host"
                was_reconnect = True
            elif room.host is None and room.host_client_id == c.client_id:
                room.host = c
                joining_side = "host"
                was_reconnect = True
            elif room.guest is not None and room.guest is not c and room.guest.client_id == c.client_id:
                old_client = room.guest
                room.guest = c
                joining_side = "guest"
                was_reconnect = True
            elif room.guest is None and room.guest_client_id == c.client_id:
                room.guest = c
                joining_side = "guest"
                was_reconnect = True
            elif room.host is None:
                room.host = c
                joining_side = "host"
            elif room.guest is None:
                room.guest = c
                joining_side = "guest"
            else:
                await c.send({"type": "ERROR", "message": "room full"})
                return

            if old_client is not None:
                # 旧连接已被新连接替换，后续 EOF 不应再清理房间槽位
                old_client.replaced = True
                old_client.room_code = None
                old_client.my_side = None
                try:
                    old_client.writer.close()
                except Exception:
                    pass

            c.room_code = code
            c.my_side = joining_side
            c.ready = False
            c.deck = []
            if joining_side == "host":
                room.host_client_id = c.client_id
            else:
                room.guest_client_id = c.client_id

            # 取消断线超时任务（重连时）
            if room.disconnect_task is not None and not room.disconnect_task.done():
                room.disconnect_task.cancel()
                room.disconnect_task = None
            was_started = room.started
            saved_host_deck = list(room.host_deck)
            saved_guest_deck = list(room.guest_deck)
            saved_commands = list(room.command_log)
            saved_seed = room.seed
            # 断线重连只回放“双方都已发出命令”的安全 tick，避免把某一方预发的未来 NO_OP 当成已执行命令。
            resume_commands = list(saved_commands)
            resume_target_tick = 0
            if was_started and saved_commands:
                side_ticks = {"player": set(), "bot": set()}
                for cmd in saved_commands:
                    if not isinstance(cmd, dict):
                        continue
                    s = str(cmd.get("side", ""))
                    t = int(cmd.get("tick", 0))
                    if s in side_ticks and t > 0:
                        side_ticks[s].add(t)
                common_ticks = side_ticks["player"] & side_ticks["bot"]
                if common_ticks:
                    resume_target_tick = max(common_ticks)
                    resume_commands = [
                        cmd for cmd in saved_commands
                        if isinstance(cmd, dict) and int(cmd.get("tick", 0)) <= resume_target_tick
                    ]
            # 对端（仍在连接中的一方）
            peer = room.guest if joining_side == "host" else room.host
        if was_started and peer is not None:
            # 战斗中断线后重连：发送 RESUME_BATTLE 恢复战场
            # 重连方获得命令日志回放恢复状态；对端只需信号恢复
            if joining_side == "host":
                # 主机重连：主机获得 commands 回放，客机只需恢复
                resume_pkt_host = {
                    "type": "RESUME_BATTLE",
                    "seed": saved_seed,
                    "my_side": "host",
                    "my_deck": saved_host_deck,
                    "peer_deck": saved_guest_deck,
                    "target_tick": resume_target_tick,
                    "commands": resume_commands,
                }
                await c.send(resume_pkt_host)
                await peer.send({"type": "RESUME_BATTLE"})
            else:
                # 客机重连：客机获得 commands 回放，主机只需恢复
                resume_pkt_guest = {
                    "type": "RESUME_BATTLE",
                    "seed": saved_seed,
                    "my_side": "guest",
                    "my_deck": saved_guest_deck,
                    "peer_deck": saved_host_deck,
                    "target_tick": resume_target_tick,
                    "commands": resume_commands,
                }
                await c.send(resume_pkt_guest)
                await peer.send({"type": "RESUME_BATTLE"})
        elif was_started and peer is None:
            # 双方都断线（不应发生，房间应已销毁），按普通加入处理
            await c.send({"type": "ROOM_JOINED", "room_code": code, "my_side": joining_side, "client_id": c.client_id})
        else:
            # 普通加入/未开始对局的房间
            await c.send({"type": "ROOM_JOINED", "room_code": code, "my_side": joining_side, "client_id": c.client_id})
            if peer is not None:
                await peer.send({"type": "PEER_JOINED"})

    async def handle_ready_tick(self, c: Client) -> None:
        if not c.room_code:
            await c.send({"type": "ERROR", "message": "not in a room"})
            return
        room = self.rooms.get(c.room_code)
        if not room:
            return
        # 存储牌组到 Room（断线重连后仍可用）
        if c.my_side == "host":
            room.host_deck = list(c.deck)
        else:
            room.guest_deck = list(c.deck)
        # 先把一方的 ready 状态告诉对端（便于房间等待页显示）
        for peer in room.peers(c):
            await peer.send({"type": "PEER_READY", "ready": c.ready, "side": c.my_side})
        if room.all_ready() and not room.started:
            room.started = True
            room.resync_tick = None
            room.resync_base_tick = None
            room.resync_pending = False
            # 清空命令日志（新对局开始）
            room.command_log.clear()
            room.command_log_index.clear()
            # 服务器下发共享种子 + 双方牌组
            room.seed = random.randint(1, 2_000_000_000)
            start_pkt_host = {
                "type": "START",
                "seed": room.seed,
                "my_side": "host",
                "my_deck": room.host.deck,
                "peer_deck": room.guest.deck if room.guest else [],
            }
            start_pkt_guest = {
                "type": "START",
                "seed": room.seed,
                "my_side": "guest",
                "my_deck": room.guest.deck if room.guest else [],
                "peer_deck": room.host.deck,
            }
            await room.host.send(start_pkt_host)
            if room.guest:
                await room.guest.send(start_pkt_guest)

    async def handle_command(self, c: Client, payload: dict) -> None:
        if not c.room_code:
            return
        room = self.rooms.get(c.room_code)
        if not room:
            return
        # —— V0.5 弱网：识别网络层包装类型 ——
        net_type = str(payload.get("_net_type", ""))
        # (1) REQUEST_COMMANDS：请求方希望补全 [from_tick, to_tick] 范围的命令
        #      服务器直接用 command_log 命中后回发 COMMANDS_REPLY，不转发给对端（避免流量放大）
        if net_type == "REQUEST_COMMANDS":
            from_tick = int(payload.get("from_tick", 0))
            to_tick = int(payload.get("to_tick", 0))
            side_filter = str(payload.get("side", ""))
            matched: List[dict] = []
            if from_tick <= to_tick and from_tick >= 0:
                for entry in room.command_log:
                    # 跳过网络层包装（只匹配真实战斗命令，避免重复嵌套）
                    entry_net = str(entry.get("_net_type", "")) if isinstance(entry, dict) else ""
                    if entry_net:
                        # 如果历史里记录的是 COMMAND_BATCH 包装，拆出里面的子命令再筛选
                        if entry_net == "COMMAND_BATCH":
                            for sub in entry.get("commands", []) or []:
                                if self._cmd_in_range(sub, from_tick, to_tick, side_filter):
                                    matched.append(sub)
                        continue
                    if self._cmd_in_range(entry, from_tick, to_tick, side_filter):
                        matched.append(entry)
            reply = {
                "_net_type": "COMMANDS_REPLY",
                "from_tick": from_tick,
                "to_tick": to_tick,
                "side": side_filter,
                "commands": matched,
            }
            await c.send({"type": "COMMAND", "payload": reply})
            return
        # (2) COMMANDS_REPLY：客户端互相发送的应答（理论上服务器已自己答，此路径极少触发）
        #     原样转发给对端即可
        if net_type == "COMMANDS_REPLY":
            for peer in room.peers(c):
                await peer.send({"type": "COMMAND", "payload": payload})
            return
        # (3) COMMAND_BATCH（内含冗余历史）或单条战斗命令：
        #     先把"真实战斗命令"按 tick+side 收敛为最终命令写入 command_log（供断线重连回放用）
        #     再整个 payload 原样转发给对端（保留冗余结构，对端解包后自动去重）
        if net_type == "COMMAND_BATCH":
            # 把 batch 内部子命令按到达顺序记录；同 tick+side 的 PLAY_CARD 会覆盖旧 PLAY_CARD，
            # NO_OP 不会覆盖 PLAY_CARD，确保日志反映最终输入
            inner_cmds = payload.get("commands", []) or []
            for sub in inner_cmds:
                self._record_command_log(room, sub)
        else:
            self._record_command_log(room, payload)
        # 原样转发给对端（保留冗余结构，抗抖动冗余在接收端生效）
        for peer in room.peers(c):
            await peer.send({"type": "COMMAND", "payload": payload})

    @staticmethod
    def _cmd_in_range(cmd, from_tick: int, to_tick: int, side_filter: str) -> bool:
        """判断一条战斗命令是否落在 [from_tick, to_tick] 且 side 匹配。"""
        if not isinstance(cmd, dict):
            return False
        if "_net_type" in cmd:
            return False
        t = int(cmd.get("tick", -1))
        if t < from_tick or t > to_tick:
            return False
        if side_filter:
            s = str(cmd.get("side", ""))
            # 服务器里 host=PLAYER / guest=BOT；但命令里用的是"player"/"bot"
            # 这里 side_filter 来自客户端的阵营名，直接比对即可（客户端发的是 "player"/"bot"）
            if s != side_filter:
                return False
        return True

    @staticmethod
    def _cmd_log_key(cmd) -> tuple:
        """生成命令在 command_log 中的去重 key：(tick, side, type, 补充字段)。"""
        if not isinstance(cmd, dict):
            return ("_invalid",)
        t = int(cmd.get("tick", 0))
        s = str(cmd.get("side", ""))
        typ = str(cmd.get("type", ""))
        if typ == "play_card":
            return (t, s, typ, str(cmd.get("card_id", "")))
        if typ == "checksum":
            return (t, s, typ, int(cmd.get("checksum", 0)))
        # no_op 或其它：tick+side+type 即可唯一
        return (t, s, typ)

    @staticmethod
    def _command_log_has(room, key: tuple) -> bool:
        """检查 room.command_log 中是否已存在同 key 命令（去重，防止冗余写入）。"""
        # 只检查最近 256 条（O(N) 足够；避免整表扫描）
        start = max(0, len(room.command_log) - 512)
        for i in range(start, len(room.command_log)):
            entry = room.command_log[i]
            if isinstance(entry, dict) and "_net_type" not in entry:
                if RelayServer._cmd_log_key(entry) == key:
                    return True
        return False

    @staticmethod
    def _record_command_log(room: Room, cmd) -> None:
        """把一条真实战斗命令按 tick+side 收敛写入 command_log。

        - 只记录 play_card / no_op（checksum 不参与重放，不写入）
        - 同 tick+side 的 NO_OP 不会覆盖 PLAY_CARD（与客户端 enqueue 去重一致）
        - 同 tick+side 的 PLAY_CARD 会覆盖旧 PLAY_CARD，保证重放使用最终输入
        """
        if not isinstance(cmd, dict) or "_net_type" in cmd:
            return
        typ = str(cmd.get("type", ""))
        if typ not in ("play_card", "no_op"):
            return
        t = int(cmd.get("tick", 0))
        s = str(cmd.get("side", ""))
        if t <= 0 or s == "":
            return
        key = (t, s)
        idx = room.command_log_index.get(key)
        if idx is not None and 0 <= idx < len(room.command_log):
            entry = room.command_log[idx]
            if isinstance(entry, dict) and "_net_type" not in entry:
                et = str(entry.get("type", ""))
                if typ == "no_op" and et == "play_card":
                    return  # 已有真实出牌，迟到的 NO_OP 不覆盖
                room.command_log[idx] = cmd
                return
        room.command_log.append(cmd)
        room.command_log_index[key] = len(room.command_log) - 1

    async def handle_rematch(self, c: Client, msg: dict) -> None:
        """Issue1: 玩家点击"再战"时通知对端"""
        if not c.room_code:
            return
        room = self.rooms.get(c.room_code)
        if not room:
            return
        # 存储牌组并重置 ready
        c.ready = False
        c.deck = list(msg.get("deck", []))
        if c.my_side == "host":
            room.host_deck = list(c.deck)
        else:
            room.guest_deck = list(c.deck)
        # 通知对端"对方申请了再战"
        for peer in room.peers(c):
            await peer.send({"type": "PEER_REMATCH"})

    async def handle_leave_room(self, c: Client) -> None:
        """Issue2: 玩家主动退出房间（区别于断线）"""
        if not c.room_code:
            return
        leaver_side = c.my_side
        async with self._lock:
            room = self.rooms.get(c.room_code)
            if not room:
                return
            peer = None
            if leaver_side == "host":
                peer = room.guest
                # 房主退出 → 房间解散
                self.rooms.pop(room.code, None)
            else:
                peer = room.host
                # 客机退出 → 移除客机，房间保留
                room.guest = None
                room.started = False
                room.guest_deck = []
            c.room_code = None
            c.my_side = None
            c.ready = False
        # 通知对端"对方退出了房间"
        if peer is not None:
            try:
                await peer.send({"type": "PEER_LEFT", "who": leaver_side})
            except Exception:
                pass

    async def handle_result(self, c: Client, msg: dict) -> None:
        if not c.room_code:
            return
        room = self.rooms.get(c.room_code)
        if not room:
            return
        winner = str(msg.get("winner", ""))
        code = str(msg.get("room_code", room.code))
        # 持久化（优先使用 Room 存储的牌组，断线后也有数据）
        record = {
            "ts": int(time.time()),
            "room_code": code,
            "winner": winner,
            "seed": room.seed if room else 0,
            "host_deck": room.host_deck if room else [],
            "guest_deck": room.guest_deck if room else [],
            "reporter_side": c.my_side,
        }
        try:
            with MATCH_RESULTS_PATH.open("a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
        except Exception as e:
            print(f"[warn] persist failed: {e}", file=sys.stderr)
        # 广播 RESULT 给双方
        result_pkt = {"type": "RESULT", "room_code": code, "winner": winner}
        await room.host.send(result_pkt)
        if room.guest:
            await room.guest.send(result_pkt)
        # 重置房间 started 与双方 ready 状态，支持"再战"：
        # 双方回到 ROOM_WAIT 重新点准备后，服务器能再次下发 START
        room.started = False
        room.resync_tick = None
        room.resync_base_tick = None
        room.resync_pending = False
        room.command_log.clear()
        room.command_log_index.clear()
        if room.host is not None:
            room.host.ready = False
        if room.guest is not None:
            room.guest.ready = False

    async def handle_resync(self, c: Client, msg: dict) -> None:
        """desync 重同步：收集双方请求的目标 tick，稍后统一广播命令日志。"""
        if not c.room_code:
            return
        room = self.rooms.get(c.room_code)
        if not room or not room.started:
            return
        tick = max(1, int(msg.get("tick", 0)))
        base_tick = max(0, int(msg.get("base_tick", 0)))
        should_launch = False
        async with self._lock:
            if room.resync_tick is None or tick < room.resync_tick:
                room.resync_tick = tick
            # base_tick 取更小（更老、更安全）的值：双方都必须有该检查点快照
            if room.resync_base_tick is None or base_tick < room.resync_base_tick:
                room.resync_base_tick = base_tick
            if not room.resync_pending:
                room.resync_pending = True
                should_launch = True
        if should_launch:
            # 稍等片刻，尽量收集双方各自报告的 tick，取较小值作为共同恢复点；
            # 双方检测 desync 的时间接近，0.15s 已足够收集，尽量缩短恢复耗时。
            asyncio.create_task(self._broadcast_resync_after(room, 0.15))

    async def _broadcast_resync_after(self, room: Room, delay: float) -> None:
        await asyncio.sleep(delay)
        async with self._lock:
            if self.rooms.get(room.code) is not room:
                return
            if room.resync_tick is None:
                room.resync_pending = False
                return
            tick = room.resync_tick
            base_tick = room.resync_base_tick or 0
            room.resync_tick = None
            room.resync_base_tick = None
            room.resync_pending = False
            commands = [
                cmd for cmd in room.command_log
                if isinstance(cmd, dict)
                and int(cmd.get("tick", 0)) <= tick
                and int(cmd.get("tick", 0)) > base_tick
            ]
            seed = room.seed
            host_deck = list(room.host_deck)
            guest_deck = list(room.guest_deck)
            host = room.host
            guest = room.guest
        if host is not None:
            await host.send({
                "type": "RESYNC_DATA",
                "target_tick": tick,
                "base_tick": base_tick,
                "seed": seed,
                "my_side": "host",
                "my_deck": host_deck,
                "peer_deck": guest_deck,
                "commands": commands,
            })
        if guest is not None:
            await guest.send({
                "type": "RESYNC_DATA",
                "target_tick": tick,
                "base_tick": base_tick,
                "seed": seed,
                "my_side": "guest",
                "my_deck": guest_deck,
                "peer_deck": host_deck,
                "commands": commands,
            })

    async def _disconnect_client(self, c: Client, reason: str = "") -> None:
        async with self._lock:
            if c in self.clients:
                self.clients.remove(c)
            # 已被重连替换的旧连接：不清理房间槽位，避免把新连接顶掉
            if c.replaced:
                try:
                    c.writer.close()
                except Exception:
                    pass
                return
            room = self.rooms.get(c.room_code) if c.room_code else None

            if room:
                # 只有当前槽位仍指向该连接时才清理；若已被新连接替换则上面已返回
                is_current_slot = (room.host is c) or (room.guest is c)
                if not is_current_slot:
                    try:
                        c.writer.close()
                    except Exception:
                        pass
                    return
                # 30秒超时判负（V0.4约定：超时未重连则断线方负）
                if c.my_side == "host":
                    room.host = None
                    losing_side = "host"
                else:
                    room.guest = None
                    losing_side = "guest"
                # 通知对端
                peer = None
                if c.my_side == "host" and room.guest:
                    peer = room.guest
                elif c.my_side == "guest" and room.host:
                    peer = room.host
                if peer is not None:
                    room.disconnect_task = asyncio.create_task(
                        self._broadcast_disconnect_with_timeout(
                            peer, room, losing_side, DISCONNECT_GRACE_SECONDS
                        )
                    )
                # 若双方都离开则销毁房间
                if room.host is None and room.guest is None:
                    self.rooms.pop(room.code, None)
        try:
            c.writer.close()
        except Exception:
            pass

    async def _broadcast_disconnect_with_timeout(
        self,
        peer: Client,
        room: Room,
        losing_side: str,
        timeout_sec: float,
    ) -> None:
        """V0.4 断线策略：先通知对端暂停 + 倒计时等待，超时判负。
        注意：断线者如果在 timeout_sec 内重连（JOIN_ROOM补位），本任务会被 cancel。
        【鲁棒性】整个协程包最外层 try/except，防止任何异常冒泡到事件循环导致服务器崩溃。
        """
        try:
            try:
                await peer.send({"type": "PEER_DISCONNECT", "grace_seconds": timeout_sec})
            except Exception:
                return
            await asyncio.sleep(timeout_sec)
            # 检查是否仍在同一房间且对端没回来
            async with self._lock:
                still = self.rooms.get(room.code)
                if still is not room:
                    return
                lost_came_back = (losing_side == "host" and room.host is not None) or (
                    losing_side == "guest" and room.guest is not None
                )
                if lost_came_back:
                    return
                winner_side = "guest" if losing_side == "host" else "host"
                # 持久化结果 + 广播
                record = {
                    "ts": int(time.time()),
                    "room_code": room.code,
                    "winner": winner_side,
                    "seed": room.seed,
                    "host_deck": room.host_deck,
                    "guest_deck": room.guest_deck,
                    "reporter_side": "server_timeout",
                    "reason": "disconnect_timeout",
                    "disconnected": losing_side,
                }
                try:
                    with MATCH_RESULTS_PATH.open("a", encoding="utf-8") as f:
                        f.write(json.dumps(record, ensure_ascii=False) + "\n")
                except Exception:
                    pass
                timeout_pkt = {
                    "type": "OPPONENT_DISCONNECTED_WIN",
                    "winner": winner_side,
                    "room_code": room.code,
                }
                if room.host and winner_side == "host":
                    try:
                        await room.host.send(timeout_pkt)
                    except Exception:
                        pass
                if room.guest and winner_side == "guest":
                    try:
                        await room.guest.send(timeout_pkt)
                    except Exception:
                        pass
                # 重置 started，避免超时后客机重连触发 RESUME_BATTLE
                room.started = False
                room.disconnect_task = None
        except asyncio.CancelledError:
            # 断线者在超时之前成功重连 → 正常cancel，忽略
            raise
        except Exception as e:
            print(f"[server] _broadcast_disconnect_with_timeout 异常: {e!r}", file=sys.stderr)
            try:
                room.disconnect_task = None
            except Exception:
                pass

    async def _client_loop(self, c: Client) -> None:
        try:
            while True:
                line = await c.reader.readline()
                if not line:
                    break
                c.last_seen = time.time()
                try:
                    msg = json.loads(line.decode("utf-8").strip())
                except Exception:
                    await c.send({"type": "ERROR", "message": "invalid json"})
                    continue
                if not isinstance(msg, dict):
                    await c.send({"type": "ERROR", "message": "json object required"})
                    continue
                await c.handle_message(msg)
        except Exception as e:
            print(f"[client {c.addr}] loop err: {e}", file=sys.stderr)
        finally:
            await self._disconnect_client(c, reason="loop_end")

    async def client_connected(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        c = Client(reader, writer, self)
        async with self._lock:
            self.clients.append(c)
        await self._client_loop(c)

    async def heartbeat_sweep(self) -> None:
        """周期清理心跳超时的客户端，让对端尽快收到 PEER_DISCONNECT。"""
        while True:
            await asyncio.sleep(HEARTBEAT_SWEEP_INTERVAL)
            now = time.time()
            stale = [
                c for c in list(self.clients)
                if now - c.last_seen > HEARTBEAT_TIMEOUT_SECONDS
            ]
            for c in stale:
                await self._disconnect_client(c, reason="heartbeat_timeout")


async def main() -> None:
    parser = argparse.ArgumentParser(description="Arcane-Front V0.4 relay server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = RelayServer()
    srv = await asyncio.start_server(server.client_connected, host=args.host, port=args.port)
    asyncio.create_task(server.heartbeat_sweep())
    MATCH_RESULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    print(
        f"[Arcane-Front relay] listening on {args.host}:{args.port} ; results -> {MATCH_RESULTS_PATH}",
        flush=True,
    )
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("[Arcane-Front relay] stopped by user")

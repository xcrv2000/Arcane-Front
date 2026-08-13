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


def gen_room_code(existing_codes: set) -> str:
    while True:
        code = "".join(random.choices(ROOM_CODE_ALPHABET, k=ROOM_CODE_LENGTH))
        if code not in existing_codes:
            return code


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

    async def send(self, obj: dict) -> None:
        try:
            data = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
            self.writer.write(data)
            await self.writer.drain()
        except Exception:
            await self.server._disconnect_client(self, reason="send_fail")

    async def handle_message(self, msg: dict) -> None:
        t = str(msg.get("type", ""))
        if t == "CREATE_ROOM":
            await self.server.handle_create(self)
        elif t == "JOIN_ROOM":
            code = str(msg.get("room_code", "")).strip().upper()
            await self.server.handle_join(self, code)
        elif t == "READY":
            self.ready = bool(msg.get("ready", False))
            self.deck = list(msg.get("deck", []))
            await self.server.handle_ready_tick(self)
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

    def peers(self, me: Client) -> List[Client]:
        out = []
        if self.host is not me:
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

    async def handle_create(self, c: Client) -> None:
        async with self._lock:
            if c.room_code is not None:
                await c.send({"type": "ERROR", "message": "already in a room"})
                return
            code = gen_room_code(set(self.rooms.keys()))
            room = Room(code, c)
            self.rooms[code] = room
            c.room_code = code
            c.my_side = "host"
            c.ready = False
            c.deck = []
        await c.send({"type": "ROOM_CREATED", "room_code": code, "my_side": "host"})

    async def handle_join(self, c: Client, code: str) -> None:
        if not code:
            await c.send({"type": "ERROR", "message": "room_code required"})
            return
        async with self._lock:
            room = self.rooms.get(code)
            if room is None:
                await c.send({"type": "ERROR", "message": "room not found"})
                return
            if room.guest is not None:
                await c.send({"type": "ERROR", "message": "room full"})
                return
            if c.room_code is not None:
                await c.send({"type": "ERROR", "message": "already in a room"})
                return
            room.guest = c
            c.room_code = code
            c.my_side = "guest"
            c.ready = False
            c.deck = []
        await c.send({"type": "ROOM_JOINED", "room_code": code, "my_side": "guest"})
        # 通知 host 有客人加入
        await room.host.send({"type": "PEER_JOINED"})

    async def handle_ready_tick(self, c: Client) -> None:
        if not c.room_code:
            await c.send({"type": "ERROR", "message": "not in a room"})
            return
        room = self.rooms.get(c.room_code)
        if not room:
            return
        # 先把一方的 ready 状态告诉对端（便于房间等待页显示）
        for peer in room.peers(c):
            await peer.send({"type": "PEER_READY", "ready": c.ready, "side": c.my_side})
        if room.all_ready() and not room.started:
            room.started = True
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
        for peer in room.peers(c):
            await peer.send({"type": "COMMAND", "payload": payload})

    async def handle_result(self, c: Client, msg: dict) -> None:
        if not c.room_code:
            return
        room = self.rooms.get(c.room_code)
        if not room:
            return
        winner = str(msg.get("winner", ""))
        code = str(msg.get("room_code", room.code))
        # 持久化
        record = {
            "ts": int(time.time()),
            "room_code": code,
            "winner": winner,
            "seed": room.seed if room else 0,
            "host_deck": room.host.deck if room else [],
            "guest_deck": (room.guest.deck if room and room.guest else []),
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

    async def _disconnect_client(self, c: Client, reason: str = "") -> None:
        # 取消之前的延时广播（如果有）
        if c._disconnect_task is not None and not c._disconnect_task.done():
            c._disconnect_task.cancel()
        async with self._lock:
            if c in self.clients:
                self.clients.remove(c)
            room = self.rooms.get(c.room_code) if c.room_code else None

            if room:
                # 30秒超时判负（V0.4约定：不做完整重连）
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
                    asyncio.create_task(
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
        这里简化为对端先收到 PEER_DISCONNECT，经过 timeout_sec 后若断线者未重连则
        对端收到 OPPONENT_WON（对手掉线判负，判断线者输）。
        注意：V0.4 不做重连恢复，所以 30s 后直接判断线方负。
        """
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
                "host_deck": room.host.deck if room.host else [],
                "guest_deck": (room.guest.deck if room.guest else []),
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

    async def _client_loop(self, c: Client) -> None:
        try:
            while True:
                line = await c.reader.readline()
                if not line:
                    break
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


async def main() -> None:
    parser = argparse.ArgumentParser(description="Arcane-Front V0.4 relay server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = RelayServer()
    srv = await asyncio.start_server(server.client_connected, host=args.host, port=args.port)
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

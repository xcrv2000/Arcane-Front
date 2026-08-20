# V0.45 ENet 协议编解码层。
# 职责：
#   - 定义 ENet raw packet 的包首字节、通道、二进制字段布局。
#   - 把 Godot 侧命令 Dictionary 编码为 ENet 二进制包，或把服务器下发的包解码回 Dictionary。
#   - 房间/准备/结果等低频控制包继续使用 0x00 + JSON；战斗高频命令使用 0x01/0x02。
#
# 包格式：
#   0x00 JSON 控制包        : 0x00 + UTF-8 JSON
#   0x01 PLAY_CARD          : tick:int32, side:u8, id_len:u8, card_id:bytes, x_fp:int32, y_fp:int32
#   0x02 CHECKSUM           : tick:int32, side:u8, checksum:u32
#   0x03 PING/PONG          : time_ms:int64
# 多字节整数统一小端序（PackedByteArray 原生小端）。
extends RefCounted

const Config = preload("res://scripts/config/game_config.gd")
const Command = preload("res://scripts/networking/command.gd")

# 包首字节
const PACKET_JSON: int = 0x00
const PACKET_PLAY_CARD: int = 0x01
const PACKET_CHECKSUM: int = 0x02
const PACKET_PING: int = 0x03

# side 编码：与模拟器阵营字符串互转
const SIDE_PLAYER: int = 0
const SIDE_BOT: int = 1


static func side_to_u8(side: String) -> int:
	if side == Config.PLAYER:
		return SIDE_PLAYER
	if side == Config.BOT:
		return SIDE_BOT
	# 未知阵营按 player 处理（协议侧仅用于日志/转发，实际校验由模拟器负责）
	return SIDE_PLAYER


static func side_from_u8(value: int) -> String:
	if int(value) == SIDE_BOT:
		return Config.BOT
	return Config.PLAYER


# —— 编码 ——

static func encode_json(obj: Dictionary) -> PackedByteArray:
	var json_bytes: PackedByteArray = JSON.stringify(obj).to_utf8_buffer()
	var data := PackedByteArray([PACKET_JSON])
	data.append_array(json_bytes)
	return data


static func encode_play_card(cmd: Dictionary) -> PackedByteArray:
	var tick: int = int(cmd.get("tick", 0))
	var side: String = String(cmd.get("side", Config.PLAYER))
	var card_id: String = String(cmd.get("card_id", ""))
	var card_bytes: PackedByteArray = card_id.to_utf8_buffer()
	var x_fp: int = int(cmd.get("target_x_fp", 0))
	var y_fp: int = int(cmd.get("target_y_fp", 0))
	var id_len: int = min(255, card_bytes.size())
	var data := PackedByteArray()
	data.resize(1 + 4 + 1 + 1 + id_len + 4 + 4)
	data[0] = PACKET_PLAY_CARD
	data.encode_s32(1, tick)
	data[5] = side_to_u8(side)
	data[6] = id_len
	for i in range(id_len):
		data[7 + i] = card_bytes[i]
	data.encode_s32(7 + id_len, x_fp)
	data.encode_s32(11 + id_len, y_fp)
	return data


static func encode_checksum(cmd: Dictionary) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(10)
	data[0] = PACKET_CHECKSUM
	data.encode_s32(1, int(cmd.get("tick", 0)))
	data[5] = side_to_u8(String(cmd.get("side", Config.PLAYER)))
	data.encode_u32(6, int(cmd.get("checksum", 0)))
	return data


static func encode_ping(time_ms: int) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(9)
	data[0] = PACKET_PING
	data.encode_s64(1, time_ms)
	return data


# —— 解码 ——

# 返回 Dictionary：
#   {"kind":"json", "payload": Dictionary, "channel": int}
#   {"kind":"command", "payload": Dictionary, "channel": int}
#   {"kind":"ping", "time_ms": int, "channel": int}
#   {"kind":"invalid", "reason": String, "channel": int}
static func parse_packet(data: PackedByteArray, channel: int = Config.ENET_CHANNEL_RELIABLE) -> Dictionary:
	if data.size() < 1:
		return {"kind": "invalid", "reason": "empty packet", "channel": channel}
	var first: int = int(data[0])
	match first:
		PACKET_JSON:
			var text: String = data.slice(1).get_string_from_utf8()
			var parsed: Variant = JSON.parse_string(text)
			if typeof(parsed) != TYPE_DICTIONARY:
				return {"kind": "invalid", "reason": "json payload not object", "channel": channel}
			return {"kind": "json", "payload": Dictionary(parsed), "channel": channel}
		PACKET_PLAY_CARD:
			if data.size() < 10:
				return {"kind": "invalid", "reason": "play_card too short", "channel": channel}
			var tick: int = data.decode_s32(1)
			var side: String = side_from_u8(int(data[5]))
			var id_len: int = int(data[6])
			if data.size() < 7 + id_len + 8:
				return {"kind": "invalid", "reason": "play_card id truncated", "channel": channel}
			var card_id: String = data.slice(7, 7 + id_len).get_string_from_utf8()
			var x_fp: int = data.decode_s32(7 + id_len)
			var y_fp: int = data.decode_s32(11 + id_len)
			var cmd: Dictionary = Command.play_card_command_fp(tick, side, card_id, x_fp, y_fp)
			return {"kind": "command", "payload": cmd, "channel": channel}
		PACKET_CHECKSUM:
			if data.size() < 10:
				return {"kind": "invalid", "reason": "checksum too short", "channel": channel}
			var tick: int = data.decode_s32(1)
			var side: String = side_from_u8(int(data[5]))
			var checksum: int = int(data.decode_u32(6))
			var cmd: Dictionary = Command.checksum_command(tick, side, checksum)
			return {"kind": "command", "payload": cmd, "channel": channel}
		PACKET_PING:
			if data.size() < 9:
				return {"kind": "invalid", "reason": "ping too short", "channel": channel}
			return {"kind": "ping", "time_ms": int(data.decode_s64(1)), "channel": channel}
		_:
			return {"kind": "invalid", "reason": "unknown packet type", "channel": channel}

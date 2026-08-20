# V0.45 ENet 联机中继服务器

Go + [codecat/go-enet](https://github.com/codecat/go-enet) 实现，替代 V0.4 的 Python TCP 中继。

## 依赖

- Go 1.22+
- C 编译器（cgo）
- Linux：`libenet-dev`（Debian/Ubuntu 安装：`sudo apt install libenet-dev`）
- Windows：go-enet 自带 enet 库，无需额外安装；但需要可用的 C 工具链（如 MSYS2/MinGW）。

## 构建

```bash
cd tools/relay_server_enet
go mod tidy
go build -o relay_server_enet main.go
```

## 运行

```bash
# 开发：本机 UDP 8765
./relay_server_enet --host 0.0.0.0 --port 8765
# 生产：公网服务器
./relay_server_enet --host 0.0.0.0 --port 8765 --results /opt/relay-server/match_results.jsonl
```

- 默认监听 UDP `8765`（不是 TCP）。
- 结果文件默认写到运行目录 `match_results.jsonl`，字段与 V0.4 保持一致。
- 服务器只保存房间状态、真实 `PLAY_CARD`/`CHECKSUM` 命令日志和对局结果，不运行战斗逻辑。
- 旧 TCP 中继 `tools/relay_server/relay_server.py` 保留为 V0.4 回退/对照。

## 协议要点

- 通道 0：可靠有序（房间控制、PLAY_CARD、CHECKSUM、RESULT、RESYNC、RESUME）。
- 通道 1：不可靠（HEARTBEAT/PING）。
- 包首字节：`0x00`=JSON 控制、`0x01`=PLAY_CARD、`0x02`=CHECKSUM、`0x03`=PING。
- 线上不记录/不转发 NO_OP；缺省即 NO_OP。

// V0.45 ENet 联机中继服务器（Go + codecat/go-enet）。
//
// 职责：
//   - 监听 UDP 端口（默认 8765），使用 ENet 可靠/不可靠通道承载自定义协议。
//   - 房间码创建/加入、READY/START、真实命令中继与命令日志、RESYNC/RESUME、结果持久化。
//   - 不运行战斗逻辑、不保存完整战场状态。
//
// 协议：
//   0x00 + JSON  : 房间控制包
//   0x01         二进制 PLAY_CARD
//   0x02         二进制 CHECKSUM
//   0x03         二进制 PING/PONG
//
// 构建：
//   go mod tidy
//   go build -o relay_server_enet main.go
//   ./relay_server_enet --host 0.0.0.0 --port 8765
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/codecat/go-enet"
)

const (
	packetJSON       byte = 0x00
	packetPlayCard   byte = 0x01
	packetChecksum   byte = 0x02
	packetPing       byte = 0x03

	channelReliable   uint8 = 0
	channelUnreliable uint8 = 1

	roomCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	roomCodeLength   = 4
	clientIDAlphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	clientIDLength   = 16

	disconnectGraceSeconds = 30.0
	heartbeatTimeout       = 10.0
	heartbeatSweepInterval = 5.0
)

var matchResultsPath = filepath.Join("match_results.jsonl")

type Client struct {
	ID       string
	Peer     enet.Peer
	Room     *Room
	Side     string // "host" / "guest"
	Ready    bool
	Deck     []string
	LastSeen time.Time
	// 断线重连状态
	Disconnected   bool
	DisconnectedAt time.Time
	Replaced       bool
}

type Room struct {
	Code     string
	Host     *Client
	Guest    *Client
	Seed     int64
	Started  bool
	Commands map[string]map[string]interface{} // "tick|side" -> command dict
}

type Server struct {
	clients map[string]*Client
	rooms   map[string]*Room
}

func main() {
	hostFlag := flag.String("host", "0.0.0.0", "listen host")
	portFlag := flag.Int("port", 8765, "listen UDP port")
	resultsFlag := flag.String("results", "", "path to match_results.jsonl (default: match_results.jsonl)")
	flag.Parse()
	if *resultsFlag != "" {
		matchResultsPath = *resultsFlag
	}

	enet.Initialize()
	defer enet.Deinitialize()

	port := uint16(*portFlag)
	serverHost, err := enet.NewHost(enet.NewListenAddress(port), 256, 2, 0, 0)
	if err != nil {
		log.Fatalf("无法创建 ENet host: %v", err)
	}
	defer serverHost.Destroy()

	s := &Server{
		clients: map[string]*Client{},
		rooms:   map[string]*Room{},
	}

	log.Printf("V0.45 ENet relay listening on %s:%d/udp", *hostFlag, port)
	lastSweep := time.Now()
	for {
		ev := serverHost.Service(1000)
		switch ev.GetType() {
		case enet.EventConnect:
			s.handleConnect(ev.GetPeer())
		case enet.EventDisconnect:
			s.handleDisconnect(ev.GetPeer())
		case enet.EventReceive:
			packet := ev.GetPacket()
			data := packet.GetData()
			packet.Destroy()
			s.handleReceive(ev.GetPeer(), ev.GetChannelID(), data)
		}

		if time.Since(lastSweep) >= heartbeatSweepInterval*time.Second {
			lastSweep = time.Now()
			s.sweep()
		}
	}
}

// ————— 基础工具 —————

func randomString(alphabet string, length int) string {
	b := make([]byte, length)
	for i := range b {
		b[i] = alphabet[rand.Intn(len(alphabet))]
	}
	return string(b)
}

func genRoomCode(existing map[string]*Room) string {
	for {
		code := randomString(roomCodeAlphabet, roomCodeLength)
		if _, ok := existing[code]; !ok {
			return code
		}
	}
}

func genClientID() string {
	return randomString(clientIDAlphabet, clientIDLength)
}

func (s *Server) attachPeer(peer enet.Peer) *Client {
	token := genClientID()
	c := &Client{
		ID:       token,
		Peer:     peer,
		LastSeen: time.Now(),
	}
	peer.SetData([]byte(token))
	s.clients[token] = c
	return c
}

func (s *Server) detachPeer(peer enet.Peer) *Client {
	token := string(peer.GetData())
	if token == "" {
		return nil
	}
	c := s.clients[token]
	if c != nil {
		delete(s.clients, token)
	}
	return c
}

// 把一条新连接挂到已有 client 上（重连认领）。
func (s *Server) reattachPeer(peer enet.Peer, existing *Client) {
	oldToken := string(peer.GetData())
	if oldToken != "" {
		delete(s.clients, oldToken)
	}
	existing.Peer = peer
	existing.LastSeen = time.Now()
	existing.Disconnected = false
	existing.DisconnectedAt = time.Time{}
	peer.SetData([]byte(existing.ID))
	s.clients[existing.ID] = existing
}

func (s *Server) sendJSON(peer enet.Peer, obj map[string]interface{}, channel uint8, reliable bool) error {
	raw, err := json.Marshal(obj)
	if err != nil {
		return err
	}
	data := append([]byte{packetJSON}, raw...)
	flags := enet.PacketFlags(0)
	if reliable {
		flags = enet.PacketFlagReliable
	}
	return peer.SendBytes(data, channel, flags)
}

func (s *Server) sendError(peer enet.Peer, message string) {
	_ = s.sendJSON(peer, map[string]interface{}{"type": "ERROR", "message": message}, channelReliable, true)
}

// ————— 连接事件 —————

func (s *Server) handleConnect(peer enet.Peer) {
	c := s.attachPeer(peer)
	log.Printf("client connected: %s (%s)", c.ID, peer.GetAddress().String())
}

func (s *Server) handleDisconnect(peer enet.Peer) {
	c := s.detachPeer(peer)
	if c == nil {
		return
	}
	if c.Room == nil {
		log.Printf("client disconnected outside room: %s", c.ID)
		return
	}
	log.Printf("client disconnected: %s room=%s side=%s", c.ID, c.Room.Code, c.Side)
	s.handleClientGone(c)
}

func (s *Server) handleClientGone(c *Client) {
	room := c.Room
	if room == nil {
		return
	}
	if room.Started {
		// 战斗中：保留槽位 30 秒等待重连；先通知对端。
		c.Disconnected = true
		c.DisconnectedAt = time.Now()
		other := room.Other(c)
		if other != nil && !other.Disconnected {
			_ = s.sendJSON(other.Peer, map[string]interface{}{
				"type":          "PEER_DISCONNECT",
				"grace_seconds": disconnectGraceSeconds,
			}, channelReliable, true)
		}
		return
	}
	// 未开战：直接移除，并通知对端。
	other := room.Other(c)
	if c.Side == "host" {
		room.Host = nil
		delete(s.rooms, room.Code)
	} else {
		room.Guest = nil
	}
	c.Room = nil
	if other != nil {
		_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "PEER_LEFT", "who": c.Side}, channelReliable, true)
	}
}

// ————— 接收事件 —————

func (s *Server) handleReceive(peer enet.Peer, channel uint8, data []byte) {
	token := string(peer.GetData())
	c := s.clients[token]
	if c == nil {
		return
	}
	c.LastSeen = time.Now()
	if len(data) == 0 {
		return
	}
	switch data[0] {
	case packetJSON:
		s.handleJSON(c, data[1:])
	case packetPlayCard, packetChecksum:
		s.handleBinaryCommand(c, data)
	case packetPing:
		// 应用层 RTT 采样：原样回 PONG（不可靠通道）。
		_ = peer.SendBytes(data, channelUnreliable, 0)
	default:
		s.sendError(peer, "unknown packet type")
	}
}

func (s *Server) handleJSON(c *Client, raw []byte) {
	var msg map[string]interface{}
	if err := json.Unmarshal(raw, &msg); err != nil {
		s.sendError(c.Peer, "invalid json")
		return
	}
	typ, _ := msg["type"].(string)
	switch typ {
	case "CREATE_ROOM":
		s.handleCreateRoom(c, msg)
	case "JOIN_ROOM":
		s.handleJoinRoom(c, msg)
	case "READY":
		s.handleReady(c, msg)
	case "HEARTBEAT":
		// last_seen 已在 handleReceive 更新
	case "COMMAND":
		s.handleCommandPayload(c, msg)
	case "RESYNC":
		s.handleResync(c, msg)
	case "RESULT":
		s.handleResult(c, msg)
	case "REMATCH":
		s.handleRematch(c)
	case "LEAVE_ROOM":
		s.handleLeaveRoom(c)
	default:
		s.sendError(c.Peer, "unknown type "+typ)
	}
}

// ————— 房间控制 —————

func (s *Server) handleCreateRoom(c *Client, msg map[string]interface{}) {
	if c.Room != nil {
		s.sendError(c.Peer, "already in room")
		return
	}
	code := genRoomCode(s.rooms)
	room := &Room{
		Code:     code,
		Commands: map[string]map[string]interface{}{},
	}
	room.Host = c
	c.Room = room
	c.Side = "host"
	c.Ready = false
	c.Deck = nil
	s.rooms[code] = room
	_ = s.sendJSON(c.Peer, map[string]interface{}{
		"type":      "ROOM_CREATED",
		"room_code": code,
		"my_side":   "host",
		"client_id": c.ID,
	}, channelReliable, true)
	log.Printf("room created: %s host=%s", code, c.ID)
}

func (s *Server) handleJoinRoom(c *Client, msg map[string]interface{}) {
	if c.Room != nil {
		s.sendError(c.Peer, "already in room")
		return
	}
	code, _ := msg["room_code"].(string)
	code = strings.ToUpper(strings.TrimSpace(code))
	room := s.rooms[code]
	if room == nil {
		s.sendError(c.Peer, "room not found")
		return
	}
	clientID, _ := msg["client_id"].(string)
	clientID = strings.TrimSpace(clientID)
	if clientID != "" {
		// 重连认领
		if room.Host != nil && room.Host.ID == clientID {
			s.reattachPeer(c.Peer, room.Host)
			c.Room = nil // 新临时 client 对象不再使用
			s.afterRejoin(room, room.Host)
			return
		}
		if room.Guest != nil && room.Guest.ID == clientID {
			s.reattachPeer(c.Peer, room.Guest)
			c.Room = nil
			s.afterRejoin(room, room.Guest)
			return
		}
	}
	if room.Guest != nil {
		s.sendError(c.Peer, "room full")
		return
	}
	room.Guest = c
	c.Room = room
	c.Side = "guest"
	c.Ready = false
	c.Deck = nil
	_ = s.sendJSON(c.Peer, map[string]interface{}{
		"type":      "ROOM_JOINED",
		"room_code": code,
		"my_side":   "guest",
		"client_id": c.ID,
	}, channelReliable, true)
	if room.Host != nil {
		_ = s.sendJSON(room.Host.Peer, map[string]interface{}{"type": "PEER_JOINED"}, channelReliable, true)
	}
	log.Printf("guest joined room: %s guest=%s", code, c.ID)
}

func (s *Server) afterRejoin(room *Room, reconnected *Client) {
	other := room.Other(reconnected)
	if other != nil && !other.Disconnected {
		_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "PEER_JOINED"}, channelReliable, true)
	}
	if room.Started {
		// 重连方收到完整尾部命令，对端收到无数据通知。
		cmds := room.CommandsBetween(0, 1<<30)
		_ = s.sendJSON(reconnected.Peer, s.resumePayload(room, reconnected, cmds), channelReliable, true)
		if other != nil {
			_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "RESUME_BATTLE", "target_tick": 0}, channelReliable, true)
		}
		log.Printf("rejoined started room: %s side=%s", room.Code, reconnected.Side)
	} else {
		_ = s.sendJSON(reconnected.Peer, map[string]interface{}{
			"type":      "ROOM_JOINED",
			"room_code": room.Code,
			"my_side":   reconnected.Side,
			"client_id": reconnected.ID,
		}, channelReliable, true)
	}
}

func (s *Server) handleReady(c *Client, msg map[string]interface{}) {
	if c.Room == nil {
		s.sendError(c.Peer, "not in room")
		return
	}
	ready, _ := msg["ready"].(bool)
	c.Ready = ready
	if deckRaw, ok := msg["deck"].([]interface{}); ok {
		deck := make([]string, 0, len(deckRaw))
		for _, v := range deckRaw {
			if s, ok := v.(string); ok {
				deck = append(deck, s)
			}
		}
		c.Deck = deck
	}
	room := c.Room
	other := room.Other(c)
	if other != nil {
		_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "PEER_READY", "side": c.Side, "ready": ready}, channelReliable, true)
	}
	if room.Host != nil && room.Guest != nil && room.Host.Ready && room.Guest.Ready && !room.Started {
		room.Started = true
		room.Seed = rand.Int63()
		room.Commands = map[string]map[string]interface{}{}
		_ = s.sendJSON(room.Host.Peer, s.startPayload(room, room.Host), channelReliable, true)
		_ = s.sendJSON(room.Guest.Peer, s.startPayload(room, room.Guest), channelReliable, true)
		log.Printf("room started: %s seed=%d", room.Code, room.Seed)
	}
}

func (s *Server) startPayload(room *Room, c *Client) map[string]interface{} {
	myDeck, peerDeck := decksFor(room, c)
	return map[string]interface{}{
		"type":      "START",
		"seed":      room.Seed,
		"my_side":   c.Side,
		"my_deck":   myDeck,
		"peer_deck": peerDeck,
	}
}

func (s *Server) resumePayload(room *Room, c *Client, cmds []map[string]interface{}) map[string]interface{} {
	myDeck, peerDeck := decksFor(room, c)
	if cmds == nil {
		cmds = []map[string]interface{}{}
	}
	return map[string]interface{}{
		"type":       "RESUME_BATTLE",
		"seed":       room.Seed,
		"my_side":    c.Side,
		"my_deck":    myDeck,
		"peer_deck":  peerDeck,
		"target_tick": 1 << 30,
		"commands":   cmds,
	}
}

func decksFor(room *Room, c *Client) ([]string, []string) {
	hostDeck := room.Host.Deck
	guestDeck := room.Guest.Deck
	if hostDeck == nil {
		hostDeck = []string{}
	}
	if guestDeck == nil {
		guestDeck = []string{}
	}
	if c.Side == "host" {
		return hostDeck, guestDeck
	}
	return guestDeck, hostDeck
}

// ————— 命令中继与日志 —————

func (s *Server) handleBinaryCommand(c *Client, data []byte) {
	room := c.Room
	if room == nil || !room.Started {
		return
	}
	cmd, ok := parseBinaryCommand(data)
	if !ok {
		return
	}
	s.logCommand(room, cmd)
	other := room.Other(c)
	if other != nil {
		_ = other.Peer.SendBytes(data, channelReliable, enet.PacketFlagReliable)
	}
}

func (s *Server) handleCommandPayload(c *Client, msg map[string]interface{}) {
	room := c.Room
	if room == nil {
		return
	}
	payload, ok := msg["payload"].(map[string]interface{})
	if !ok {
		return
	}
	netType, _ := payload["_net_type"].(string)
	if netType == "REQUEST_COMMANDS" {
		from, _ := payload["from_tick"].(float64)
		to, _ := payload["to_tick"].(float64)
		matched := room.CommandsBetween(int(from), int(to))
		reply := map[string]interface{}{
			"_net_type":  "COMMANDS_REPLY",
			"from_tick":  int(from),
			"to_tick":    int(to),
			"side":       payload["side"],
			"commands":   matched,
		}
		_ = s.sendJSON(c.Peer, map[string]interface{}{"type": "COMMAND", "payload": reply}, channelReliable, true)
		return
	}
	cmdType, _ := payload["type"].(string)
	if cmdType == "play_card" || cmdType == "checksum" {
		s.logCommand(room, payload)
		other := room.Other(c)
		if other != nil {
			_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "COMMAND", "payload": payload}, channelReliable, true)
		}
	}
}

func asInt(v interface{}) int {
	switch n := v.(type) {
	case int:
		return n
	case int32:
		return int(n)
	case float64:
		return int(n)
	case float32:
		return int(n)
	default:
		return 0
	}
}

func (s *Server) logCommand(room *Room, cmd map[string]interface{}) {
	tick := asInt(cmd["tick"])
	side, _ := cmd["side"].(string)
	key := fmt.Sprintf("%d|%s", tick, side)
	room.Commands[key] = cmd
}

func parseBinaryCommand(data []byte) (map[string]interface{}, bool) {
	if len(data) < 1 {
		return nil, false
	}
	switch data[0] {
	case packetPlayCard:
		if len(data) < 10 {
			return nil, false
		}
		tick := int32(binary.LittleEndian.Uint32(data[1:5]))
		side := "player"
		if data[5] == 1 {
			side = "bot"
		}
		idLen := int(data[6])
		if len(data) < 7+idLen+8 {
			return nil, false
		}
		cardID := string(data[7 : 7+idLen])
		x := int32(binary.LittleEndian.Uint32(data[7+idLen : 11+idLen]))
		y := int32(binary.LittleEndian.Uint32(data[11+idLen : 15+idLen]))
		return map[string]interface{}{
			"type":        "play_card",
			"tick":        int(tick),
			"side":        side,
			"card_id":     cardID,
			"target_x_fp": int(x),
			"target_y_fp": int(y),
		}, true
	case packetChecksum:
		if len(data) < 10 {
			return nil, false
		}
		tick := int32(binary.LittleEndian.Uint32(data[1:5]))
		side := "player"
		if data[5] == 1 {
			side = "bot"
		}
		cs := binary.LittleEndian.Uint32(data[6:10])
		return map[string]interface{}{
			"type":     "checksum",
			"tick":     int(tick),
			"side":     side,
			"checksum": int(cs),
		}, true
	}
	return nil, false
}

// ————— RESYNC / RESUME / RESULT —————

func (s *Server) handleResync(c *Client, msg map[string]interface{}) {
	room := c.Room
	if room == nil || !room.Started {
		return
	}
	target := asInt(msg["tick"])
	base := asInt(msg["base_tick"])
	if base < 0 {
		base = 0
	}
	if target < base {
		target = base
	}
	cmds := room.CommandsBetween(base+1, target)
	other := room.Other(c)
	payload := func(rc *Client) map[string]interface{} {
		myDeck, peerDeck := decksFor(room, rc)
		if cmds == nil {
			cmds = []map[string]interface{}{}
		}
		return map[string]interface{}{
			"type":      "RESYNC_DATA",
			"target_tick": target,
			"base_tick":   base,
			"seed":        room.Seed,
			"my_side":     rc.Side,
			"my_deck":     myDeck,
			"peer_deck":   peerDeck,
			"commands":    cmds,
		}
	}
	_ = s.sendJSON(c.Peer, payload(c), channelReliable, true)
	if other != nil {
		_ = s.sendJSON(other.Peer, payload(other), channelReliable, true)
	}
}

func (s *Server) handleResult(c *Client, msg map[string]interface{}) {
	room := c.Room
	if room == nil {
		return
	}
	winner, _ := msg["winner"].(string)
	code := room.Code
	s.persistResult(room, winner, c.Side)
	_ = s.sendJSON(c.Peer, map[string]interface{}{"type": "RESULT", "winner": winner, "room_code": code}, channelReliable, true)
	other := room.Other(c)
	if other != nil {
		_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "RESULT", "winner": winner, "room_code": code}, channelReliable, true)
	}
	log.Printf("result room=%s winner=%s reporter=%s", code, winner, c.Side)
}

func (s *Server) handleRematch(c *Client) {
	room := c.Room
	if room == nil {
		return
	}
	other := room.Other(c)
	if other != nil {
		_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "PEER_REMATCH"}, channelReliable, true)
	}
}

func (s *Server) handleLeaveRoom(c *Client) {
	room := c.Room
	if room == nil {
		return
	}
	other := room.Other(c)
	if c.Side == "host" {
		delete(s.rooms, room.Code)
	} else {
		room.Guest = nil
	}
	c.Room = nil
	if other != nil {
		_ = s.sendJSON(other.Peer, map[string]interface{}{"type": "PEER_LEFT", "who": c.Side}, channelReliable, true)
	}
}

func (s *Server) persistResult(room *Room, winner string, reporterSide string) {
	hostDeck, guestDeck := []string{}, []string{}
	if room.Host != nil {
		hostDeck = room.Host.Deck
	}
	if room.Guest != nil {
		guestDeck = room.Guest.Deck
	}
	entry := map[string]interface{}{
		"ts":            time.Now().UTC().Format(time.RFC3339),
		"room_code":     room.Code,
		"winner":        winner,
		"seed":          room.Seed,
		"host_deck":     hostDeck,
		"guest_deck":    guestDeck,
		"reporter_side": reporterSide,
	}
	raw, err := json.Marshal(entry)
	if err != nil {
		return
	}
	f, err := os.OpenFile(matchResultsPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("cannot write match results: %v", err)
		return
	}
	defer f.Close()
	_, _ = f.Write(append(raw, '\n'))
}

// ————— 命令查询 —————

func (r *Room) Other(c *Client) *Client {
	if r.Host == c {
		return r.Guest
	}
	if r.Guest == c {
		return r.Host
	}
	return nil
}

func (r *Room) CommandsBetween(from, to int) []map[string]interface{} {
	result := []map[string]interface{}{}
	for _, cmd := range r.Commands {
		t := asInt(cmd["tick"])
		if t >= from && t <= to {
			result = append(result, cmd)
		}
	}
	sort.Slice(result, func(i, j int) bool {
		ti := asInt(result[i]["tick"])
		tj := asInt(result[j]["tick"])
		if ti == tj {
			si, _ := result[i]["side"].(string)
			sj, _ := result[j]["side"].(string)
			return si < sj
		}
		return ti < tj
	})
	return result
}

// ————— 心跳/断线清扫 —————

func (s *Server) sweep() {
	now := time.Now()
	for _, room := range s.rooms {
		if !room.Started {
			continue
		}
		for _, c := range []*Client{room.Host, room.Guest} {
			if c == nil || !c.Disconnected {
				continue
			}
			if now.Sub(c.DisconnectedAt) >= disconnectGraceSeconds*time.Second {
				other := room.Other(c)
				winner := "draw"
				if other != nil && other.Side != "" {
					winner = other.Side
				}
				s.persistResult(room, winner, "server")
				if other != nil {
					_ = s.sendJSON(other.Peer, map[string]interface{}{
						"type":      "OPPONENT_DISCONNECTED_WIN",
						"winner":    winner,
						"room_code": room.Code,
					}, channelReliable, true)
				}
				delete(s.rooms, room.Code)
				if room.Host != nil {
					room.Host.Room = nil
				}
				if room.Guest != nil {
					room.Guest.Room = nil
				}
				log.Printf("disconnect timeout room=%s winner=%s", room.Code, winner)
				break
			}
		}
	}
	// 清理长时间无心跳但未断开的僵尸连接（ENet 自身超时通常已处理，这里兜底）
	for token, c := range s.clients {
		if c.Room == nil && now.Sub(c.LastSeen) > heartbeatTimeout*time.Second {
			c.Peer.DisconnectNow(0)
			delete(s.clients, token)
		}
	}
}

// strconv 保留引用，便于后续扩展参数解析。
var _ = strconv.Itoa

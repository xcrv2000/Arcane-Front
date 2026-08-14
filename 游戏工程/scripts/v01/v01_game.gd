# V0.1/V0.2 对局控制器：Godot Control 节点入口。
# V0.4 (P0+P2)：
#   - 帧 delta → 累加器 → 固定 tick 推进；
#   - 玩家出牌、Bot 出牌都经 LockstepScheduler 命令队列，再由 execute_command 统一进入模拟器；
#   - 每 DESYNC_CHECK_INTERVAL tick 生成 CHECKSUM 命令并入队（本地双实例自校验通过调度器 verify）。
# 职责仅限：生命周期、输入分发（→命令入队）、每帧 tick 推进、屏幕状态切换。
extends Control

const Config = preload("res://scripts/config/game_config.gd")
const CardCatalog = preload("res://scripts/v01/card_catalog.gd")
const BattleSimulator = preload("res://scripts/simulation/battle_simulator.gd")
const TaskSystem = preload("res://scripts/simulation/task_system.gd")
const BotBrain = preload("res://scripts/simulation/bot_brain.gd")
const CanvasHelpers = preload("res://scripts/presentation/canvas_helpers.gd")
const UIPainter = preload("res://scripts/presentation/ui_painter.gd")
const LockstepScheduler = preload("res://scripts/networking/lockstep_scheduler.gd")
const Command = preload("res://scripts/networking/command.gd")
const Fp = preload("res://scripts/support/fp_math.gd")
const NetworkClient = preload("res://scripts/networking/network_client.gd")
const DECK_SAVE_PATH: String = "user://selected_deck.json"
const CARD_HOTKEYS: Array[Key] = [KEY_Q, KEY_W, KEY_E, KEY_A, KEY_S, KEY_D]

enum ScreenMode { MAIN_MENU, COMPENDIUM, DECK_BUILDER, ROOM_SETUP, ROOM_WAIT, BATTLE, RESULT }

var screen_mode: int = ScreenMode.MAIN_MENU
var cards: Array[Dictionary] = []
var selected_card_ids: Array[String] = []
var saved_deck_ids: Array[String] = []
var selected_battle_card_id: String = ""
var compendium_card_id: String = ""
var frontend_status_text: String = ""

var helpers: CanvasHelpers
var simulator: BattleSimulator
var task_system: TaskSystem
var bot_brain: BotBrain
var painter: UIPainter
var scheduler: LockstepScheduler

# V0.4：本地自校验用——模拟"我方与Bot各发送一份checksum"进行比对
# （联机模式下远端checksum由网络层入队）
var last_issued_checksum_tick: int = -1

# —— V0.4 联机：房间/网络相关状态 ——
var online_mode: bool = false  # true=当前对战是联机（对真实远端），false=本地对Bot
var net: RefCounted = null    # NetworkClient 实例
var room_code: String = ""
var my_side: String = "host"        # "host" / "guest"（服务器分配的联机房间角色）
var my_game_side: String = Config.PLAYER  # 我在模拟器中的阵营（联机时host=player，guest=bot）
var peer_game_side: String = Config.BOT
var my_ready: bool = false
var peer_ready: bool = false
var peer_deck_ids: Array[String] = []
var online_status_text: String = ""  # 房间界面顶部状态栏
var join_input_text: String = ""     # 加入房间时的临时输入
var disconnect_countdown: float = -1.0  # -1=未启动；>0=倒计时中（秒）

# Issue1: 对方申请了再战（RESULT界面提示）
var peer_rematch_requested: bool = false
# Issue2: 对方退出了房间（""=无；"host"=房主退出；"guest"=客机退出）
var peer_left_reason: String = ""
# Issue5: 战斗恢复倒计时（>0时显示倒计时覆盖层，暂停模拟）
var battle_restart_countdown: float = -1.0

# —— 房间/联机按钮（按屏幕尺寸动态计算位置，不用改 UIPainter）——
var online_create_rect: Rect2 = Rect2()
var join_input_rect: Rect2 = Rect2()
var room_ready_rect: Rect2 = Rect2()
var room_leave_rect: Rect2 = Rect2()
var join_submit_rect: Rect2 = Rect2()
var room_setup_back_rect: Rect2 = Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	cards = CardCatalog.all_cards()
	helpers = CanvasHelpers.new()
	helpers.setup(get_theme_default_font())
	simulator = BattleSimulator.new()
	task_system = TaskSystem.new()
	task_system.setup(cards, simulator)
	simulator.setup(task_system)
	bot_brain = BotBrain.new()
	painter = UIPainter.new()
	painter.setup(helpers, simulator, task_system, cards)
	scheduler = LockstepScheduler.new()
	scheduler.strict_wait = false  # 本地模式，不等待网络
	scheduler.sides = [Config.PLAYER, Config.BOT]
	_load_saved_deck()
	selected_card_ids = saved_deck_ids.duplicate()
	if not cards.is_empty():
		compendium_card_id = String(cards[0]["id"])
	# 初始化网络客户端（需要一个 Node 挂定时器做帧轮询）
	_init_networking()
	queue_redraw()


# 牌组存档只有一个“当前牌组”。读取时会过滤不存在/重复的卡牌；无有效存档则使用卡池前 6 张。
func _load_saved_deck() -> void:
	saved_deck_ids = _default_deck_ids()
	if not FileAccess.file_exists(DECK_SAVE_PATH):
		return
	var raw: String = FileAccess.get_file_as_string(DECK_SAVE_PATH)
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		frontend_status_text = "牌组存档无法读取，已使用默认牌组。"
		return
	var candidate: Array[String] = []
	var seen: Dictionary = {}
	var known: Dictionary = {}
	for card in cards:
		known[String(card.get("id", ""))] = true
	for raw_id in parsed.get("selected_card_ids", []):
		var card_id: String = String(raw_id)
		if known.has(card_id) and not seen.has(card_id):
			candidate.append(card_id)
			seen[card_id] = true
	if candidate.size() == Config.CARD_PICK_COUNT:
		saved_deck_ids = candidate
	else:
		frontend_status_text = "牌组存档不完整，已使用默认牌组。"


func _default_deck_ids() -> Array[String]:
	var result: Array[String] = []
	for index in range(min(Config.CARD_PICK_COUNT, cards.size())):
		result.append(String(cards[index]["id"]))
	return result


func _save_current_deck() -> bool:
	if selected_card_ids.size() != Config.CARD_PICK_COUNT:
		frontend_status_text = "需要恰好选择 %d 张卡才能保存。" % Config.CARD_PICK_COUNT
		return false
	var file: FileAccess = FileAccess.open(DECK_SAVE_PATH, FileAccess.WRITE)
	if file == null:
		frontend_status_text = "保存牌组失败（错误码 %d）。" % FileAccess.get_open_error()
		return false
	saved_deck_ids = selected_card_ids.duplicate()
	file.store_string(JSON.stringify({
		"schema_version": 1,
		"selected_card_ids": saved_deck_ids
	}, "\t"))
	file.close()
	frontend_status_text = "牌组已保存，单机与联机将使用这 6 张卡。"
	return true


# —— 网络初始化：挂信号 + 用 self（Control Node）做轮询宿主
func _init_networking() -> void:
	if net != null:
		return
	net = NetworkClient.new()
	net.default_host = "127.0.0.1"
	net.default_port = 8765
	net.connected_to_server.connect(_on_connected)
	net.connection_failed.connect(_on_conn_fail)
	net.disconnected.connect(_on_disconnected)
	net.room_created.connect(_on_room_created)
	net.room_joined.connect(_on_room_joined)
	net.peer_joined.connect(_on_peer_joined)
	net.peer_ready_changed.connect(_on_peer_ready_changed)
	net.peer_disconnected.connect(_on_peer_disconnect)
	net.opponent_win_by_disconnect.connect(_on_opponent_win_by_dc)
	net.start_match_received.connect(_on_start_match)
	net.command_received.connect(_on_peer_command)
	net.result_received.connect(_on_result_received)
	net.peer_rematch_received.connect(_on_peer_rematch)
	net.peer_left_received.connect(_on_peer_left)
	net.resume_battle_received.connect(_on_resume_battle)
	net.server_error.connect(_on_server_error)


# 帧 → 累加器 → 整数 tick。每 tick 执行：
#   1) Bot.update 产出命令 → 入队（到 execution_tick）
#   2) 从 scheduler 取出本 tick 命令 → execute_command
#   3) advance_time(TICK_DT) → check_mana → update_units → 法术特效 → 进化闪光 → 胜负切换
#   4) 若 tick 为 DESYNC_CHECK_INTERVAL 倍数：生成双方 CHECKSUM 命令并验证
func _process(delta: float) -> void:
	# 网络轮询：每帧直接 poll（替代 Timer 的 0.033s 延迟，确保对端命令及时接收）
	if net != null and net.is_attached():
		net.poll()
	# 断线倒计时在任何界面下都需要更新
	if disconnect_countdown > 0.0:
		_tick_disconnect_countdown(delta)
		queue_redraw()  # Issue3: 确保倒计时在RESULT界面也能每帧刷新

	# Issue5: 战斗恢复倒计时（暂停期间不推进 accumulate，不攒 tick 债）
	var resume_now: bool = false
	if battle_restart_countdown > 0.0:
		battle_restart_countdown = maxf(0.0, battle_restart_countdown - delta)
		if battle_restart_countdown <= 0.0:
			battle_restart_countdown = -1.0
			resume_now = true
			# —— 倒计时结束：扩展对方NO_OP窗口到 256 tick，避免刚恢复就因为网络抖动缺命令暂停
			var extra_base: int = scheduler.current_tick
			for i in range(1, 256 + 1):
				var t: int = extra_base + i
				if not scheduler.has_side_command_for_tick(t, peer_game_side):
					var noop_peer: Dictionary = Command.no_op_command(t, peer_game_side)
					scheduler.enqueue_command(noop_peer)
			# 解除 strict_wait 暂停（consume 会覆盖，但我们同时保证命令齐）
			scheduler.paused = false
			simulator.push_event("战斗恢复！")
		queue_redraw()

	if screen_mode == ScreenMode.BATTLE:
		# 倒计时中：完全跳过 accumulate 与推进循环（不攒 tick 债）
		# 倒计时结束的那一帧（resume_now=true）也先跳过，让扩展窗口生效，下一帧再正常推进
		if battle_restart_countdown <= 0.0 and not resume_now:
			var tick_count: int = scheduler.accumulate(delta)
			for i in range(tick_count):
				if scheduler.desynced:
					break  # desync 后不再推进
				if not _step_one_tick():
					break  # 等待命令，暂停推进

		if not simulator.running:
			# 联机：正常结束时通过服务器同步结果；desync/异常结束不主动上报（避免假平局）
			if online_mode and net != null and not scheduler.desynced:
				var w: String = simulator.winner_side()
				var report_side: String = ""
				if w == my_game_side:
					report_side = my_side
				elif w == peer_game_side:
					report_side = peer_game_side_for_report()
				# 只有正常产生胜者才上报；空 winner 属于异常情况（如被外部置 running=false），不报 draw
				if report_side != "":
					net.send_result(report_side, room_code)
			screen_mode = ScreenMode.RESULT
			queue_redraw()
			return
		# 战斗中每帧重绘
		queue_redraw()


# 把模拟器中的"对端阵营"映射成服务器角色（host/guest）
func peer_game_side_for_report() -> String:
	if peer_game_side == Config.PLAYER:
		return "host"
	return "guest"


# 单 tick 模拟推进。返回 true 表示成功推进；false 表示暂停（等待命令/desync）。
func _step_one_tick() -> bool:
	var tick: int = scheduler.current_tick + 1
	var exec_tick: int = tick

	# 1) 非联机模式 Bot 思考（联机模式命令已预发，不需在此补 NO_OP）
	if not online_mode:
		var bot_cmds: Array[Dictionary] = bot_brain.update(
			Config.TICK_DT, simulator, task_system, exec_tick
		)
		for cmd in bot_cmds:
			scheduler.enqueue_command(cmd)

	# 2) 取出 tick 的双方命令 → execute_command
	var tick_cmds: Array[Dictionary] = scheduler.consume_tick_commands(tick)
	if tick_cmds.is_empty():
		# strict_wait=true 时会发生：命令缺失，本帧不推进（暂停）
		return false
	for cmd in tick_cmds:
		simulator.execute_command(cmd, task_system)

	# 3) 推进模拟（顺序与原实现完全一致，只是 delta → TICK_DT）
	simulator.advance_time(Config.TICK_DT)
	task_system.check_mana(Config.PLAYER, simulator.player_mana())
	task_system.check_mana(Config.BOT, simulator.bot_mana())
	simulator.update_units(Config.TICK_DT)
	simulator.update_spell_effects(Config.TICK_DT)
	simulator.update_evolution_flashes(Config.TICK_DT)

	scheduler.current_tick = tick

	# 3.5) 联机模式：预发未来 tick 的 NO_OP（滑动窗口）
	#      每推进一个 tick，为 tick + INPUT_DELAY_TICKS 预发一个 NO_OP
	#      这样对端总是有未来几 tick 的命令缓存，不需要实时等待网络
	if online_mode:
		var future_tick: int = tick + Config.INPUT_DELAY_TICKS
		if not scheduler.has_side_command_for_tick(future_tick, my_game_side):
			var noop_cmd: Dictionary = Command.no_op_command(future_tick, my_game_side)
			scheduler.enqueue_command(noop_cmd)
			_send_local_command_net(noop_cmd)

	# 4) CHECKSUM：每 DESYNC_CHECK_INTERVAL tick 生成校验和
	if tick > 0 and tick % Config.DESYNC_CHECK_INTERVAL == 0 and tick != last_issued_checksum_tick:
		var cs: int = simulator.state_checksum()
		if online_mode:
			# 联机模式：只注入我自己阵营的 checksum，并通过网络发送给对端
			var my_cmd: Dictionary = Command.checksum_command(tick, my_game_side, cs)
			scheduler.enqueue_command(my_cmd)
			_send_local_command_net(my_cmd)
			# 尝试比对：如果对端 checksum 也到了，就立即发现 desync；如果没到则 strict_wait 下暂停
			var vr: Dictionary = scheduler.verify_checksum_for_tick(tick)
			if not bool(vr.get("ok", true)):
				var info: Dictionary = vr.get("mismatch", {})
				simulator.running = false
				scheduler.desynced = true
				scheduler.desync_info = info
				simulator.push_event("同步错误（T%d）：%s=%d vs %s=%d，建议重开。" % [
					int(info.get("tick", tick)),
					String(info.get("side_a", "?")), int(info.get("cs_a", 0)),
					String(info.get("side_b", "?")), int(info.get("cs_b", 0))
				])
				# desync 属于异常结束：没有合法胜者，设置 override_winner="" 让 UI 显示"平局"
				painter.override_winner = ""
				screen_mode = ScreenMode.RESULT
		else:
			# 本地模式：把 player 和 bot 的 checksum 都注入（两者在同一台机器上计算，必然一致；仅演示流程）
			scheduler.enqueue_command(Command.checksum_command(tick, Config.PLAYER, cs))
			scheduler.enqueue_command(Command.checksum_command(tick, Config.BOT, cs))
			var vr: Dictionary = scheduler.verify_checksum_for_tick(tick)
			if not bool(vr.get("ok", true)):
				var info: Dictionary = vr.get("mismatch", {})
				simulator.running = false
				simulator.push_event("同步错误（T%d）：%s=%d vs %s=%d，建议重开。" % [
					int(info.get("tick", tick)),
					String(info.get("side_a", "?")), int(info.get("cs_a", 0)),
					String(info.get("side_b", "?")), int(info.get("cs_b", 0))
				])
				# desync 异常结束：显示平局（本地模式理论上不应出现，以防万一）
				painter.override_winner = ""
				screen_mode = ScreenMode.RESULT
		last_issued_checksum_tick = tick

	return true


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_press(event.position)
	elif event is InputEventScreenTouch and event.pressed:
		_handle_press(event.position)


func _input(event: InputEvent) -> void:
	# ROOM_SETUP 下：字符输入到 join_input_text；回车提交；Esc 返回；Backspace 删
	if screen_mode == ScreenMode.ROOM_SETUP:
		if event is InputEventKey and event.pressed:
			var k: Key = event.keycode
			if k == KEY_ENTER or k == KEY_KP_ENTER:
				var txt: String = join_input_text.strip_edges().to_upper()
				if txt.length() >= 4:
					_try_join_room(txt)
				return
			elif k == KEY_ESCAPE:
				_leave_room()
				return
			elif k == KEY_BACKSPACE:
				if join_input_text.length() > 0:
					join_input_text = join_input_text.substr(0, join_input_text.length() - 1)
					queue_redraw()
				return
			else:
				# Godot InputEventKey 有 unicode 属性
				var uc: int = int(event.unicode)
				if uc > 0:
					var ch: String = char(uc).to_upper()
					if "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".find(ch) >= 0 and join_input_text.length() < 8:
						join_input_text += ch
						queue_redraw()
				return
	if screen_mode != ScreenMode.BATTLE:
		return
	if not (event is InputEventKey and event.pressed) or event.echo:
		return

	var keycode: Key = event.keycode
	var hotkey_index: int = CARD_HOTKEYS.find(keycode)
	if hotkey_index >= 0:
		_select_battle_card_by_index(hotkey_index)
		return
	match keycode:
		KEY_EQUAL, KEY_PLUS:
			var mana_max_fp: int = int(Config.MANA_MAX * Config.FP_SCALE_F + 0.5)
			simulator.player_mana_fp = min(mana_max_fp, simulator.player_mana_fp + Fp.to_fp(2.0))
			simulator.push_event("调试：费用 +2")
		KEY_MINUS:
			simulator.player_mana_fp = max(0, simulator.player_mana_fp - Fp.to_fp(2.0))
			simulator.push_event("调试：费用 -2")
		KEY_T:
			if selected_battle_card_id != "":
				task_system.force_complete_task(_controlled_game_side(), selected_battle_card_id)
				simulator.push_event("调试：强制完成 %s 任务" % selected_battle_card_id)
		KEY_R:
			if not online_mode:
				_start_battle()
		KEY_B:
			bot_brain.set_use_random_deck(not bot_brain.use_random_deck)
			simulator.push_event("调试：Bot 牌组模式 → %s" % ("随机" if bot_brain.use_random_deck else "固定"))
		KEY_Y:
			var new_seed: int = simulator.rng.randi()
			simulator.set_shared_seed(new_seed)
			simulator.push_event("调试：随机种子已重置为 %d" % new_seed)
		KEY_F:
			_toggle_debug_overlay()
		KEY_ESCAPE:
			if online_mode:
				_leave_room()


func _select_battle_card_by_index(index: int) -> void:
	if index < 0 or index >= selected_card_ids.size():
		return
	selected_battle_card_id = selected_card_ids[index]
	painter.info_card_id = selected_battle_card_id
	var side: String = _controlled_game_side()
	var card: Dictionary = task_system.active_card_by_id(side, selected_battle_card_id)
	var mana_fp: int = simulator.player_mana_fp if side == Config.PLAYER else simulator.bot_mana_fp
	var cost_fp: int = int(float(card.get("cost", 0.0)) * Config.FP_SCALE_F + 0.5)
	if mana_fp < cost_fp:
		simulator.push_event("%s 费用不足。" % String(card.get("name", selected_battle_card_id)))
	queue_redraw()


func _controlled_game_side() -> String:
	return my_game_side if online_mode else Config.PLAYER


var show_debug_overlay: bool = true


func _toggle_debug_overlay() -> void:
	show_debug_overlay = not show_debug_overlay
	simulator.push_event("调试：调试面板 %s" % ("显示" if show_debug_overlay else "隐藏"))


func _handle_press(position: Vector2) -> void:
	var is_frontend: bool = screen_mode != ScreenMode.BATTLE and screen_mode != ScreenMode.RESULT
	painter.update_layout(size, is_frontend)
	_recompute_online_rects()
	if screen_mode == ScreenMode.MAIN_MENU:
		_handle_main_menu_press(position)
	elif screen_mode == ScreenMode.COMPENDIUM:
		_handle_compendium_press(position)
	elif screen_mode == ScreenMode.DECK_BUILDER:
		_handle_deck_builder_press(position)
	elif screen_mode == ScreenMode.ROOM_SETUP:
		_handle_room_setup_press(position)
	elif screen_mode == ScreenMode.ROOM_WAIT:
		_handle_room_wait_press(position)
	elif screen_mode == ScreenMode.BATTLE:
		_handle_battle_press(position)
	elif screen_mode == ScreenMode.RESULT:
		if painter.restart_rect.has_point(position):
			if online_mode:
				if peer_left_reason == "host":
					# 房主已退出，房间已解散，按钮不可按
					pass
				elif peer_left_reason == "guest":
					# 客机退出，房主可回到房间等待新客机
					_back_to_room_wait()
				elif battle_restart_countdown > 0.0:
					pass  # 战斗恢复倒计时中，不可按
				else:
					_request_online_rematch()
			else:
				_start_battle()
		elif painter.deck_rect.has_point(position):
			_leave_room()


func _recompute_online_rects() -> void:
	var w: float = size.x
	var h: float = size.y
	var box_w: float = min(460.0, w - 64.0)
	join_input_rect = Rect2(Vector2(w * 0.5 - box_w * 0.5, h * 0.5 - 84.0), Vector2(box_w, 54.0))
	join_submit_rect = Rect2(Vector2(w * 0.5 - box_w * 0.5, h * 0.5 - 18.0), Vector2(box_w, 48.0))
	online_create_rect = Rect2(Vector2(w * 0.5 - box_w * 0.5, h * 0.5 + 92.0), Vector2(box_w, 52.0))
	room_setup_back_rect = Rect2(Vector2(22.0, 22.0), Vector2(112.0, 44.0))
	# 房间等待界面：准备/离开
	room_ready_rect = Rect2(Vector2(w * 0.5 - 220.0, h * 0.5 + 60.0), Vector2(200.0, 48.0))
	room_leave_rect = Rect2(Vector2(w * 0.5 + 20.0, h * 0.5 + 60.0), Vector2(200.0, 48.0))


func _handle_room_setup_press(pos: Vector2) -> void:
	if online_create_rect.has_point(pos):
		_try_create_room()
	elif join_submit_rect.has_point(pos):
		# 提交加入请求
		var txt: String = join_input_text.strip_edges().to_upper()
		if txt.length() < 4:
			online_status_text = "房间码不足 4 位（%s）" % txt
			queue_redraw()
			return
		_try_join_room(txt)
	elif room_setup_back_rect.has_point(pos):
		_leave_room()


func _handle_room_wait_press(pos: Vector2) -> void:
	if room_ready_rect.has_point(pos):
		_toggle_ready()
	elif room_leave_rect.has_point(pos):
		_leave_room()


func _handle_main_menu_press(position: Vector2) -> void:
	if painter.main_menu_rects.get("single", Rect2()).has_point(position):
		selected_card_ids = saved_deck_ids.duplicate()
		online_mode = false
		_start_battle()
	elif painter.main_menu_rects.get("online", Rect2()).has_point(position):
		selected_card_ids = saved_deck_ids.duplicate()
		screen_mode = ScreenMode.ROOM_SETUP
		online_status_text = ""
		join_input_text = ""
		queue_redraw()
	elif painter.main_menu_rects.get("compendium", Rect2()).has_point(position):
		screen_mode = ScreenMode.COMPENDIUM
		frontend_status_text = ""
		queue_redraw()
	elif painter.main_menu_rects.get("deck", Rect2()).has_point(position):
		selected_card_ids = saved_deck_ids.duplicate()
		screen_mode = ScreenMode.DECK_BUILDER
		frontend_status_text = ""
		queue_redraw()


func _handle_compendium_press(position: Vector2) -> void:
	if painter.back_rect.has_point(position):
		screen_mode = ScreenMode.MAIN_MENU
		queue_redraw()
		return
	for raw_card_id in painter.repository_card_rects.keys():
		var card_id: String = String(raw_card_id)
		if painter.repository_card_rects[card_id].has_point(position):
			compendium_card_id = card_id
			queue_redraw()
			return


func _handle_deck_builder_press(position: Vector2) -> void:
	if painter.back_rect.has_point(position):
		selected_card_ids = saved_deck_ids.duplicate()
		screen_mode = ScreenMode.MAIN_MENU
		frontend_status_text = ""
		queue_redraw()
		return
	if painter.save_deck_rect.has_point(position):
		_save_current_deck()
		queue_redraw()
		return
	for raw_card_id in painter.deck_slot_rects.keys():
		var card_id: String = String(raw_card_id)
		if painter.deck_slot_rects[card_id].has_point(position):
			selected_card_ids.erase(card_id)
			frontend_status_text = "已移出 %s；保存后生效。" % _card_name(card_id)
			queue_redraw()
			return
	for raw_card_id in painter.repository_card_rects.keys():
		var card_id: String = String(raw_card_id)
		if painter.repository_card_rects[card_id].has_point(position):
			_toggle_card_selection(card_id)
			queue_redraw()
			return


func _handle_battle_press(position: Vector2) -> void:
	for raw_card_id in painter.battle_card_rects.keys():
		var card_id: String = String(raw_card_id)
		if painter.battle_card_rects[card_id].has_point(position):
			selected_battle_card_id = card_id
			painter.info_card_id = card_id
			var side: String = _controlled_game_side()
			var card: Dictionary = task_system.active_card_by_id(side, card_id)
			var cost_fp: int = int(float(card["cost"]) * Config.FP_SCALE_F + 0.5)
			var mana_fp: int = simulator.player_mana_fp if side == Config.PLAYER else simulator.bot_mana_fp
			if mana_fp < cost_fp:
				simulator.push_event("%s 费用不足。" % card["name"])
			queue_redraw()
			return

	# 玩家出牌：转定点坐标 → 生成 command_fp → 送入 scheduler（延迟 INPUT_DELAY_TICKS 后执行）
	if painter.is_in_board(position) and selected_battle_card_id != "":
		var logic_position: Vector2 = painter.screen_to_map(position)
		var exec_tick: int = scheduler.target_execution_tick()
		var tgt_x_fp: int = Fp.to_fp(logic_position.x)
		var tgt_y_fp: int = Fp.to_fp(logic_position.y)
		# 联机时使用 my_game_side（host=PLAYER/guest=BOT）
		var side_to_use: String = Config.PLAYER
		if online_mode:
			side_to_use = my_game_side
		var cmd: Dictionary = Command.play_card_command_fp(
			exec_tick,
			side_to_use,
			selected_battle_card_id,
			tgt_x_fp,
			tgt_y_fp
		)
		scheduler.enqueue_command(cmd)
		_send_local_command_net(cmd)
		queue_redraw()


func _toggle_card_selection(card_id: String) -> void:
	if selected_card_ids.has(card_id):
		selected_card_ids.erase(card_id)
		frontend_status_text = "已移出 %s；保存后生效。" % _card_name(card_id)
	elif selected_card_ids.size() < Config.CARD_PICK_COUNT:
		selected_card_ids.append(card_id)
		frontend_status_text = "已加入 %s（%d/%d）；保存后生效。" % [_card_name(card_id), selected_card_ids.size(), Config.CARD_PICK_COUNT]
	else:
		frontend_status_text = "牌组已满；请先移出一张卡。"


func _card_name(card_id: String) -> String:
	for card in cards:
		if String(card.get("id", "")) == card_id:
			return String(card.get("name", card_id))
	return card_id


func _start_battle() -> void:
	if selected_card_ids.size() != Config.CARD_PICK_COUNT:
		selected_card_ids = saved_deck_ids.duplicate()
	if selected_card_ids.is_empty():
		frontend_status_text = "当前没有可用牌组。"
		screen_mode = ScreenMode.MAIN_MENU
		queue_redraw()
		return
	screen_mode = ScreenMode.BATTLE
	selected_battle_card_id = selected_card_ids[0]
	painter.info_card_id = selected_card_ids[0]
	painter.override_winner = ""
	scheduler.reset()
	scheduler.strict_wait = false  # 本地模式不等待
	scheduler.sides = [Config.PLAYER, Config.BOT]
	painter.controlled_side = Config.PLAYER
	bot_brain.reset()
	task_system.initialize(selected_card_ids, bot_brain.current_deck())
	simulator.start_battle()
	last_issued_checksum_tick = -1
	simulator.push_event("V0.4 对局开始：固定 tick %dHz，输入延迟 %d tick，校验每 %d tick。Bot 卡组：%s" % [Config.TICK_RATE, Config.INPUT_DELAY_TICKS, Config.DESYNC_CHECK_INTERVAL, ", ".join(bot_brain.current_deck())])
	queue_redraw()


func _draw() -> void:
	var is_frontend: bool = screen_mode != ScreenMode.BATTLE and screen_mode != ScreenMode.RESULT
	painter.update_layout(size, is_frontend)
	_recompute_online_rects()
	painter.selected_card_ids = selected_card_ids
	painter.selected_battle_card_id = selected_battle_card_id
	painter.draw_background(self)
	if screen_mode == ScreenMode.MAIN_MENU:
		painter.draw_main_menu(self, saved_deck_ids, frontend_status_text)
	elif screen_mode == ScreenMode.COMPENDIUM:
		painter.draw_compendium(self, compendium_card_id)
	elif screen_mode == ScreenMode.DECK_BUILDER:
		painter.draw_deck_builder(self, selected_card_ids, frontend_status_text)
	elif screen_mode == ScreenMode.ROOM_SETUP:
		_draw_room_setup()
		_draw_status_banner()
	elif screen_mode == ScreenMode.ROOM_WAIT:
		_draw_room_wait()
		_draw_status_banner()
	else:
		painter.draw_battle(self)
		if show_debug_overlay and screen_mode == ScreenMode.BATTLE:
			# 调试面板附加 desync / 暂停状态（V0.4 新增）
			painter.draw_debug_overlay(self, bot_brain.current_deck(), simulator.rng_seed)
			_draw_net_status_hud()
			_draw_disconnect_countdown()
		if screen_mode == ScreenMode.RESULT:
			# Issue1/2: 同步RESULT界面状态到painter
			if not online_mode:
				painter.result_button_mode = "normal"
				painter.result_rematch_hint = ""
			else:
				if peer_left_reason == "host":
					painter.result_button_mode = "disabled"
					painter.result_rematch_hint = ""
				elif peer_left_reason == "guest":
					painter.result_button_mode = "back_to_room"
					painter.result_rematch_hint = ""
				else:
					painter.result_button_mode = "normal"
					painter.result_rematch_hint = "对方申请了再战" if peer_rematch_requested else ""
			painter.draw_result_overlay(self)
		# Issue5: 战斗恢复倒计时覆盖层
		if battle_restart_countdown > 0.0:
			_draw_restart_countdown()
		_draw_status_banner()


# —— 顶部状态栏（显示 online_status_text / 断线倒计时）
func _draw_status_banner() -> void:
	if online_status_text == "" and disconnect_countdown <= 0.0:
		return
	var w: float = size.x
	var panel: Rect2 = Rect2(Vector2(14.0, 14.0), Vector2(w - 28.0, 36.0))
	var col: Color = Color(0.08, 0.10, 0.14, 0.86)
	var border: Color = Color(0.86, 0.66, 0.30)
	if online_status_text.find("失败") >= 0 or online_status_text.find("报错") >= 0 or online_status_text.find("错误") >= 0:
		border = Color(0.90, 0.32, 0.30)
	helpers.draw_panel(self, panel, col, 6.0, border, 1.0)
	var text: String = online_status_text
	if disconnect_countdown > 0.0:
		text += "  倒计时 %ds" % int(ceilf(disconnect_countdown))
	helpers.draw_text_line(self, text, Rect2(panel.position + Vector2(12.0, 10.0), Vector2(panel.size.x - 24.0, 18.0)), 14, Color(0.94, 0.92, 0.80), HORIZONTAL_ALIGNMENT_LEFT)


func _draw_disconnect_countdown() -> void:
	if disconnect_countdown <= 0.0:
		return
	var w: float = size.x
	var h: float = size.y
	var panel: Rect2 = Rect2(Vector2(w * 0.5 - 220.0, h * 0.5 - 40.0), Vector2(440.0, 80.0))
	helpers.draw_panel(self, panel, Color(0.18, 0.08, 0.08, 0.92), 10.0, Color(0.92, 0.30, 0.28), 2.0)
	helpers.draw_text_line(self, "对方连接中断", Rect2(panel.position + Vector2(14.0, 16.0), Vector2(panel.size.x - 28.0, 22.0)), 18, Color(0.98, 0.86, 0.40), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(self, "等待 %d 秒后判负（%s）" % [int(ceilf(disconnect_countdown)), room_code], Rect2(panel.position + Vector2(14.0, 44.0), Vector2(panel.size.x - 28.0, 18.0)), 13, Color(0.90, 0.80, 0.70), HORIZONTAL_ALIGNMENT_CENTER)


# Issue5: 战斗恢复倒计时覆盖层
func _draw_restart_countdown() -> void:
	var w: float = size.x
	var h: float = size.y
	var panel: Rect2 = Rect2(Vector2(w * 0.5 - 160.0, h * 0.5 - 50.0), Vector2(320.0, 100.0))
	helpers.draw_panel(self, panel, Color(0.08, 0.12, 0.08, 0.92), 10.0, Color(0.42, 0.92, 0.52), 2.0)
	helpers.draw_text_line(self, "战斗恢复", Rect2(panel.position + Vector2(14.0, 16.0), Vector2(panel.size.x - 28.0, 28.0)), 22, Color(0.72, 0.96, 0.80), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_text_line(self, "%d" % int(ceilf(battle_restart_countdown)), Rect2(panel.position + Vector2(14.0, 48.0), Vector2(panel.size.x - 28.0, 36.0)), 32, Color(0.96, 0.94, 0.68), HORIZONTAL_ALIGNMENT_CENTER)


# —— ROOM_SETUP：选择创建房间，或输入 4 位房间码加入
func _draw_room_setup() -> void:
	var w: float = size.x
	var h: float = size.y
	var title: Rect2 = Rect2(Vector2(40.0, h * 0.5 - 250.0), Vector2(w - 80.0, 42.0))
	helpers.draw_text_line(self, "联机对战", title, 30, Color(0.94, 0.86, 0.60), HORIZONTAL_ALIGNMENT_CENTER)
	var deck_hint: Rect2 = Rect2(Vector2(40.0, h * 0.5 - 202.0), Vector2(w - 80.0, 22.0))
	helpers.draw_text_line(self, "使用当前已保存牌组（%d/%d）" % [saved_deck_ids.size(), Config.CARD_PICK_COUNT], deck_hint, 14, Color(0.70, 0.77, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	var hint: Rect2 = Rect2(Vector2(40.0, h * 0.5 - 126.0), Vector2(w - 80.0, 20.0))
	helpers.draw_text_line(self, "输入房间码加入（字母+数字，不含 0/O/1/I）", hint, 13, Color(0.78, 0.74, 0.66), HORIZONTAL_ALIGNMENT_CENTER)
	helpers.draw_panel(self, join_input_rect, Color(0.06, 0.08, 0.12, 0.96), 6.0, Color(0.70, 0.80, 0.96), 1.5)
	var text: String = join_input_text
	if text == "":
		text = "房间码（例：ABC2）"
		var c: Color = Color(0.46, 0.50, 0.60)
		helpers.draw_text_line(self, text, Rect2(join_input_rect.position + Vector2(16.0, 16.0), Vector2(join_input_rect.size.x - 32.0, 20.0)), 18, c, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		var c: Color = Color(0.96, 0.90, 0.68)
		helpers.draw_text_line(self, text, Rect2(join_input_rect.position + Vector2(16.0, 16.0), Vector2(join_input_rect.size.x - 32.0, 20.0)), 22, c, HORIZONTAL_ALIGNMENT_CENTER)
	_draw_button(room_setup_back_rect, "返回", true, Color(0.50, 0.50, 0.60), Color(0.20, 0.22, 0.28))
	var ready_active: bool = join_input_text.strip_edges().length() >= 4
	_draw_button(join_submit_rect, "加入房间", ready_active, Color(0.30, 0.72, 0.52), Color(0.20, 0.34, 0.28))
	var separator: Rect2 = Rect2(Vector2(40.0, h * 0.5 + 48.0), Vector2(w - 80.0, 22.0))
	helpers.draw_text_line(self, "或", separator, 13, Color(0.48, 0.54, 0.62), HORIZONTAL_ALIGNMENT_CENTER)
	_draw_button(online_create_rect, "创建新房间", saved_deck_ids.size() == Config.CARD_PICK_COUNT, Color(0.30, 0.55, 0.92), Color(0.20, 0.24, 0.34))


# —— ROOM_WAIT：显示房间码、双方准备按钮
func _draw_room_wait() -> void:
	var w: float = size.x
	var h: float = size.y
	var title: Rect2 = Rect2(Vector2(40.0, h * 0.5 - 180.0), Vector2(w - 80.0, 40.0))
	helpers.draw_text_line(self, "房间：%s" % room_code, title, 32, Color(0.96, 0.86, 0.42), HORIZONTAL_ALIGNMENT_CENTER)
	var side_hint: Rect2 = Rect2(Vector2(40.0, h * 0.5 - 130.0), Vector2(w - 80.0, 22.0))
	helpers.draw_text_line(self, "我：%s（卡组 %d/%d 已选）" % [my_side.to_upper(), selected_card_ids.size(), Config.CARD_PICK_COUNT], side_hint, 16, Color(0.88, 0.82, 0.74), HORIZONTAL_ALIGNMENT_CENTER)
	var status: Rect2 = Rect2(Vector2(40.0, h * 0.5 - 80.0), Vector2(w - 80.0, 26.0))
	var me_s: String = "✅ 我已准备" if my_ready else "⏸ 我未准备"
	var peer_s: String = "✅ 对方已准备" if peer_ready else "⏸ 对方未准备"
	helpers.draw_text_line(self, "%s        |        %s" % [me_s, peer_s], status, 15, Color(0.78, 0.92, 0.78) if (my_ready and peer_ready) else Color(0.92, 0.80, 0.62), HORIZONTAL_ALIGNMENT_CENTER)
	var tip: Rect2 = Rect2(Vector2(40.0, h * 0.5 + 10.0), Vector2(w - 80.0, 20.0))
	helpers.draw_text_line(self, "双方都点「准备」后服务器自动开始（共享随机种子+牌组）", tip, 12, Color(0.66, 0.72, 0.80), HORIZONTAL_ALIGNMENT_CENTER)
	var ready_bg: Color = Color(0.30, 0.72, 0.52) if not my_ready else Color(0.30, 0.55, 0.92)
	_draw_button(room_ready_rect, "准备 / 取消" + (" ✓" if my_ready else ""), true, ready_bg, Color(0.20, 0.34, 0.28))
	_draw_button(room_leave_rect, "离开房间", true, Color(0.78, 0.40, 0.30), Color(0.30, 0.20, 0.20))


# 网络状态小 HUD：显示当前 tick / 等待原因 / desync 信息
func _draw_net_status_hud() -> void:
	var lines: Array[String] = []
	lines.append("T%d  tick %dHz  延迟%dt" % [scheduler.current_tick, Config.TICK_RATE, Config.INPUT_DELAY_TICKS])
	if scheduler.desynced:
		var info: Dictionary = scheduler.desync_info
		lines.append("DESYNC T%d: %s vs %s" % [int(info.get("tick", -1)), String(info.get("side_a", "?")), String(info.get("side_b", "?"))])
	elif scheduler.paused:
		lines.append("暂停：%s" % scheduler.paused_reason)
	elif scheduler.waiting_for_tick > 0:
		lines.append("等待T%d" % scheduler.waiting_for_tick)
	if lines.size() <= 1 and not scheduler.desynced and not scheduler.paused:
		return
	var line_h: float = 13.0
	var panel_h: float = lines.size() * line_h + 8.0
	var panel: Rect2 = Rect2(size.x - 220.0, 70.0, 208.0, panel_h)
	helpers.draw_panel(self, panel, Color(0.04, 0.05, 0.06, 0.80), 5.0, Color(0.90, 0.32, 0.30) if scheduler.desynced else Color(0.86, 0.66, 0.30), 1.0)
	for index in range(lines.size()):
		var col: Color = Color(0.96, 0.52, 0.50) if scheduler.desynced else Color(0.88, 0.84, 0.42) if scheduler.paused else Color(0.68, 0.74, 0.82)
		helpers.draw_text_line(self, lines[index], Rect2(panel.position + Vector2(8.0, 4.0 + index * line_h), Vector2(panel.size.x - 16.0, line_h)), 10, col, HORIZONTAL_ALIGNMENT_LEFT)


# ———————————————— V0.4 联机：网络信号处理 ————————————————
func _on_connected() -> void:
	online_status_text = "已连接服务器"
	queue_redraw()


func _on_conn_fail(reason: String) -> void:
	online_status_text = "连接失败：%s（点击返回主界面）" % reason
	room_code = ""
	my_ready = false
	peer_ready = false
	queue_redraw()


func _on_disconnected() -> void:
	online_status_text = "服务器断开"
	disconnect_countdown = -1.0
	battle_restart_countdown = -1.0
	# 对局中如果未结束则进入结果页
	if screen_mode == ScreenMode.BATTLE:
		simulator.running = false
		screen_mode = ScreenMode.RESULT
	queue_redraw()


func _on_room_created(code: String, side: String) -> void:
	room_code = code
	my_side = side
	my_ready = false
	peer_ready = false
	_online_setup_sides()
	online_status_text = "房间已创建：%s（我是%s，等待玩家加入…）" % [code, side]
	screen_mode = ScreenMode.ROOM_WAIT
	queue_redraw()


func _on_room_joined(code: String, side: String) -> void:
	room_code = code
	my_side = side
	my_ready = false
	peer_ready = false
	_online_setup_sides()
	online_status_text = "已加入房间：%s（我是%s，双方点准备开始）" % [code, side]
	screen_mode = ScreenMode.ROOM_WAIT
	queue_redraw()


func _on_peer_joined() -> void:
	online_status_text = "对方已加入房间：%s（双方点准备开始）" % room_code
	peer_ready = false
	# Issue4: 对方重连时取消断线倒计时
	disconnect_countdown = -1.0
	scheduler.paused = false
	queue_redraw()


func _on_peer_ready_changed(ready_flag: bool, _peer_side: String) -> void:
	peer_ready = ready_flag
	var me_txt: String = "已准备" if my_ready else "未准备"
	var peer_txt: String = "已准备" if peer_ready else "未准备"
	online_status_text = "房间 %s（我：%s，对方：%s）" % [room_code, me_txt, peer_txt]
	queue_redraw()


func _on_peer_disconnect(grace_seconds: float) -> void:
	online_status_text = "对方连接中断，等待%d秒重连…" % int(grace_seconds)
	disconnect_countdown = grace_seconds
	scheduler.paused = true
	scheduler.paused_reason = "对方断线"
	queue_redraw()


func _on_opponent_win_by_dc(winner_side: String, _rc: String) -> void:
	# 服务器判定断线者负
	disconnect_countdown = -1.0
	battle_restart_countdown = -1.0
	var i_won: bool = (winner_side == my_side)
	simulator.running = false
	painter.override_winner = my_game_side if i_won else peer_game_side
	screen_mode = ScreenMode.RESULT
	queue_redraw()


func _on_start_match(seed: int, _side_role: String, my_deck: Array[String], peer_deck: Array[String]) -> void:
	# 服务器：双方都准备好了，下发共享种子 + 双方牌组
	peer_deck_ids = peer_deck.duplicate()
	online_mode = true
	scheduler.strict_wait = true
	scheduler.sides = [Config.PLAYER, Config.BOT]  # 固定顺序，确保双方命令执行顺序一致
	# 用服务器共享种子初始化 rng
	simulator.set_shared_seed(seed)
	# 启动对局
	_start_online_battle(my_deck, peer_deck)


func _on_peer_command(cmd_dict: Dictionary) -> void:
	# 服务器转发的远端命令，直接入队 scheduler（不需要加 input delay，因为远端已经按 delay 打在对应的 tick_scheduled 上）
	scheduler.enqueue_command_direct(cmd_dict)


func _on_result_received(winner_side: String, _rc: String) -> void:
	disconnect_countdown = -1.0
	battle_restart_countdown = -1.0
	simulator.running = false
	peer_rematch_requested = false
	peer_left_reason = ""
	if winner_side == "draw":
		painter.override_winner = ""
	else:
		var i_won: bool = (winner_side == my_side)
		painter.override_winner = my_game_side if i_won else peer_game_side
	screen_mode = ScreenMode.RESULT
	queue_redraw()


func _on_server_error(message: String) -> void:
	online_status_text = "服务器报错：%s" % message
	queue_redraw()


# Issue1: 对方申请了再战
func _on_peer_rematch() -> void:
	peer_rematch_requested = true
	online_status_text = "对方申请了再战"
	queue_redraw()


# Issue2: 对方主动退出了房间
func _on_peer_left(who: String) -> void:
	peer_left_reason = who
	disconnect_countdown = -1.0
	scheduler.paused = false
	if who == "host":
		online_status_text = "对方退出了房间（房间已解散）"
	else:
		online_status_text = "对方退出了房间"
	queue_redraw()


# Issue5: 战斗中断线重连后，服务器下发 RESUME_BATTLE 恢复战场
# 主机端（非重连方）：无 commands 数据，只需填充对方NO_OP并恢复倒计时
# 客机端（重连方）：有 commands 数据，需要回放所有命令恢复战场，填充双方滑动窗口NO_OP
func _on_resume_battle(commands: Array, seed_val: int, side_role: String, my_deck: Array[String], peer_deck: Array[String]) -> void:
	disconnect_countdown = -1.0
	battle_restart_countdown = -1.0
	peer_rematch_requested = false
	peer_left_reason = ""
	if side_role == "":
		# —— 非重连方（战场状态完好）——
		# 关键：断线+3秒恢复期间，对端的命令我们都没收到（对端当时不在线）
		# 需要为对方的未来 FILL_WINDOW 个 tick 预填 NO_OP 占位。
		# 真实命令到达后 enqueue_command 会覆盖尚未被 consume 的同tick占位，不会 desync
		var base_tick: int = scheduler.current_tick
		var FILL_WINDOW: int = 128  # ~ 2.1s 缓冲，足够命令往返
		for i in range(1, FILL_WINDOW + 1):
			var t: int = base_tick + i
			if not scheduler.has_side_command_for_tick(t, peer_game_side):
				var noop_peer: Dictionary = Command.no_op_command(t, peer_game_side)
				scheduler.enqueue_command(noop_peer)
		battle_restart_countdown = 3.0
		scheduler.paused = true
		online_status_text = "对方已重连，3秒后战斗恢复…"
		queue_redraw()
	else:
		# —— 重连方（主机或客机）：回放命令恢复战场 ——
		my_side = side_role
		_online_setup_sides()
		peer_deck_ids = peer_deck.duplicate()
		online_mode = true
		scheduler.strict_wait = true
		scheduler.sides = [Config.PLAYER, Config.BOT]
		simulator.set_shared_seed(seed_val)
		# 初始化战斗（会 reset scheduler、start_battle 等）
		_start_online_battle(my_deck, peer_deck)
		# 回放所有命令恢复战场状态
		if commands.size() > 0:
			_replay_commands(commands)
		# 填充双方滑动窗口的 NO_OP 占位（FILL_WINDOW ~ 2秒命令缓冲）
		var base_tick: int = scheduler.current_tick
		var FILL_WINDOW: int = 128
		for i in range(1, FILL_WINDOW + 1):
			var t: int = base_tick + i
			# 本方 NO_OP：入队 + 通过网络发给对端（真实PLAY_CARD覆盖会被对端enqueue替换）
			var noop_self: Dictionary = Command.no_op_command(t, my_game_side)
			scheduler.enqueue_command(noop_self)
			if i <= Config.INPUT_DELAY_TICKS:
				_send_local_command_net(noop_self)
			# 对方 NO_OP：只入队占位（真实命令到达后 enqueue_command 覆盖）
			if not scheduler.has_side_command_for_tick(t, peer_game_side):
				var noop_peer: Dictionary = Command.no_op_command(t, peer_game_side)
				scheduler.enqueue_command(noop_peer)
		# 3秒倒计时后恢复
		battle_restart_countdown = 3.0
		scheduler.paused = true
		online_status_text = "战场已恢复，3秒后战斗继续…"
		queue_redraw()


# 命令回放：按 tick 顺序执行所有命令并推进模拟，恢复到断线前的战场状态
func _replay_commands(commands: Array) -> void:
	# 按 tick 分组
	var cmds_by_tick: Dictionary = {}
	var max_tick: int = 0
	for raw_cmd in commands:
		if typeof(raw_cmd) != TYPE_DICTIONARY:
			continue
		var cmd: Dictionary = raw_cmd
		var tick: int = int(cmd.get("tick", 0))
		if tick > max_tick:
			max_tick = tick
		if not cmds_by_tick.has(tick):
			cmds_by_tick[tick] = []
		cmds_by_tick[tick].append(cmd)
	# 逐 tick 回放
	for tick in range(1, max_tick + 1):
		var tick_cmds: Array = cmds_by_tick.get(tick, [])
		for cmd in tick_cmds:
			simulator.execute_command(cmd, task_system)
		simulator.advance_time(Config.TICK_DT)
		task_system.check_mana(Config.PLAYER, simulator.player_mana())
		task_system.check_mana(Config.BOT, simulator.bot_mana())
		simulator.update_units(Config.TICK_DT)
		simulator.update_spell_effects(Config.TICK_DT)
		simulator.update_evolution_flashes(Config.TICK_DT)
		scheduler.current_tick = tick
	# 网络轮询（回放期间防止TCP超时）
	if net != null and net.is_attached():
		net.poll()


# Issue2: 客机退出后，房主点"回到房间"回到 ROOM_WAIT 等待新客机
func _back_to_room_wait() -> void:
	peer_left_reason = ""
	peer_rematch_requested = false
	peer_ready = false
	my_ready = false
	disconnect_countdown = -1.0
	battle_restart_countdown = -1.0
	painter.override_winner = ""
	simulator.running = false
	scheduler.reset()
	scheduler.strict_wait = true
	scheduler.paused = false
	scheduler.desynced = false
	screen_mode = ScreenMode.ROOM_WAIT
	online_status_text = "对方退出了房间，等待新玩家加入…"
	queue_redraw()


# ———————————————— V0.4 联机：房间/开始 流程辅助 ————————————————
func _online_setup_sides() -> void:
	# 约定：host 用 PLAYER 阵营，guest 用 BOT 阵营（双方显示上都显示自己在下方蓝方，对手在上方红方；绘制层已按 side 镜像）
	if my_side == "host":
		my_game_side = Config.PLAYER
		peer_game_side = Config.BOT
	else:
		my_game_side = Config.BOT
		peer_game_side = Config.PLAYER


# 确保与服务器的 TCP 已连接
func _ensure_connected() -> bool:
	if net == null:
		return false
	if net.is_tcp_connected():
		return true
	# 首次连接时挂载轮询 Timer（本地游戏不会创建 Timer）
	if not net.is_attached():
		net.attach_to_node(self)
	online_status_text = "正在连接服务器 %s:%d…" % [net.default_host, net.default_port]
	queue_redraw()
	net.connect_to_server("", 0)
	return true


func _try_create_room() -> void:
	if selected_card_ids.size() < Config.CARD_PICK_COUNT:
		online_status_text = "卡组不满6张，不能进入联机"
		queue_redraw()
		return
	if not _ensure_connected():
		return
	screen_mode = ScreenMode.ROOM_SETUP
	online_status_text = "连接服务器中…"
	queue_redraw()
	if not await _wait_for_connection():
		online_status_text = "连接服务器超时，请确认服务器已启动（默认 127.0.0.1:8765）"
		queue_redraw()
		return
	net.send_create_room()


func _try_join_room(code_text: String) -> void:
	if selected_card_ids.size() < Config.CARD_PICK_COUNT:
		online_status_text = "卡组不满6张，不能进入联机"
		queue_redraw()
		return
	if not _ensure_connected():
		return
	screen_mode = ScreenMode.ROOM_SETUP
	online_status_text = "连接服务器中…"
	queue_redraw()
	if not await _wait_for_connection():
		online_status_text = "连接服务器超时，请确认服务器已启动（默认 127.0.0.1:8765）"
		queue_redraw()
		return
	net.send_join_room(code_text)


# 等待 TCP 连接建立（最多 3 秒），返回 true=已连接，false=超时
func _wait_for_connection() -> bool:
	if net == null:
		return false
	if net.is_tcp_connected():
		return true
	var timeout: float = 3.0
	while not net.is_tcp_connected() and timeout > 0.0:
		await get_tree().create_timer(0.05).timeout
		timeout -= 0.05
	return net != null and net.is_tcp_connected()


func _toggle_ready() -> void:
	if net == null or not net.is_tcp_connected():
		return
	my_ready = not my_ready
	net.send_ready(my_ready, selected_card_ids)
	online_status_text = "已发送准备：%s（我方：%s，对方：%s）" % [room_code, "已准备" if my_ready else "未准备", "已准备" if peer_ready else "未准备"]
	queue_redraw()


# —— 联机模式下RESULT页点"再战"：通知对端并回到ROOM_WAIT ——
func _request_online_rematch() -> void:
	if net == null or not net.is_tcp_connected():
		_leave_room()
		return
	# 重置scheduler与模拟器残留状态
	scheduler.reset()
	scheduler.strict_wait = true
	scheduler.paused = false
	scheduler.desynced = false
	simulator.running = false
	bot_brain.reset()
	painter.override_winner = ""
	disconnect_countdown = -1.0
	peer_rematch_requested = false
	# 重置准备状态
	my_ready = false
	peer_ready = false
	# 使用已保存的当前牌组
	selected_card_ids = saved_deck_ids.duplicate()
	# Issue1: 发送 REMATCH 通知对端（而非 READY），服务器会广播 PEER_REMATCH
	net.send_rematch(selected_card_ids)
	# 回到房间等待界面
	screen_mode = ScreenMode.ROOM_WAIT
	online_status_text = "再战：已回到房间 %s，请双方重新点「准备」开始" % room_code
	queue_redraw()


func _leave_room() -> void:
	# Issue2: 先通知服务器主动退出（区别于断线），再断开TCP
	if net != null and net.is_tcp_connected() and room_code != "":
		net.send_leave_room()
	if net != null:
		net.disconnect_from_server()
	room_code = ""
	my_ready = false
	peer_ready = false
	peer_deck_ids.clear()
	online_mode = false
	scheduler.strict_wait = false
	scheduler.sides = [Config.PLAYER, Config.BOT]
	disconnect_countdown = -1.0
	battle_restart_countdown = -1.0
	peer_rematch_requested = false
	peer_left_reason = ""
	painter.override_winner = ""
	painter.controlled_side = Config.PLAYER
	selected_card_ids = saved_deck_ids.duplicate()
	screen_mode = ScreenMode.MAIN_MENU
	online_status_text = ""
	queue_redraw()


# —— 启动联机对局（start_match_received 之后）——
func _start_online_battle(my_deck: Array[String], peer_deck: Array[String]) -> void:
	# 联机时 host=PLAYER 阵营、guest=BOT 阵营
	var player_ids: Array[String]
	var bot_ids: Array[String]
	if my_side == "host":
		player_ids = my_deck.duplicate()
		bot_ids = peer_deck.duplicate()
	else:
		player_ids = peer_deck.duplicate()
		bot_ids = my_deck.duplicate()
	scheduler.reset()
	task_system.initialize(player_ids, bot_ids)
	simulator.start_battle()
	# 开局重置上一局可能污染的 UI 覆盖胜者显示（上局 RESULT 的 override_winner 会带进来）
	painter.override_winner = ""
	# 联机模式 bot_brain 不参与思考，但重置状态以防上一局残留影响
	bot_brain.reset()
	# 同步我的卡组到卡牌栏（host端=player端卡组，guest端=bot端卡组=my_deck）
	selected_card_ids = my_deck.duplicate()
	# 通知绘制层本机操控的阵营（影响法力条、任务进度、进化高亮等8处显示判断）
	painter.controlled_side = my_game_side
	# 联机模式：预发前 INPUT_DELAY_TICKS 个 tick 的 NO_OP（滑动窗口初始化）
	# 双方都预发后，前几个 tick 的命令已齐，可以连续推进不需等待网络
	if online_mode:
		for i in range(1, Config.INPUT_DELAY_TICKS + 1):
			var noop_cmd: Dictionary = Command.no_op_command(i, my_game_side)
			scheduler.enqueue_command(noop_cmd)
			_send_local_command_net(noop_cmd)
	# 选第一张卡做默认选中；注意用 selected_card_ids（我的卡组），不要用 player_ids（guest端是对手卡组）
	selected_battle_card_id = selected_card_ids[0] if selected_card_ids.size() > 0 else ""
	painter.info_card_id = selected_battle_card_id
	last_issued_checksum_tick = -1
	screen_mode = ScreenMode.BATTLE
	online_status_text = ""
	queue_redraw()


# —— 联机：玩家发出的本地命令同时发给服务器 ——
func _send_local_command_net(cmd_dict: Dictionary) -> void:
	if not online_mode:
		return
	if net == null:
		return
	net.send_command(cmd_dict)


# ———————————————— V0.4 联机：断线倒计时 tick ————————————————
func _tick_disconnect_countdown(dt: float) -> void:
	if disconnect_countdown > 0.0:
		disconnect_countdown = maxf(0.0, disconnect_countdown - dt)
		if disconnect_countdown <= 0.0:
			disconnect_countdown = 0.0
			online_status_text = "等待重连超时，服务器将判负（如未跳转请手动返回）"


# —— 按钮绘制（不修改 CanvasHelpers，就地实现）——
func _draw_button(r: Rect2, text: String, enabled: bool, accent: Color, bg: Color) -> void:
	var fill: Color = bg if enabled else Color(0.14, 0.16, 0.20, 0.70)
	var border: Color = accent if enabled else Color(0.26, 0.28, 0.32)
	helpers.draw_panel(self, r, fill, 6.0, border, 1.2)
	var text_col: Color = Color(0.96, 0.96, 0.96) if enabled else Color(0.50, 0.54, 0.60)
	var text_rect: Rect2 = Rect2(r.position + Vector2(8.0, r.size.y * 0.5 - 10.0), Vector2(r.size.x - 16.0, 20.0))
	var font_size: int = 14
	if r.size.y >= 48.0:
		font_size = 16
	helpers.draw_text_line(self, text, text_rect, font_size, text_col, HORIZONTAL_ALIGNMENT_CENTER)

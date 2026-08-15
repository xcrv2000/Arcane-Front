# 游戏配置层：集中存放 V0.1/V0.2 原型的全部平衡常量、地图尺寸、Bot 牌组与美术路径。
# 设计师可读、可编辑的数值仍以 `开发文档/设计/设计师文档.md` 为说明入口；
# 此处是工程运行时引用的单一常量来源，避免散落在多个脚本中。
#
# 使用方式：在各脚本中 `const Config = preload("res://scripts/config/game_config.gd")`，
# 再以 `Config.XXX` 访问。沿用项目既有的 preload 风格，不使用 class_name。
extends RefCounted

# —— 阵营标识 ——
const PLAYER: String = "player"
const BOT: String = "bot"

# —— 选卡与地图 ——
const CARD_PICK_COUNT: int = 6
const MAP_WIDTH: float = 56.0
const MAP_HEIGHT: float = 100.0

# —— 费用 ——
const MANA_MAX: float = 10.0
const STARTING_MANA: float = 5.0
const MANA_PER_SECOND: float = 0.5

# —— 基地 ——
const BASE_MAX_HP: float = 300.0
const BASE_RADIUS: float = 4.8

# —— 单位表现缩放（仅影响表现与碰撞半径，不影响法术范围与基地半径）——
const UNIT_RADIUS_SCALE: float = 2.0

# —— 单位美术（版本线外表现层实验）——
const UNIT_ART_ROOT: String = "res://assets/units/"
const UNIT_ART_FRONT: String = "front"
const UNIT_ART_BACK: String = "back"
const UNIT_ART_HEIGHT_SCALE: float = 3.0
const UNIT_ART_FOOT_OFFSET: float = 1.05

# —— 地形与部署区 ——
const RIVER_Y: float = 50.0
const PLAYER_DEPLOY_MIN_Y: float = 54.0
const BOT_DEPLOY_MAX_Y: float = 46.0

# —— Bot 思考节奏 ——
const BOT_THINK_MIN_DELAY: float = 1.45
const BOT_THINK_MAX_DELAY: float = 2.7

# —— Bot 固定牌组（trial 原型策略）——
const BOT_DECK_IDS: Array[String] = [
	"spark_swarm",
	"shield_pair",
	"cleaver",
	"quick_archer",
	"ember_mage",
	"arcane_giant"
]

# —— V0.4 锁步联机默认参数（可随手感调整）——
const TICK_RATE: int = 60               # 模拟 tick 频率 Hz
const TICK_DT: float = 1.0 / float(TICK_RATE)  # ≈0.0167s 每 tick
const INPUT_DELAY_TICKS: int = 4       # 输入延迟 tick（4 tick ≈ 67ms @60Hz）
const DESYNC_CHECK_INTERVAL: int = 30  # 每 30 tick（0.5s）做一次校验和比对

# —— V0.4 定点数精度约定（P1 引入）——
const FP_SCALE: int = 1000              # Q*1000 定点精度
const FP_SCALE_F: float = 1000.0

# —— V0.4 断线策略（P4 引入）——
const DISCONNECT_PAUSE_SECONDS: float = 30.0  # 断线暂停等待时长，超时判负

# —— V0.5 弱网优化参数（新增）——
# NO_OP 预发窗口：每 tick 预发到未来这么多 tick（60 tick = 1 秒缓冲）
# 越大越抗抖，但断线恢复时的 NO_OP 占位越多（真实命令覆盖即可，不影响结果）
const NO_OP_AHEAD_WINDOW: int = 60
# 命令冗余发送：每次发送命令时附带最近 N 条历史命令（防止丢包/重传延迟）
# 冗余越多越抗抖，但带宽开销变大；推荐 8~16
const COMMAND_REDUNDANCY_COUNT: int = 12
# 最大容忍暂停 tick 数：超过此数仍缺命令时，主动请求服务器补全
const MAX_WAIT_TICKS_BEFORE_REQUEST: int = 30  # 500ms 仍缺命令就请求补全
# 命令请求冷却：两次主动请求之间的最小间隔 tick，避免请求风暴
const COMMAND_REQUEST_COOLDOWN_TICKS: int = 20  # ~333ms
# 自适应输入延迟范围：根据网络抖动动态调整
const INPUT_DELAY_MIN_TICKS: int = 4
const INPUT_DELAY_MAX_TICKS: int = 12
# 抖动统计窗口：统计最近多少个 tick 的命令到达延迟
const JITTER_WINDOW_SIZE: int = 120  # 2 秒窗口

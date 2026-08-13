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

# AI 单位美术生产流程

状态：trial revision required（低细节移动端基准待确认）
最后更新：2026-08-13
创建者：mike/AI单位美术流程

本流程用于为战场生物单位生产正面/背面图片，并在 Godot 中替换早期几何占位表现。该工作不纳入当前版本开发时间线；它只改变表现层，不改变碰撞半径、战斗数值、费用、任务/进化逻辑或法术表现。

## 已确认方向

- 单位基准风格：原盾卫样张 2C 已因手机端过于模糊而不再作为正式单位生产基准；后续改用低细节移动端方向。
- 当前候选基准：`shield_pair_low_detail_candidate_20260813` 与 `shield_pair_ultra_low_detail_candidate_20260813`，需项目负责人确认其中一档后才能批量替换正式 12 个单位资源。
- 风格关键词：明亮卡通、比例夸张、轮廓清晰、极低细节、干净大块面、小尺寸可读。
- 题材关键词：主体是奥术，可按单位主题混入机械、黑客、能量核心等元素。
- 视角规则：我方单位永远显示背面；敌方单位永远显示正面。
- 姿态规则：单位当前没有战斗动画，因此必须使用静态站桩或静态悬浮姿态；不要使用走路、冲刺、出招、被风吹动的动态姿态。
- 移动端清晰度规则：以 32-45 px 高度为主要验收尺寸；缩小后仍应首先读出单位类别，不追求大图细节观赏性。
- 剪影规则：通过少数大形状增强辨识度；每个单位优先保留 2-3 个主读点，不通过碎切面、小纹路、小宝石、小螺丝、密集电路线和复杂徽记增加复杂度。
- 阵营规则：蓝/红阵营识别环由代码单独绘制；图片本身不得烘焙阵营色。
- 样张 1 方向：保留为未来地图、边框与 UI 参考，不作为单位生产线基准。

## 资源边界

Godot 只消费透明 PNG：

- `游戏工程/assets/units/<art_id>_front.png`
- `游戏工程/assets/units/<art_id>_back.png`

AI 原始源图保留在：

- `游戏工程/assets/units/source_sheets/<art_id>_sheet.png`

源图是左右构图：左侧为正面，右侧为背面。正式 PNG 由处理脚本切分和抠绿生成；不要让游戏直接引用源图。

## 当前资源清单

| art_id | 单位 | 说明 |
| --- | --- | --- |
| `spark_swarm` | 星屑群 | 单个星屑群成员，不是一整群。 |
| `spark_drift` | 星屑漂流 | 星屑群的轻微进化形态。 |
| `shield_pair` | 盾卫 | 已确认的 2C 基准样张。 |
| `steadfast_guard` | 坚盾护卫 | 盾卫的更厚重进化形态。 |
| `cleaver` | 旋刃兵 | 大月牙/旋刃为主读点。 |
| `wheel_blade` | 轮刃兵 | 旋刃兵的轮状刃进化。 |
| `quick_archer` | 连弩手 | 连弩/机械弓为主读点。 |
| `roaming_archer` | 漫游弓手 | 连弩手的多目标进化。 |
| `ember_mage` | 秘火手 | 大火核法杖/秘火核心为主读点。 |
| `fire_thrower` | 投火手 | 秘火手的投火器进化。 |
| `arcane_giant` | 奥术巨像 | 大头、巨拳、胸口核心为主读点。 |
| `arcane_power_giant` | 奥能巨像 | 奥术巨像的能量核心进化。 |

当前正式资源仍是首批 2C 路线 trial 版本，手机端可读性不足；low/ultra 低细节候选确认前不要覆盖正式资源。

低细节候选文件：

- 源图：`游戏工程/assets/units/source_sheets/candidates/shield_pair_low_detail_candidate_20260813_sheet.png`
- 正面：`游戏工程/assets/units/candidates/shield_pair_low_detail_candidate_20260813_front.png`
- 背面：`游戏工程/assets/units/candidates/shield_pair_low_detail_candidate_20260813_back.png`
- 源图：`游戏工程/assets/units/source_sheets/candidates/shield_pair_ultra_low_detail_candidate_20260813_sheet.png`
- 正面：`游戏工程/assets/units/candidates/shield_pair_ultra_low_detail_candidate_20260813_front.png`
- 背面：`游戏工程/assets/units/candidates/shield_pair_ultra_low_detail_candidate_20260813_back.png`
- 小尺寸 QA 预览：`开发文档/美术/AI单位美术低细节盾卫候选预览.png`

当前试装状态：

- `shield_pair` 正式正面/背面/源图已临时替换为 low 候选，供项目负责人游戏内观察。
- 原 `shield_pair` 2C 正面/背面/源图已备份为：
  - `游戏工程/assets/units/candidates/shield_pair_2c_legacy_20260813_front.png`
  - `游戏工程/assets/units/candidates/shield_pair_2c_legacy_20260813_back.png`
  - `游戏工程/assets/units/source_sheets/candidates/shield_pair_2c_legacy_20260813_sheet.png`
- 其它 11 个正式单位资源未替换。

## 生成提示词模板

使用内置 `imagegen`，不要使用 CLI fallback，除非项目负责人明确要求。新单位建议先用已确认的低细节盾卫候选作为风格参考；如果低细节候选尚未被确认，不要批量生产正式资源。

```text
Use the referenced low-detail shield guard image as the strict style reference:
bright flat anime-boardgame sticker sprite, very simple bold shapes, thick dark outline,
clean cel shading, readable at 32px mobile battlefield size, no painterly texture,
no busy detail.

Asset type: mobile battlefield unit sprite source sheet.
Subject: <单位中文名> / <art_id>, <一句话说明单位定位和主轮廓读点>.

Pose constraints: calm static planted or hovering pawn pose for a sprite that slides
without animation. No walking, no running, no lunging, no attack action, no motion trails.

Design constraints: icon-first mobile readability, simple bold silhouette, readable at 32px.
Keep only 2-3 large identity shapes: <列出主轮廓读点>.
Use 3-5 large color masses only. White/gold/black arcane-tech design with sparse,
large neutral glow accents.
No red or blue team colors baked in. Avoid tiny text, tiny screws, dense circuit lines,
thin cyan wires, complex shield emblems, fragmented armor, bevel noise, small gemstones,
many small ornaments, or decorative internal lines.

Show exactly two matching full-body views of the same unit side by side:
left front view for enemy display, right back view for player display.
Same scale, same costume, same static pose, generous padding.
Pure perfectly flat chroma key green #00FF00 background only;
no shadows, no labels, no UI, no watermark.
```

进化形态额外加两条约束：

```text
Use image 1 as the strict overall unit sprite style reference,
and image 2 as the base character reference for <基础单位>.

It must clearly be the same unit upgraded, not a new character.
Evolution changes: <只列 2-4 个在基础形态上的微调>.
```

## 后处理命令

源图确认后，先保存为：

```powershell
游戏工程/assets/units/source_sheets/<art_id>_sheet.png
```

再运行：

```powershell
python tools/ai_unit_art/process_unit_sheet.py --sheet "游戏工程/assets/units/source_sheets/<art_id>_sheet.png" --unit-id "<art_id>" --out-dir "游戏工程/assets/units"
```

脚本会输出：

- `游戏工程/assets/units/<art_id>_front.png`
- `游戏工程/assets/units/<art_id>_back.png`

脚本会检查透明角和主体覆盖率。如果发现明显绿边，可先尝试：

```powershell
python tools/ai_unit_art/process_unit_sheet.py --sheet "游戏工程/assets/units/source_sheets/<art_id>_sheet.png" --unit-id "<art_id>" --out-dir "游戏工程/assets/units" --edge-contract 1
```

## Godot 接入约定

- `游戏工程/scripts/v01/v01_game.gd` 会按 `art_id + view` 读取图片，并用 `Image.load_from_file()` 创建运行时纹理。
- 基础单位使用卡牌 `id` 作为 `art_id`。
- 进化单位使用卡牌运行时的 `evolved_id` 作为 `art_id`。
- 玩家侧显示 `<art_id>_back.png`。
- Bot 侧显示 `<art_id>_front.png`。
- 缺少图片时自动 fallback 到旧的几何占位图形。
- 当前实现不依赖提交 `.png.import` 文件；Godot 编辑器后续若生成导入缓存，不应改变本流程的正式资源命名。
- 阵营环、生命条、碰撞半径仍由代码单独控制；图片不参与碰撞和数值。

## 验收清单

- 左侧正面、右侧背面，不要反。
- 姿态必须能“无动画平移”。
- 缩到 30-45 px 高度时仍能读出主轮廓。
- 32 px 高度下，单位应优先读出 2-3 个大形状；若只能看到“花纹/噪声”，该图不合格。
- 进化形态必须像基础形态的微调，不要像新角色。
- 不把红/蓝阵营色烘焙进角色。
- 抠图后四角透明，无明显绿边。
- Godot headless 能加载主场景。

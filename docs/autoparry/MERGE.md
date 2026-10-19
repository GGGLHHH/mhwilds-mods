# 合并规格：自动放刀并入 AutoGuardGS（v1.5）

> 状态：规格稿，2026-10-11。本阶段只写本文：不改代码、不部署、不动游戏目录、不动 git 状态（分支 `feat/auto-offset-predict`，大量未提交改动原样保留）。实现阶段按本文做，做完在本文末尾追加「实现记录」一节（写法同 V16 第 13、14 节）。
>
> 实现与集成（2026-10-12）：已按本文实现、接通并跑完第 6.8 节的验收（逐刀等价 121 个场景 0 差异），**还没部署**。结果、和本文的出入见末尾「实现记录」；正文里写错的几处原地改了，标「实现记录更正」。
>
> 审查修订（2026-10-12，两份审查之后）：放刀部分一行没改；修了防御 / 配置 / 菜单的 3 处运行时边角（快照读到一半抛错时防御段照 v1.4.2 自己读、读配置失败时不拿默认值盖文件、菜单分块出错后能恢复），补了 21 个场景（11 个逐刀等价、10 个只在合并模式跑），改了 `check.sh` 的正则、分析脚本 D16 的 sidmis 项、mock 的动作编号，文档按审查补齐。逐条处理和重跑结果见末尾「实现记录」第 8 小节；正文改动处标「审查修订」。
>
> 依据：
> - `CLAUDE.md`、`README.md`、`docs/NOTES.md`；
> - `docs/autoparry/V16.md`（v1.6 规格，含第 13、14 节集成与审查修订）、`docs/autoparry/SPEED.md`（第 7.1.1 节 A 阶段结果）；
> - `src/reframework/autorun/AutoGuardGS.lua`（v1.4.2，562 行，md5 `85fedcc0…`）、`src/reframework/autorun/AutoParryGS.lua`（v1.6，998 行，md5 `a83527d9…`）。2026-10-11 核对过：两个文件和游戏 autorun 里正在跑的逐字节相同；
> - `tools/mock/`（`run.lua`、`game_sim.lua`、`mock_ref.lua`、`scenarios.lua`、`e2e_analyze.py`）、`tools/apcal_analyze.py`（1.4）、`tools/check.sh`、`tools/deploy.sh`；
> - 游戏日志 `re2_framework_log.txt`（只读）：2026-10-11 17:59 起的 v1.6 试打，session 1791712779。
>
> 用户已定（本轮必须照做）：
> 1. **合成一个脚本**：放刀逻辑并入 `AutoGuardGS.lua`，删掉独立的 `AutoParryGS.lua`。只有一个菜单（「大剑自动防御」里多一节「自动放刀」），只有一个配置文件 `AutoGuardGS.json`。旧的 `AutoParryGS.json` 在首次加载时自动迁移进来。
> 2. **研究记录精简成可选调试日志**：
>    - 去掉 JSON 写盘和研究用的计数、记录种类；
>    - 默认不记；打开 AutoGuardGS 已有的「调试日志」开关时，只写放刀和结局两类行，外加一行 HDR；错误行照常总写；
>    - 日志格式要让 `tools/apcal_analyze.py` 还能读（必要时改分析脚本）；
>    - 菜单保留四个数：放了几刀、接住几刀（分 26 / 27）、被弹开几次、没接住几次；状态行也保留。
> 3. **优化**：
>    - 去掉 rc / v1.5 时代的兼容字段和升级路径、研究专用逻辑；
>    - 代码更短、更清楚；
>    - **放刀行为（何时放、放不放）必须与 v1.6 逐刀一致**。这是本轮最重要的验收标准。
> 4. **测试环境收尾**（游戏目录由主线程负责）：
>    - 两个探针从游戏 autorun 撤掉；
>    - 部署时撤掉游戏目录里旧的 `AutoParryGS.lua`；
>    - `tools/deploy.sh` 要能处理已废弃的文件。
> 5. **文档**：
>    - README 写上自动放刀；
>    - NOTES 补全这几轮的结论；
>    - B 阶段验收没做完，如实写明。
>
> 标注：**实测**指由数据或日志直接得出（带样本量或出处），**推测**指由源码、类型库或机制推断、没有直接测到。帧 = 1/60 s。

---

## 0. 一页摘要

| 项 | 现在 | 合并后 | 节 |
|---|---|---|---|
| 脚本 | 两个文件：`AutoGuardGS.lua` v1.4.2、`AutoParryGS.lua` v1.6 | **一个文件：`AutoGuardGS.lua` v1.5**，放刀规则版本仍记 `1.6` | 1 |
| 放刀规则 | E5c 时机、L = 28、L_min 22、该接过滤 g1、否决、CREDIT 1.3 s、引用记账、错误分级与自停 | **一处不改**，用逐刀等价测试保证 | 2.7、6.3 |
| 配置 | 两个文件：`AutoGuardGS.json`、`AutoParryGS.json`（cfg_ver = 3） | `AutoGuardGS.json` 加两个键 `auto_parry`、`parry_lead` | 3 |
| 配置迁移 | — | 首次加载从旧文件迁一次、立刻写回；旧文件只读、不动 | 3 |
| 记录 | 12 种行全部总写日志，另有 JSON 分块写盘 | 调试日志开着才写 FIRE、RES 和一行 HDR；ERR、RED 总写；没有 JSON | 4 |
| 日志标签 | `[AutoParryGS]` | 沿用，含义变成「放刀记录」；分析脚本做三处小改 | 4.3、4.4 |
| 菜单 | 两个树节点 | 一个「大剑自动防御 v1.5」，中间一节「自动放刀（实验）」 | 5 |
| 测试 | v1.6 的 133 个场景 | 133 个原样跑归档的 v1.6，作为参照组 | 6 |
| | | 再把合并脚本在调试日志开、关两种情况下各跑一遍，逐刀比较 | 6 |
| | | 补防御功能、配置迁移、两部分交互的场景 | 6 |
| 部署 | `deploy.sh` 只复制文件 | 加废弃清单：把游戏里旧的 `AutoParryGS.lua` 挪到 `reframework/autorun_disabled/`（不删） | 7 |

**放刀部分不变的东西**（逐项对 V16）：

- 触发量：Q 按 E5c 算。从登记后第一个帧回调起读 CoreState，用条目 hs 自己的递减当时钟，C < 1 按 1 算，首帧读不到 C 的结果永不放刀。
- 候选条件：`22 ≤ Q ≤ L`、`0 ≤ he−hs ≤ 60`、不是联机副本、通过该接过滤（读不准就不放，fail-closed）；取 Q 最小的那条。
- 否决按原始 hs：视野是 hs ≤ 90 且 he ≥ 0；视野里有长窗口、抓取或 SKILL_GUARD 家族的攻击，整帧不放。
- 连续成立的帧合并成一次放刀（streak），不设超时。
- 跟踪与丢弃：最多 32 条；距最后一条消息 8 s 丢；全部条目 he < −30 且距消息 ≥ 1 s 丢。
- 结局：CREDIT 1.3 s 内进 (2,26)/(2,27) 记接住，进 (2,25) 记被弹（RECOIL）。
- 错误分级：核心模块 10 s 内出错 3 次标红；帧逻辑连续 30 帧出错自停；读主角抛错有 1.5 s 容忍期。
- 只 add_ref、不手动 release。
- 唯一有副作用的游戏调用是 `changeActionRequest(0, (2,23), false)`；只钩 `receiveGameMessage` 一个函数。

**防御部分不变的东西**：v1.4.2 的全部功能、配置键、菜单控件 ID，以及共享参数的还原路径。

---

## 1. 合并后的文件结构与版本

### 1.1 版本号：AutoGuardGS v1.5；放刀记录的 HDR 里 `ver` 仍写 `1.6`

- **AutoGuardGS 从 v1.4.2 升到 v1.5**，理由：
  1. **对 AutoGuardGS 是加功能**。
     - 新增的东西：一节菜单、两个配置键、一个钩子（`receiveGameMessage`）。
     - 不变的东西：已有功能和配置键的行为一个都不改（第 3 节）。已有用户的 `AutoGuardGS.json` 原样能用，不需要改动。
     - 按惯例这是升次版本号，不到 2.0。
  2. **补丁号（1.4.3）不够**：多了一整块功能，还多了一次配置迁移。
  3. **会和旧版本号撞名**：AutoParryGS 有过 v1.5 / v1.5.1（旧规则：hs 口径，L = 26 / 30）。处理办法：
     - 文档和日志里提到 AutoGuardGS 的版本时，一律带脚本名（「AutoGuardGS v1.5」）；
     - 放刀记录的 HDR 里，`ver` 写的是**放刀规则的版本**，仍是 `1.6`；另加字段 `host=AutoGuardGS-v1.5`，标明是哪个脚本写的；
     - 分析脚本只按 HDR 的 `ver` / `rule` 认规则代。HDR 绝不能写成 `ver=1.5`：否则分析脚本会按 AutoParryGS 1.5 的冻结值判（L = 26、hs 口径），整段判错。
  - 如果用户想彻底避开撞名，也可以改叫 2.0。这只影响 `VERSION` 常量和菜单标题，本文其余部分不变。
- **放刀规则版本**用常量 `PARRY_RULE = "1.6"`，写进 HDR 的 `ver`。
  - 什么时候改：规则（何时放、放不放）变了才改；只改代码结构或记录格式不改。
  - 本轮逐刀等价测试（6.3）通过，就说明规则没变，所以仍写 1.6。

### 1.2 `AutoGuardGS.lua` 的分节顺序

| 节 | 内容 | 来源 |
|---|---|---|
| §0 头注释 | 两部分各自的原理（防御：原 v1.4.2 头注释；放刀：原 v1.6 头注释，压缩后保留 E5c、该接过滤、否决、L、结局、引用记账、只有一个副作用调用、联机未测）；调试日志写什么；文档指针（NOTES、V16、本文） | 两份头注释合并 |
| §1 常量与小工具 | 常量：`TAG = "[AutoGuardGS] "`、`REC_TAG = "[AutoParryGS]"`、`VERSION = "v1.5"`、`PARRY_RULE = "1.6"`、`CONFIG_PATH = "AutoGuardGS.json"`、`LEGACY_PARRY_CONFIG = "AutoParryGS.json"` | 新 |
| | 小工具：`finite`、`int_s`、`clean_str`、`hex`、`safe_fmt` | v1.6 |
| | 计时：`timed` 和 `prof`（frame、dmg_pre、dmg，加一项 msg） | v1.4.2 |
| §2 放刀记录与错误分级 | 记录：`SPEC`（只剩 HDR、FIRE、RES、ERR、RED）、`rec()`（第一次写放刀记录前补写 HDR） | v1.6 精简 |
| | 错误分级：`note_error`、`set_red`、`CORE`、`mod_off`、`self_stop_init` | v1.6 精简 |
| | 防御的警告：`guard_warn(kind, msg)`，每类每次加载最多写 20 行 | 新 |
| §3 配置 | 默认值表、`load_config()`、`migrate_parry_config()`、`save_config()`，加载时就执行 | 合并，见第 3 节 |
| §4 主角与动作 | `master_player()`、`read_frame()`（每帧开头读一次快照）、`current_action()`（钩子里现读）、`make_action_id()` | 合并 |
| §5 自动防御 | `init_guard()`：类型、枚举、钩子注册，整个包在 pcall 里，见 1.5 | v1.4.2 原样，结构调整只有这一行列的几处 |
| | 逻辑不变的部分：能不能举剑、防御角度、无限蓄力、自动肩撞、`restore_hit_state()`（原名 `release()`）、受击钩子、锁血钩子 | v1.4.2 原样 |
| | `guard_frame(snap)`：原来帧回调里的防御部分 | v1.4.2 |
| §6 自动放刀 | `init_parry()`：类型与枚举，失败就 `self_stop_init` | v1.6 |
| | 预告跟踪（`on_message` 和消息钩子）、速度（E5c）、条目读取与该接过滤（`catchable`）、规则（`consider` / `process_track` / `evaluate`） | v1.6 |
| | 放刀与结局（streak、`res_wait`）、`parry_frame(now, ok, snap)`、`self_stop` | v1.6 |
| §7 帧回调 | 唯一一个 `re.on_pre_application_entry("UpdateBehavior")`，顺序见 1.3 第 3 行 | 合并 |
| §8 Reset 与存配置 | `re.on_script_reset`、`re.on_config_save` | 合并 |
| §9 菜单 | `re.on_draw_ui`，见第 5 节 | 合并 |
| §10 加载完成 | 写 `[AutoGuardGS] v1.5 loaded`（原样，总写）；调试日志开着时紧接着写 HDR | — |

这样排的原因：

- §2 放在 §3 前面：读配置出错要走 `note_error`（mod = cfg）。
- §3 放在两部分初始化前面：两部分都要读配置。
- 防御（§5）放在放刀（§6）前面：和原来的加载、运行顺序一致（1.4）；读代码时也先看到简单的那部分。
- 改名 `release()` → `restore_hit_state()`：这个函数是还原状态标志和防御角度的，和 REF 的 release（扣引用）无关。合并后同一个文件里有大段「不手动 release」的注释，改名避免误读。纯改名，不改逻辑。

### 1.3 两部分共享的东西

| 共享项 | 怎么共享 | 和原来比 | 为什么不改变行为 |
|---|---|---|---|
| 主角读取 | 每帧开头一次 `pcall(read_frame)`，调用顺序和 v1.6 的 `read_hunter` 一字不差：PlayerManager → getMasterPlayer → get_Character → get_address → get_WeaponType → get_BaseActionController → get_CurrentActionID → `_Category` / `_Index`。读到的 `{ hunter, addr, gs, cat, idx }` 交给两段帧逻辑 | v1.4.2 帧里自己读主角（get_WeaponType 只在无限蓄力开着时读，动作 ID 只在有肩撞请求时读）；现在改用快照 | 帧开头到两段逻辑之间没有游戏更新，读到的值相同。读失败时见下面 3 条 |
| 读主角失败时 | 放刀段：照 v1.6。容忍期 1.5 s 内这一帧当作不存在；超过就按帧逻辑出错计，连续 30 帧自停 | — | 同 v1.6 |
| | 防御段：快照抛错时照 v1.4.2 自己再读一遍，只读这一帧用得到的（主角；武器只在无限蓄力开着时读；动作只在有肩撞请求时读），之后按 v1.4.2 处理；自己读也抛错 → 写警告（每类 20 行）、`tackle = nil` | 审查修订：原稿是直接 `tackle = nil`、跳过这一帧。快照比 v1.4.2 多读武器、动作控制器，这几项出错时 v1.4.2 照常补血、照常还原 `_OverheatTime`，跳过的话关无限蓄力后的还原要拖到故障结束 | 读法、顺序同 v1.4.2；mock 场景 `guard_read_fault`、`guard_tackle_read_fault` |
| | 钩子里照旧现读主角和动作 | — | 帧中途动作可能已经变了 |
| 动作 ID | 帧回调里用快照的 `(cat, idx)`；`make_action_id` 共用：(1,141) 防御、(2,15)/(2,17) 肩撞、(2,23) 上捞斩 | `update_tackle` / `charge_index` 在帧回调里改用快照，省 2~3 次 REF 调用 | 值相同；动作 ID 读不到时 v1.4.2 是抛错进 pcall、清掉 tackle，现在直接清掉 tackle，结果一样 |
| 帧回调 | 只有一个，顺序固定：`prof_report` → `restore_hit_state`（防御状态还原兜底，原样排在最前）→ `read_frame` → `guard_frame` → `parry_frame` | 原来是两个回调，AutoGuardGS 的先跑（1.4） | 先后顺序和原来相同；每段各自 pcall，一段出错不影响另一段 |
| 错误处理 | **放刀**：v1.6 的分级原样。核心模块 = msg、frame、fire；可选模块 = master、items、speed、filter、filter_enum、cfg、ui | 删了 json 模块（已经不写 JSON）；ERR 不再排队 | 分级规则不变（2.7） |
| | **防御**：v1.4.2 的「写警告 + 还原状态」 | 加了上限：每类每次加载最多 20 行 | 只改写日志的次数 |
| | 防御出错不进放刀的红黄计数；放刀自停不停防御 | — | 1.4 |
| 菜单 | 一个树节点；两部分共用「清零统计」和「调试日志」 | — | 第 5 节 |
| 配置 | 一个表、一个文件，加载时读一次，存配置时写一次（迁移时多写一次） | — | 第 3 节 |
| 计时 | `prof` 加一项 msg（消息钩子） | 删了 v1.6 只给 STAT 用的 `hook_ms`、`lua_win` | 只读 `os.clock`，不调游戏 |

### 1.4 防御与放刀的交互：谁先谁后，什么条件下互不打扰

**先后顺序**

- 原来两个脚本时：REF 按文件名字母序加载 autorun 里的脚本。实测（日志）：17:59:39.386 ATP，.386 AutoGuardGS，.389 APCal，.390 AutoParryGS。帧回调按注册先后执行，所以 AutoGuardGS 的帧逻辑先于 AutoParryGS。
- 合并后：在同一个回调里，防御段在前、放刀段在后，和原来相同。
- 钩子没有共用：受击的两个钩子和锁血的两个钩子属于防御，消息钩子属于放刀。

**两部分在抵消蓄力 (2,21)/(2,22) 时的关系**

| 情况 | 结论 | 依据 |
|---|---|---|
| 抵消蓄力中挨打 | **不出自动肩撞**：肩撞只认 (2,5)/(2,6)/(2,7)/(2,11)（`CHARGE_TO_TACKLE`）。(2,21) 里受击钩子的 `charge_index` 为 nil，不登记肩撞请求 | 代码 |
| 动作请求 | 自动放刀只在 (2,21)/(2,22) 时请求 (2,23)；肩撞只在 (2,5..11) 时请求 (2,15)/(2,17)。两组动作不相交，而两段读的是同一帧开头的快照，所以**同一帧最多发一个 changeActionRequest**（mock 断言，6.2） | 代码 |
| 防御角度 | 抵消动作族 (2,21)~(2,29) 里不改写（v1.4.1 原样），放刀期间共用的 Wp00ActionParam 不被防御改动 | 代码；v1.4.1 日志 16:12:47.045 实测 |
| 强开防御标志 | 抵消蓄力和上捞斩带 SUPER_ARMOR，`respect_armor` 默认开，所以跳过（mock 的动作模型也是这样）。如果关掉 `respect_armor`，就由行为表决定：(2,21)/(2,23) 里 `checkContainsActionInCurrentBTable` 返回什么没测过（推测 false）。两个脚本一起跑时就是这样，合并前后完全相同；本轮不改，列入第 9 节 | 推测 |
| 无限蓄力（测试开关） | `_ChargeParam_Parry._OverheatTime` 也会改成 99999，抵消蓄力不会过热自动放出。只影响能按住多久，不影响放不放刀 | 代码 |
| 锁血（测试开关） | 跳过 requestDamage。放刀的结局按动作 ID 判，不看血量，所以不受影响 | 代码 |

**互不打扰的条件**（必须全部成立；6.5 的 `merge_interaction` 逐条测）：

1. 两部分请求的动作集合不相交，同一帧最多一个动作请求。
2. 防御只在受击钩子里改状态标志和防御角度，并且有三处还原：结算后、每帧开头、Reset。放刀不改任何共享参数。
3. 放刀唯一有副作用的调用是 `changeActionRequest(0, (2,23), false)`；防御的副作用和 v1.4.2 一样，清单见 6.2 第 4 条。
4. 两部分各自 pcall：任何一边出错、自停、初始化失败，另一边照常工作。
5. 防御出错不计入放刀的红黄状态；放刀自停不停防御。

### 1.5 加载顺序与出错隔离

**为什么要专门处理**：原来两个文件互相独立，一个在加载时抛错（比如游戏更新后找不到某个类型），另一个照常跑。合并成一个文件后，一处抛错会连带另一半一起失效。

**怎么隔离**：

- **防御部分**：`init_guard()` 整个包在 pcall 里，做三件事：查类型、读枚举、注册 4 个钩子。
  - 失败时：设 `guard_ready = false`，写一行 `log.warn`，菜单的防御一节显示「自动防御初始化失败：<原因>；自动放刀不受影响」。
  - 已经注册上的防御钩子，函数体第一句先检查 `guard_ready`。
- **放刀部分**：`init_parry()` 照 v1.6 原样。类型、枚举或钩子注册失败 → `self_stop_init`：写一行 RED（why=init），状态显示「已自停」，防御照常。
- **其他各段**：配置读写、菜单、Reset、存配置各自 pcall。
- **顶层禁止裸调**：文件最外层不许有不在 pcall 里的游戏调用。

**加载顺序**：读配置 → `init_guard` → `init_parry` → 注册帧回调、Reset 回调、存配置回调、菜单回调 → 写「loaded」那行。

**验收**：6.5 的 `merge_init_isolation_guard`、`merge_init_isolation_parry` 两个场景。

### 1.6 规模与代码要求

- **行数**：目标 ≤ 1250 行（现在两份合计 1560 行）；超了要在实现记录里说明为什么。
- **代码约定**：
  - 中文注释写「为什么」，并标明实测还是推测；
  - 菜单用中文，控件标签带 `##英文ID`；
  - 不用 `%d` 格式化浮点（防御菜单原有的 `%d` 只用于整数计数，可以保留；放刀计数用 `int_s`）；
  - 不用 `°` 和全角空格（6.7 有静态检查）；
  - 所有钩子和帧回调都包 pcall；
  - 共享参数三处还原：结算后、每帧开头、Reset。
- **引用记账**：只 add_ref、不手动 release。`tools/check.sh` 改成检查 `AutoGuardGS.lua`（6.7）。
- **钩子**：不钩新函数。防御 4 个 + 放刀 1 个，和原来两个脚本合计相同。
- **工具使用**：reframework MCP 只许只读（`get_type` 等），禁止调用方法、禁止写字段。实现阶段不部署、不动游戏目录。

---

## 2. 保留与删除（逐项）

总原则：

- **判断放不放刀的代码和数据**原样保留（第 2.7 节逐条论证）。
- **删掉的只有三类**：
  - a. 只写不读的变量（计数、去重表、影子量）；
  - b. 只为输出存在的代码：日志行、JSON、STAT；
  - c. 只为写记录而读游戏的调用。
- **调试日志开关只决定写不写日志行**，不决定任何状态更新。

### 2.1 记录种类

| 种类 | v1.6 怎么写 | 合并后 | 理由 |
|---|---|---|---|
| HDR | 加载时总写 | **保留**，写入时机是「本次加载第一次写任何 `[AutoParryGS]` 行之前，写一次」 | 分析脚本靠它分会话、认规则版本、核对冻结值 |
| | | 调试日志开着时，就在加载那一刻写 | |
| | | 字段：删 `rotation`、`scan`、`cfg_ver`，加 `host`、`enum_skip`（4.2） | |
| FIRE | 总写 | **保留**，只在调试日志开着时写 | 用户点名删 Qp、Qe1、vq |
| | | 删字段 `src`（恒为 V0）、`Qp`、`Qe1`、`mode`（恒为 E5c，HDR 已有 rule）、`vq` | src、mode 是恒值 |
| FIRE_END | 总写 | **删**。`entered` 改记在 RES 里 | 另外两个字段 R1、n 只给研究用。n 在实测里恒为 1，都是第一次请求就被接受：v1.6 试打 7/7（FIRE_END 全是 n=1、entered=1），第 1 轮 34/34（NOTES） |
| RES | 总写 | **保留**，只在调试日志开着时写；末尾加字段 `entered` | 记结局 |
| VETO | 每段否决写一行 | **删** | 研究否决口径用；放不放只看这一帧有没有否决 |
| STAT | 每 60 s 一行 | **删** | 研究用的计数和耗时；开销改看 `[AutoGuardGS] PERF` 行（4.5） |
| CFG | 每次改开关或滑块写一行 | **删** | 只给验收截断用；FIRE 带着 L，分析脚本能从 L 的变化推断滑块改动（分析脚本 1.0 起就有的兜底） |
| UVIEW | 放刀那一帧视野里有 U 时写 | **删** | 研究：为下一轮评估「pb / UNABLE_GUARD 要不要整帧否决」 |
| SKIP | 被该接过滤挡掉时写 | **删** | 研究；被挡掉的条目本来就不放刀 |
| ERR | 总进 JSON；日志只写前 20 条，按每秒 1 行补写 | **保留**，总写；每次加载前 20 条**立刻写**，不排队 | 错误必须看得到；不写 JSON 后排队已无意义 |
| RED | 总写 | **保留**，总写：进入红状态、自停、初始化失败，每次加载至多 3 行 | 错误分级 |
| DBG | 调试日志开时写；grab_enum、guard_enum、self_stop 三种总写 | **删** | 只给人看。缺的枚举名改写进 HDR 的 `enum_skip`；自停已有 RED why=self_stop |
| JSON 文件 `AutoParryGS_<会话>_<序号>.json` | 空闲时每 60 s 写一次；按钮触发；Reset 时写 | **删** | 用户定；而且写盘会卡帧 |

### 2.2 计数（v1.6 的 `stats`）

| 计数 | 合并后 | 原来谁读它 / 理由 |
|---|---|---|
| `fires` | **保留**（菜单「放了几刀」） | 每个 streak 开头 +1，口径同 v1.6 |
| `catches` | **拆成 `catch26`、`catch27`**（菜单「接住几刀」及括号里的分项） | 用户要分 26 / 27 |
| `recoils` | **保留**（菜单「被弹开几次」） | — |
| `nocatch` | **新增**（菜单「没接住几次」）= 写成 NOCATCH 的结局数 | 包括没进 (2,23)、空挥、被打断、又回到蓄力、主角消失、自停、Reset，口径同 RES |
| `vetoes` | 删 | 只给 STAT 和 VETO 行 |
| `failopen` | 删 | 同上 |
| `errors`、`err_red`、`err_yellow` | 删 | 只给 STAT 和 v1.6 菜单的第二行统计；状态行用的是 `err_state` |
| `readfail`、`replica`、`readerr` | 删 | 只给 STAT 和菜单统计 |
| `speedfail`、`speedhold`、`clockskip` | 删 | 同上 |
| `vetoq`、`fclosed`、`excl`、`uview`、`sidmis` | 删 | 研究计数 |
| `ferr` | 删 | 只给状态行里的「n 条」；状态行改成不带数字的写法（5.2） |

**这些删除都不影响放刀**：被删的计数没有一个出现在任何判断条件里。2.7 列了每个计数原来的唯一读者。

### 2.3 预告跟踪记录（`tracks[key]`）的字段，和只记录的量

| 字段 | 合并后 | 用途 |
|---|---|---|
| `obj`、`t_msg`、`master`、`idx` | 保留 | 决策：持有结果对象、判断过期、副本闸门、按 SystemIndex 读速度 |
| `first`、`m`、`X`、`x0`、`hs_prev`、`t_prev`、`clock`、`nofire` | 保留 | 决策：E5c 计算 |
| `em` | 保留 | 登记时照样读 `get_EmID`，见 2.7 的 C 类第 4 条 |
| `c1`、`cf`、`nchg`、`a0` | 保留（只做赋值，不调游戏） | FIRE 的 C1、Cf、nchg、A0：诊断放早要用，分析脚本也按 nchg 判断影子对照可不可信。调试日志中途打开时，这些值也得是现成的 |
| `fo`（failopen 去重） | 删 | 只服务 failopen 计数 |
| `sk`（SKIP 去重） | 删 | 只服务 SKIP 行；`catchable` 改成布尔函数之后（2.7）用不到了 |
| `fe`（过滤读取出错的去重） | 删 | 只服务 ferr 计数 |
| `re`（readerr 去重） | 删 | 只服务 readerr 计数 |
| `snd` | 删 | 只给 sidmis 比对 |
| `ql`、`qf` | 删 | 只给 FIRE 的 Qp |
| `ev.vq` | 删 | 只给 FIRE 的 vq 和 STAT 的 vetoq |
| `ev.ucands` | 删 | 只给 UVIEW |
| `ev.veto` | 保留，但只存 `true` | 原来存的是「代表条目 + 原因」，那只给 VETO 行用（2.7） |
| `streak.n`、`streak.r1` | 删 | 只给 FIRE_END |
| `veto_on` | 删 | 只给「每段否决写一行 VETO」去重 |
| `act_cat`、`act_idx`、`action_gap` | 删 | 只给 JSON 空闲写盘判断和 DBG |
| `res_wait = { id, t, to }` | 保留，再加 `entered` | 结局判定，菜单计数和 RES 都要用 |

### 2.4 函数

逐个去留见**附录 A**。概括如下：

- **删掉的函数**：
  - JSON 一套：`write_json`、`periodic`、`stat_emit`、`is_idle`、`draw_dump`；
  - 日志排队：`err_flush`；
  - DBG：`dbg`、`dbg_line`；
  - 研究记录：`skip_entry`、`pick_u`、`set_veto`（含 `WHY_RANK`）；
  - 记录小工具：`round4`；
  - CFG 行：`set_cfg`；
  - 旧配置读取：`load_config`（v1.6 版），由第 3 节的统一读配置和迁移代替。
- **改写的函数**：
  - `filter_reason` → 布尔函数 `catchable`（等价证明在 2.7）；
  - `build` / `emit` → `rec`：只拼日志行，第一次写之前补一行 HDR，不写 JSON；
  - `read_hunter` → 共享的 `read_frame`。
- **其余的函数**原样保留，只删掉函数体里写记录、写计数的那几行。

### 2.5 常量与状态

| 常量 / 状态 | 合并后 | 说明 |
|---|---|---|
| `LEAD_DEFAULT` 28、`LEAD_LO` 23、`LEAD_HI` 45 | 保留 | — |
| `LEAD_MIN` 22、`LONG_WINDOW` 60、`VETO_HORIZON` 90 | 保留 | — |
| `C_LO` 0.5、`C_HI` 2.0、`CLOCK_DMAX` 30 | 保留 | — |
| `SPEED_FAIL_STREAK` 5 | 保留 | 「速度读不到」的报黄和状态行要用 |
| `CREDIT` 1.3 | 保留 | — |
| `TRACK_MAX` 32、`TRACK_STALE` 8.0 | 保留 | — |
| `PAST_HE` −30、`PAST_AGE` 1.0 | 保留 | — |
| 动作编号：`CAT_ATTACK`、`IDX_SLASH`、`IDX_SLASH_FWD`、`PARRY_CHARGE`、`PARRY_OUT` | 保留 | — |
| `STOP_FRAMES` 30、`RED_WINDOW` 10、`RED_COUNT` 3 | 保留 | — |
| `READ_FAIL_TOL` 1.5、`READ_FAIL_GAP` 0.5 | 保留 | — |
| `ERR_LOG_MAX` 20 | 保留 | 每次加载最多写 20 行 ERR |
| `COLOR_RED`、`COLOR_GRAY` | 保留 | — |
| `CFG_VER` 3 | 只在迁移旧配置时用 | 新配置不存 cfg_ver（3.3） |
| `STAT_INTERVAL`、`JSON_INTERVAL`、`JSON_SEQ_MAX`、`REC_MAX` | 删 | — |
| `ERR_LOG_GAP`、`ERR_JSON_MAX` | 删 | — |
| `DATA_PREFIX` | 删 | — |
| `session = os.time()` | 保留 | HDR 的 session 字段；分析脚本和探针配对靠它 |
| `err_state` | 保留 `red`、`stopped`、`yellow`、`logged`、`times` | — |
| | 删 `last_log`、`recent`、`queue`、`json_n`、`final` | 不排队，菜单也不显示「最近的错误」 |
| `CORE` | `{ msg, frame, fire }` | 删 json |
| `records`、`rec_dropped`、`json_seq`、`json_status`、`want_dump`、`last_json_t`、`hook_ms`、`lua_win`、`last_stat_t` | 删 | — |
| `next_id` | 保留 | 每次放刀都递增，**不看调试日志开没开**；FIRE 和 RES 靠它对上 |

### 2.6 菜单项（v1.6 的「自动放刀（实验）」树节点 → 合并后）

| v1.6 | 合并后 |
|---|---|
| 树节点「自动放刀（实验）##AutoParryGS」 | 删；这一节挪进「大剑自动防御 v1.5##AutoGuardGS」（第 5 节） |
| 「版本 1.6  状态：…」 | 改成「状态：…」：版本号在树节点标题里已经有了；状态行文字按 5.2 |
| 红字「出错了：请把 re2_framework_log.txt 发给开发者，然后 Reset Scripts」 | 保留 |
| 「启用（实验）##ap_enabled」 | 文字改成「自动放刀（实验）##ap_enabled」；ID 不变 |
| 「提前量（真实剩余帧，1/60 秒）##ap_lead」，范围 23~45 | 原样 |
| 灰字「已按怪物速度修正。越小越常出抵消动作；太小会被先打到。默认 28」 | 原样 |
| 统计第一行（放刀、接住、被弹、否决、该接过滤跳过、读不准不放、速度读不到、联机副本跳过、fail-open、读取错误） | 只剩四项：放了几刀、接住几刀（26 / 27）、被弹开几次、没接住几次，放到底部统计区（5.1） |
| 统计第二行（错误、跟踪中的预告、待写出记录、读主角抛错跳过） | 删 |
| 「调试日志##ap_debug」 | 删，改用共用的「调试日志##debug_log」 |
| 「清零统计##ap_reset」 | 删，改用共用的「清零统计##reset_stats」，一次清两部分 |
| 「写出数据##ap_dump」「##ap_dump_min」、写出状态、最近的错误 | 删 |
| 出错后的简化菜单（状态 + 写出数据 + 最近的错误） | 改成只剩状态行和红字（5.3） |

### 2.7 为什么这些删除不改变放刀决策

**决策的范围**

决策 = 什么时候调用、调不调用 `changeActionRequest(0, (2,23), false)`。v1.6 里，这件事只取决于下面这些量：

- **消息钩子的登记条件**：
  - 开关开着、没有自停、知道主角地址、主角拿大剑；
  - 消息类型对、攻击目标是主角、预告还没结束；
  - 读主机 / 副本的结果，以及 `mod_off.master` 有没有关掉这项读取。
- **跟踪的丢弃规则**：上限 32 条、8 s 过期、IsAttackFinished、全部条目 he < −30、主角消失或换人、关掉开关、自停。
- **速度状态**：`m`、`X`、`x0`、`hs_prev`、`t_prev`、`clock`、`nofire`、`speed_cache`。
- **条目与过滤**：条目表、`classify` 的结果、`shell_of` 的结果。
- **规则求值**：
  - `ev.veto` 是否为真；
  - `ev.best`（Q 最小的候选）；
  - streak 状态；
  - 是否 active：开关、自停、拿大剑、在 (2,21)/(2,22)。
- **错误与容错**：`consec_err` 与自停、`read_fail` 的容忍期、`frame_no`。

合并后这些量的计算代码原样保留，删掉的东西逐类如下。

**A 类：只写不读的变量**

- 2.2 里删掉的计数；
- 2.3 里删掉的去重表和影子量：`fo`、`sk`、`fe`、`re`、`snd`、`ql`、`qf`、`vq`、`ucands`；
- `veto_on`、`streak.n`、`streak.r1`、`act_cat`、`act_idx`、`action_gap`。

全文找不到任何以它们为条件的分支（实现时用 grep 核对）。

**B 类：只为输出存在的代码**

- 所有日志行、JSON、STAT、DBG 的生成代码；
- ERR 的排队补写；
- 菜单统计。

规则：

- 输出代码**只读状态、不写状态**。这一条是给实现定的规矩，写进代码注释：FIRE / RES 的拼行代码不许给跟踪、streak、计数字段赋值；`next_id` 和计数的递增放在判断调试日志开没开之前。
- 调试日志开着（B 组）和关着（C 组）两种跑法的请求序列都必须与 v1.6 相同（6.3）。这条用测试证明。

**C 类：只为写记录而读游戏的调用**

一共 5 处，删掉之后的影响逐条如下：

1. `read_master` 里的 `enemy:get_address()`，只为 sidmis。
   - 推测不会抛错：REF 的 get_address 只返回指针，不解引用；mock 也这样建模。
   - 万一抛错，原来会让 master 模块报黄、停用这项读取；现在少了这次调用，只会更少出错。
2. `core_read` 里的 `enemy:get_address()`，只为 sidmis。
   - 推测不会抛错，理由同上一条。
   - 万一抛错：v1.6 会把整次 `core_read` 判为「读不到 C」；如果正好是首帧，这个结果就被标成永不放刀（nofire）。合并版不再调用它，只会更少出现这种情况。
   - mock 不对 get_address 注入故障，所以等价测试不受影响。
3. SKIP 路径的 ShellIndex 读取：已经确定不该接的条目，v1.6 会在它第一帧进窗口时读一次 ShellIndex。合并后 `catchable` 提前返回，不再读。
   - 出错的后果只是 filter 报黄。filter 报黄从来不会停用读取，也不进帧逻辑的错误计数。
4. UVIEW 的 ShellIndex、keep 读取，以及 SKIP 的 keep 读取。原来都包在 pcall 里，出错要么写 `-`，要么只报 filter 黄。
5. FIRE 的 keep 读取：改成只在调试日志开着、要写 FIRE 的时候才读，读出错写 `-`、**不计错误**。
   - v1.6 把它算作帧逻辑的错误，只影响红状态显示，不影响 `consec_err` 和自停。
   - 现在它只是一个可选日志行里的诊断字段，跟 v1.6 对 SKIP / UVIEW 里 keep 的处理一致。
   - 这是本轮唯一有意改变的错误口径：只在 `get_KeepActionID` 抛错时才看得出差别；现有 133 个场景里没有这种故障注入。

所以合并版每一帧对游戏的读取，是 v1.6 的**子集**，没有新增任何读取。

有一处要注意：登记时的 `get_EmID` 必须照读。它在 v1.6 里没有单独包 pcall，抛错会让整个 `on_message` 失败：计一次 msg 错误，这条预告不登记，也就不会放刀。如果为了省事改成只在写 FIRE 时才读，就改变了故障下的决策。

故障注入的一个理论例外：某个 API 被设成「只抛错 N 次」，而 v1.6 恰好在删掉的调用里用掉了这 N 次，合并版就会在保留的调用里遇到它，决策可能差一帧。现有场景里，限次故障只用在 get_Item、getClosestDetectedData、get_AttackAreaResult、TargetCharacter、imgui.slider_int 上，这些都是保留的调用，或者 v1.6 根本不调。所以现有场景不受影响。将来新增场景时，等价测试会直接报出差异。

**`filter_reason` → `catchable`：逐项等价**

```lua
-- 返回 true = 该接；它和 v1.6 的 filter_reason(tr, e) == nil 是充要条件关系
local function catchable(tr, e)
    local c = classify(tr, e)                                 -- 本帧缓存，否决侧已经读过
    if not (c.dmg_ok and c.guard_ok) then return false end    -- 伤害类型或防御类型读不准 → fc
    if c.grab or c.effect ~= false then return false end       -- 抓取；效果攻击（true）；效果名缺、读不准（nil）
    if c.g ~= "white" then return false end                    -- SKILL_GUARD 家族、UNABLE_GUARD、未知值
    if c.pb ~= false then return false end                     -- pb = 1，或读不准（nil）
    return shell_of(tr, e) == false                            -- 是弹体（true），或读不准（nil）
end
```

v1.6 的 `filter_reason` 返回 nil，当且仅当下面四条同时成立：

1. 不满足 (dmg_ok 且 (是抓取 或 effect = true))；
2. 不满足 (guard_ok 且 g = sg)；
3. `why₀` 为 nil；
4. shell 读出来是 false。

其中第 3 条 `why₀` 为 nil，当且仅当：pb ≠ true，且不满足 (guard_ok 且 g = ug)，且 dmg_ok，且 effect ≠ nil，且 guard_ok，且 g ≠ unknown，且 pb ≠ nil。

把四条合起来，得到：dmg_ok、guard_ok、不是抓取、effect = false、g = white、pb = false、shell = false，七条同时成立。这里用到：guard_ok 时 g 只可能是 white、ug、sg、unknown 四个值之一。这正是 `catchable` 返回 true 的条件。

两点补充：

- v1.6 里 `tr.sk` 提前返回那一支，只在 `why₀ ≠ nil` 时才走到，返回的也不是 nil，所以不影响「返回 nil」的条件。
- 对最终判为该接的条目，两边读游戏的顺序相同：先用缓存的 `classify` 结果，再读 ShellIndex。

**否决只看真假**

`update_fire` 只用 `ev.veto` 判断真假；从多个否决里挑哪一条、按什么原因排序，只影响 VETO 行写什么。所以 `set_veto` / `WHY_RANK` 换成 `ev.veto = true`，决策不变。

`consider` 里对视野内每条 DANGER 条目调用 `classify`（否决侧要用），**顺序和次数都不变**：不要因为「已经有否决了」就跳过后面条目的读取，否则故障下报黄的时刻会和 v1.6 不一样。

**最终保证**：6.3 的逐刀等价测试，**只在场景覆盖到的路径上成立**（审查修订：原稿只写了「最终保证」）。

- 审查时用变异找过一遍（两份审查合计约 100 个改坏的副本）。原来全套场景抓不住、会改变放不放刀的：否决视野的上沿（90 改 95 / 100）、8 s 过期（改 6 s）、候选的窗口宽度上限（60 改 70）、get_EmID 照读（包进 pcall）、候选的 w ≥ 0、active 里的「拿大剑」、连续 30 帧才自停、主角消失和开新 streak 两处结算 `res_wait`、没进 (2,23) 的 entered=0 路径、弹体最后读。都补了场景，见 6.5 末尾「审查补的场景」，变异见 6.7 表末尾。
- 已知仍没有场景约束的：
  - 请求了 (2,23) 却进了 (2,24)（第 9 节第 7 条）：和「请求一直被拒」都走 `end_streak(entered = false)`，但「把 (2,24) 也当成进了」这种改法抓不住。要补得先让参照组的断言认「(2,24) 不算进入」（mock 现在按进了 (2,23) 或 (2,24) 都算有这次尝试）；
  - 纯边界值：CREDIT 的 ≥、否决的 he ≥ 0 和 hs ≤ 90 的等号、过期 8 s 改 7.9 s、PAST_HE −30 改 −29 或 −10、CLOCK_DMAX 30 改 10；
  - 等价或近似等价的改写：时钟条目的优先顺序、登记时的 IsAttackFinished、Q 相等时取哪一条、防御段和放刀段的先后、`now` 在防御段之前还是之后取。
- 这些地方的代码和 v1.6 逐字相同（逐函数对照过），以后改到这里要靠代码审查，测试拦不住。

---

## 3. 配置

### 3.1 键与默认值（`reframework/data/AutoGuardGS.json`）

| 键 | 默认 | 类型、范围 | 来源 |
|---|---|---|---|
| `enabled` | true | 布尔 | v1.4.2，原样 |
| `guard_type` | 1 | 只接受 1 或 2 | v1.4.2，原样 |
| `guard_angle` | nil（用游戏原值） | 数值，夹到 30~360；为 nil 时文件里没有这个键 | v1.4.2，原样 |
| `respect_armor` | true | 布尔 | v1.4.2，原样 |
| `auto_tackle` | true | 布尔 | v1.4.2，原样 |
| `infinite_charge` | false | 布尔 | v1.4.2，原样 |
| `lock_health` | false | 布尔 | v1.4.2，原样 |
| `debug_log` | false | 布尔，**两部分共用** | v1.4.2，原样 |
| `auto_parry` | **true** | 布尔 | 新键；默认值同 v1.6，保证「没有任何配置文件」的场景和 v1.6 等价 |
| `parry_lead` | **28** | 有限数值 → 四舍五入成整数 → 夹到 23~45 | 新键；单位是 Q（真实剩余帧），同 v1.6 |

**不存 `cfg_ver`**：

- `parry_lead` 这个键只会由合并版写，含义永远是真实剩余帧，不需要版本号。
- 以后如果滑块含义再变，就换一个新键名，比维护版本号和升级路径简单。
- 这也是在执行用户第 3 条「去掉 rc / v1.5 时代的兼容字段和升级路径」。

### 3.2 读取 `AutoGuardGS.json`

- 用 `pcall(json.load_file, CONFIG_PATH)` 读。v1.4.2 没有包 pcall；读出错时报 ERR，mod=cfg、level=yellow，然后用默认值。
- 已有 8 个键的读法和 v1.4.2 一字不差：
  - `guard_angle` 是数值才收，夹到 30~360；
  - `guard_type` 只收 1 或 2；
  - 其余键要求类型和默认值相同；
  - 不认识的键忽略，包括 `cfg_ver`、`lead_rotation`、`scan`。
- 新键：
  - `auto_parry` 必须是布尔，否则用默认值；
  - `parry_lead` 必须是有限数值，然后按 `clamp_lead` 处理（四舍五入 → 夹到 23~45），否则用默认值。

### 3.3 从 `AutoParryGS.json` 迁移（只迁一次）

**什么时候迁**：读完 `AutoGuardGS.json` 后，如果它读出来的表里 `auto_parry` 和 `parry_lead` **两个键都没有**，就迁移。文件不存在、读失败也算「两个键都没有」。只要有任意一个键，就认为已经是合并版的配置，不看旧文件。

- 审查修订：读失败时只在内存里迁，不在加载时写回（第 5 步）。`json.load_file` 抛错（文件被占用等）时，这次加载一个字节都不写 `AutoGuardGS.json`，存配置也不写（3.4）。

**迁移步骤**：

1. 读旧文件：`pcall(json.load_file, "AutoParryGS.json")`。
   - 抛错 → 报 ERR（mod=cfg，黄），按「没有旧文件」处理。
   - 读出来不是表（文件不存在、内容坏了） → 按「没有旧文件」处理，用默认值 true / 28。**不写回**：下次加载会再试一次，结果相同，没有坏处。
2. `auto_parry`：旧值是布尔就用它，否则用 true。和 v1.6 一样，不看 `cfg_ver`。
3. `parry_lead`：
   - 旧文件的 `cfg_ver` 是 ≥ 3 的数值，并且 `parry_lead` 是有限数值 → 用 `clamp_lead`（四舍五入、夹到 23~45）；
   - 否则一律用 28。原因：cfg_ver 缺失、是 1 或 2、是字符串 `"3"` 时，旧值是名义帧口径，不能沿用。这条规则和 V16 第 2.7 节相同。
4. 不迁的键：`debug_log`、`cfg_ver`、`lead_rotation`、`scan`。用户定了：调试日志只用 AutoGuardGS 自己的开关。
5. **迁完立刻写回**：调 `save_config()`，内容是完整的配置表。
   - 写失败（抛错，或 `dump_file` 返回 false）→ 报 ERR（mod=cfg，黄），内存里的迁移值照常生效；下次加载会再迁一次，结果相同。
   - 审查修订：**只在 `AutoGuardGS.json` 本身读出了表时**才在加载时写回。文件不存在、读不出来时只在内存里迁，等存配置时再写。原因：旧文件永远在（第 6 步），迁移完以后，哪次加载读盘偶发失败就会被当成「两个键都没有」再迁一次；原稿在加载那一刻写回，会拿默认值把用户的防御设置整份盖掉（用户现在的文件是 guard_angle 360、无限蓄力、锁血、调试日志都开着）。
6. **旧文件只读**：不写、不改名、不删。理由：回滚（7.4）时 v1.6 还能原样读它；探针 APCal 也还在读它（第 9 节）。

**和 v1.6 等价**：对任何内容的 `AutoParryGS.json`，迁移得到的 `(auto_parry, parry_lead)` 和 v1.6 读同一个文件得到的值相同。mock 里已有的配置场景（6.4）用来检验这一点。

**以后不会再迁**：写回成功后，`AutoGuardGS.json` 里已经有这两个键，之后加载都不会再读旧文件。即使旧文件后来被改了也一样。

**用户的实际情况**（2026-10-11，只读核对）：

- 旧文件 `AutoParryGS.json` 是 `{auto_parry: true, cfg_ver: 3, debug_log: true, parry_lead: 28}`，迁移后得到 `auto_parry = true`、`parry_lead = 28`。
- `AutoGuardGS.json` 里 `debug_log = true`，所以部署后马上就会写 FIRE / RES 行。

### 3.4 保存

- 由 `re.on_config_save` 调 `pcall(json.dump_file, CONFIG_PATH, config)`；写失败报 ERR（mod=cfg，黄）。
- 审查修订：这次加载读 `AutoGuardGS.json` 抛错时，存配置也不写（内存里是默认值，写了就盖掉多半完好的原文件），菜单顶上用红字写「读不出配置文件……改动也不保存……Reset Scripts 重读」。v1.4.2 读配置不包 pcall，抛错时整个脚本加载失败，同样一个字节都不写；合并版保住了可用性，也保住了「不盖文件」。读出来不是表（文件不存在、内容坏了，REF 返回 nil）分不清是哪种，照 v1.4.2：存配置时照常写。
- 写出的键：v1.4.2 的 8 个键（`guard_angle` 为 nil 时没有这个键），加上 `auto_parry`、`parry_lead`。不写 `cfg_ver`。
- 菜单改动立刻写进内存里的配置，什么时候落盘同 v1.4.2，由 REF 触发 `on_config_save` 决定。不再写 CFG 行。

### 3.5 可测的条目

都放在 6.5 的 `merge_migrate_*` 场景里：

| # | 输入 | 期望 |
|---|---|---|
| 1 | `AutoGuardGS.json` 是 v1.4.2 的 8 个键；旧文件 `{auto_parry: false, parry_lead: 35, cfg_ver: 3}` | `auto_parry = false`，一刀不放；`parry_lead = 35` |
| | | 加载那一刻 `AutoGuardGS.json` 就被写成 10 个键 |
| | | 旧文件的字节一个不变 |
| 2 | 旧文件 `{parry_lead: 26, cfg_ver: 2}` | `parry_lead = 28` |
| 3 | 旧文件没有 `cfg_ver`，`parry_lead = 27.5` | `parry_lead = 28` |
| 4 | 旧文件 `cfg_ver = "3"`（字符串） | `parry_lead = 28` |
| 5 | 旧文件 `cfg_ver = 3`，`parry_lead` 分别是 22 / 50 / `"abc"` | 23 / 45 / 28 |
| 6 | 没有旧文件 | true / 28，加载时不写 `AutoGuardGS.json` |
| 7 | 旧文件不是 JSON | 同上；不报错 |
| 8 | `AutoGuardGS.json` 里已有 `parry_lead = 30`，旧文件 `parry_lead = 35`、`cfg_ver = 3` | 用 30，不读旧文件 |
| 9 | 迁移时 `AutoGuardGS.json` 写失败 | ERR（mod=cfg，黄）恰好一行；放刀按迁移来的值照常 |
| 10 | `AutoGuardGS.json` 全是 v1.4.2 的键，取值各异（`guard_angle = 360`、`guard_type = 2`、`lock_health = true` 等），也有类型不对的值 | 8 个已有键读出来的值和 v1.4.2 读同一个文件完全相同 |
| | | 存配置时这 8 个键原样写回 |
| 11（审查修订） | 迁移过的 `AutoGuardGS.json` 这次读盘抛错，旧文件还在 | 只在内存里迁（旧文件的 28）；加载时、存配置时都不写；菜单写明不保存；ERR（mod=cfg，黄）一行 |
| 12（审查修订） | 没有 `AutoGuardGS.json`，旧文件 `parry_lead = 33`、`cfg_ver = 3` | 33；加载时不写，存配置时照常写 |
| 13（审查修订） | `AutoGuardGS.json` 只有 `auto_parry = false` | 不迁移、不读旧文件：开关关、提前量 28 |
| 14（审查修订） | `AutoGuardGS.json` 的 `parry_lead` 是 50 / `"abc"` | 45 / 28（同样经 `clamp_lead`）；不迁移 |

---

## 4. 调试日志

### 4.1 什么时候写哪些行

| 行 | 什么时候写 |
|---|---|
| `[AutoGuardGS] v1.5 loaded` | 总写（原样） |
| `[AutoGuardGS] game guard angle: …` | 第一次读到防御角度原值时写一行（原样） |
| `[AutoGuardGS] PERF …`、`skip: …`、`guard forced: …`、`tackle …`、`infinite charge …` | 调试日志开着时写（原样）；PERF 行多一项 `msg`（4.5） |
| `[AutoGuardGS] <段> err: …` | 防御部分出错时总写，每类每次加载最多 20 行（新上限，原来没有上限） |
| `[AutoParryGS] HDR` | 本次加载第一次要写下面三种 `[AutoParryGS]` 行之一时，先写一次。调试日志在加载时就开着的话，就在加载那一刻写 |
| `[AutoParryGS] FIRE` | 调试日志开着时，放刀 streak 的第一帧写 |
| `[AutoParryGS] RES` | 调试日志开着时，结局确定的那一帧写：进了 (2,26) / (2,27) / (2,25)、超过 CREDIT、又回到蓄力、主角消失、自停、Reset |
| `[AutoParryGS] ERR` | 总写，每次加载前 20 条，出错时立刻写 |
| `[AutoParryGS] RED` | 总写 |

**为什么 HDR 不在加载时无条件写**：用户要求「默认不记」。调试日志关着、也没出错时，`[AutoParryGS]` 一行都不写。

**为什么又必须在第一行之前补写**：分析脚本按最近的一行 HDR 划分 session。如果加载后才打开调试日志、没有补写 HDR，这次的 FIRE 会被算进上一次加载的 session。

**补写带来的差别**：补写的 HDR 里，`auto_parry` 和 `lead` 是写那一刻的值，不是加载时的值。滑块后来又改过的话，看 FIRE 的 L。

### 4.2 字段表

`SPEC` 的写法同 v1.6：`字段名:格式`，`i` 整数、`fN` N 位小数、`s` 文本、`b` 布尔（1/0）、`h` 地址（十六进制）。值为 nil、NaN 或无穷时写 `-`。保留下来的字段，格式和 v1.6 完全相同；等价测试会逐字比较这些字段的文本。

| 种类 | 合并版的 SPEC | 和 v1.6 的差别 |
|---|---|---|
| HDR | `ver:s session:i auto_parry:b lead:i L_min:i W_long:i H_veto:i credit:f1 rule:s filter:s c_lo:f2 c_hi:f2 host:s enum_skip:s` | 删 `rotation`、`scan`（rc 时代，恒为 0）、`cfg_ver` |
| | | 加 `host=AutoGuardGS-v1.5` |
| | | 加 `enum_skip`：加载时没读到的抓取名或黑名单名，逗号分隔；都读到时写 `-`。它代替 v1.6 的 DBG grab_enum / guard_enum |
| | | `ver=1.6`、`rule=E5c`、`filter=g1`、`c_lo=0.50`、`c_hi=2.00` 不变 |
| FIRE | `id:i t:f4 L:i R0:f2 he0:f2 ent:h res:h em:s keep:s from:s C1:f3 Cf:f3 mf:f3 nchg:i dX:f2 A0:f2 Q0:f2` | 删 `src`、`Qp`、`Qe1`、`mode`、`vq` |
| RES | `id:i t:f4 outcome:s dt:f3 to:s entered:b` | 加 `entered`，值见下面 |
| ERR | `mod:s level:s msg:s` | 不变 |
| RED | `t:f4 mod:s why:s` | 不变；`why` 取 init、3in10s、self_stop |

RES 的 `entered` 怎么取：

- 1：streak 已经进了 (2,23)。
- 0：streak 没进 (2,23) 就结束了，v1.6 是当场补一行 RES NOCATCH；或者 streak 被主角消失、自停、Reset 打断。
- 规律：`res_wait` 只在进了 (2,23) 之后才存在，所以由 `res_wait` 结算出来的 RES，`entered` 一律是 1。

例：

```
[AutoParryGS] HDR ver=1.6 session=1791712779 auto_parry=1 lead=28 L_min=22 W_long=60 H_veto=90 credit=1.3 rule=E5c filter=g1 c_lo=0.50 c_hi=2.00 host=AutoGuardGS-v1.5 enum_skip=-
[AutoParryGS] FIRE id=1 t=4076.7890 L=28 R0=32.95 he0=49.35 ent=1365BAD850 res=13B8D8B250 em=em19#277 keep=(0,55) from=(2,22) C1=1.050 Cf=1.050 mf=1.050 nchg=0 dX=3.65 A0=106.04 Q0=27.90
[AutoParryGS] RES id=1 t=4077.3550 outcome=CATCH27 dt=0.566 to=(2,27) entered=1
```

### 4.3 标签：沿用 `[AutoParryGS]`

题目给了两个选项：沿用旧标签，或者改分析脚本认新标签。**选沿用**。

理由：

1. 分析脚本的 `_LOG_RE`、`TAG2SRC`、session 划分、`merge_sources`，mock 的日志解析，`e2e_analyze.py` 的抽取，都按这个标签工作，不用改。
2. 改用 `[AutoGuardGS]` 的话，防御已有的调试行（`[AutoGuardGS] PERF …` 等）会被分析脚本的正则当成「不认识的种类」，进报告的问题列表；为此还要再加一套排除规则。
3. V16、SPEED 和这几轮的报告都按 `[AutoParryGS]` 引用记录；旧日志和新日志用同一个标签，同一个 grep 就能看全。
4. 从此这个标签的含义是「放刀记录」，不再指某个文件。这一点写进头注释和 README。

### 4.4 `tools/apcal_analyze.py` 的改动

版本升到 1.5。报告头另起一行 `ANALYZER_REV_15`，原有的 1.2、1.3、1.4、1.4R 各行原样保留。

需要的改动：

1. **RES 认 `entered`**：`SCHEMA_SPEC["rc"]["RES"]` 追加 `entered:b`。
   - `build_fires` 取 entered 的顺序：先找 FIRE_END；没有就用 RES 的 `entered`；还没有就看探针的 ACT；都没有，按「进入了」计并计数。
2. **一致性核对允许没有 Qe1**：`fire_consistency` 在 `Qe1` 为 None 时：
   - 只核对 `|Q0 − (R0 − dX)/mf|` 和 `L_min ≤ Q0 ≤ L`，容差同 1.4；
   - 不报「缺字段」；
   - `C1`、`A0` 只在核对 Qe1 时才必需。
3. **认出合并版**：HDR 带 `host` 字段的 session 叫「合并版」。
   - 报告头写一行：「合并版（AutoGuardGS v1.5）放刀日志：只有 HDR、FIRE、RES、ERR、RED；没有 VETO、SKIP、UVIEW、STAT、CFG、FIRE_END、JSON。依赖这些的项写『—（合并版不记）』」。
   - D16 的开销项写「—（合并版没有 STAT；开销看 [AutoGuardGS] PERF 行）」。
   - 因为缺这一项，D16 的结论不会是「通过」，只会是「样本不足」或「需复核」。如果以后要用合并版做正式验收，就把第 5 条做了。
4. **自检**（`--selftest`）补三例：
   - 一个合并版 session，只有日志、没有 JSON：要能解析；`entered` 从 RES 取；一致性核对在没有 Qe1 时通过；故意把 Q0 写偏 0.6 要被抓到；报告里出现「合并版」那一行。
   - 一个独立 v1.6 session 和一个合并版 session 一起分析：两者都按 1.6 规则；冻结值都是 lead 28、L_min 22、W_long 60、H_veto 90、rule=E5c、filter=g1。
   - 合并版 HDR 是懒写的：它前面没有任何 `[AutoParryGS]` 行，session 划分正确。
5. **可选**：解析 `[AutoGuardGS] PERF` 行，用来估合并版的开销。
   - 解析方法：把各项的 ms/s 加起来，除以 1000，就是占帧时间的比例。
   - 这个比例单独报告，不进 D16 判定。
   - 本轮可以不做，不做时写进第 9 节。

**回归**：

- 第 1 轮报告：`tools/out/round1_report_baseline.md` 的每一行仍在，顺序不变；只多出 1.5 的说明行。
- 2a、2b、2c 的报告：和 1.4 的输出比，只多报告头一行。以上改动只对带 host 的 session、或缺 Qe1 的 FIRE 生效，这几轮的数据都不是。

### 4.5 调试日志关着时的开销

| 什么 | 关着时 | 开着时 |
|---|---|---|
| 决策逻辑（跟踪、速度、过滤、否决、放刀） | 照常（和 v1.6 一样） | 照常 |
| 菜单计数、`res_wait`、`next_id` | 照常：每次放刀做几次整数运算 | 照常 |
| 诊断量 `c1`、`cf`、`nchg`、`a0` | 照常赋值：不调游戏，每个新条目多一次表写入 | 照常 |
| `prof` 计时（frame、dmg_pre、dmg、msg） | 照常：每次调用读两次 `os.clock`。这是 v1.4.2 的「一直计数」，PERF 行只在开着时写 | 每 5 s 写一行 PERF |
| FIRE / RES 的拼行和 keep 读取 | **不做**：调用前先判断 `config.debug_log` | 每次放刀写 2 行；keep 读 1 次 REF |
| HDR | 不写（除非出错，见 4.1） | 每次加载写 1 行 |
| ERR / RED | 出错时写（前 20 条） | 同左 |
| JSON 写盘、STAT、VETO / SKIP / UVIEW / CFG / DBG 行 | **永远不做** | 永远不做 |

**和 v1.6 比**：

- v1.6 的 FIRE、RES、VETO、STAT 等行**不看调试日志开关，总写**；还要每 60 s 在空闲帧写一次 JSON，那是卡帧的主要来源。
- 合并版在调试日志关着时，没有日志 I/O，没有字符串拼接，没有 JSON；剩下的只有决策本身。

**和两个脚本一起跑比**：每帧的 REF 调用只少不多。原因是两边各读一遍主角，合成了读一遍快照。

**实测参照**：v1.6 试打（session 1791712779，约 63 分钟，STAT 每 60 s 一行）：

- 帧回调 `lua_ms_avg` 在 0.015~0.039 ms 之间；
- 钩子 `hook_ms_ps` 在 0.17~0.55 ms/s 之间；
- 同期帧率 60~124 fps，中位 77（取自 `[AutoGuardGS] PERF` 的 766 行）；
- 按「帧回调耗时 × fps + 钩子耗时」折算，约占帧时间 0.1%~0.5%，中位约 0.2%。

合并版的开销用 `[AutoGuardGS] PERF` 行看：frame 一项包含两部分的帧逻辑，msg 一项就是放刀的消息钩子。

---

## 5. 菜单

### 5.1 布局与控件

只有一个树节点：`大剑自动防御 v1.5##AutoGuardGS`。ID 不变，所以树的展开状态会保留。缩进表示同一层级的先后顺序：

```
[x] 启用自动防御（含自动肩撞）##enabled          ← ID、键都不变，只改文字（理由见下）
防御类型##guard_type                              ← 原样
[x] 霸体时不防御（保护真蓄力斩等霸体攻击）##respect_armor
[x] 蓄力中挨打后自动肩撞##auto_tackle
────────（separator）
防御角度##guard_angle  [恢复默认##angle_default]  说明文字    ← 原样
────────
[x] 自动放刀（实验）##ap_enabled
    （灰）按住抵消蓄力时，危险攻击快到就自动放出抵消上捞斩；伤害、火花、弹开都是游戏原生的
    状态：正常                                     ← 5.2
    （红，只在核心模块出错时）出错了：请把 re2_framework_log.txt 发给开发者，然后 Reset Scripts
    提前量（真实剩余帧，1/60 秒）##ap_lead        ← slider_int 23~45；改动后经 clamp_lead 处理
    （灰）已按怪物速度修正。越小越常出抵消动作；太小会被先打到。默认 28
────────
[ ] 【测试】无限蓄力（蓄满后不会自动放出）##infinite_charge   （开着时显示状态，原样）
[ ] 【测试】锁血（不掉血、不会倒下，被打的动作照常）##lock_health   （原样）
────────
自动防御：n 次   自动肩撞：n 次   本来就在防御：n 次             ← 原样
跳过：霸体 n 次   不能举剑（翻滚、收刀、硬直等）n 次                ← 原样
自动放刀：放了 n 刀   接住 n 刀（26：n，27：n）   被弹开 n 次   没接住 n 次
[清零统计##reset_stats]  [x] 调试日志##debug_log                  ← 一次清两部分；开关两部分共用
（调试日志开着时）性能（每秒）：frame … | dmg_pre … | dmg … | msg …
（调试日志开着时，灰）放刀记录写在 re2_framework_log.txt：[AutoParryGS] FIRE（放刀）、RES（结局）
```

- **为什么改「启用」的文字**：v1.4.2 的「启用」管的是自动防御和自动肩撞，不管自动放刀。合并后下面紧跟着「自动放刀（实验）」的开关，只写「启用」容易被当成总开关。ID 和配置键都不变。
- **四个计数的口径**：
  - 放了几刀 = `fires`，每个 streak 开头 +1；
  - 接住几刀 = `catch26 + catch27`，括号里分别列出；
  - 被弹开几次 = `recoils`；
  - 没接住几次 = `nocatch`。
  - 「放了」减去另外三项，等于还在等结局的那一刀（0 或 1）。
- **文字约束**：不用 `°` 和全角空格；中文全角标点可以用，原菜单本来就有。
- **格式化**：计数用 `int_s`，或者只对整数用 `%d`。

### 5.2 状态行（放刀一节）

前缀「状态：」；多条之间用「；」连接；一条都没有时写「正常」。顺序同 v1.6：

| 条件 | 文字 |
|---|---|
| 已自停 | 已自停（帧逻辑连续出错） |
| 否则，如果核心模块出过红错误 | 核心模块出错 |
| 否则，如果有不属于「soft」的可选模块报过黄 | 有可选模块停用（黄 n），自动放刀照常（n = 报过黄的模块数，不算 soft 模块） |
| items 报过黄 | 条目读取出过错：读不出条目的预告不放刀 |
| 首帧连续 5 次读不到速度，且还没恢复 | 速度读不到，已停止自动放刀 |
| 速度曾经读不到，现在恢复了 | 速度曾读不到，已恢复 |
| filter 报过黄 | 过滤字段读取出过错：读不准的条目不放刀 |
| filter_enum 报过黄 | 过滤用的枚举读不到（缺 X）：这些攻击一律不放刀 |

- soft 模块指 items、speed、filter、filter_enum：它们报黄后**不停用读取**，所以不能说成「有模块停用」。
- 和 v1.6 的差别只有一处：去掉了括号里的计数（「读取错误 n」「n 个预告没放刀」「n 条」），因为对应的计数已经删了。是哪类问题仍然清楚，细节看 ERR 行。

### 5.3 出错时

- 放刀一节的绘制包在 pcall 里。出过错（ERR mod=ui，黄）之后，这一节只画状态行和红字，同 v1.6 的「简化菜单」，只是去掉了已删的按钮和错误列表。
- 防御一节的绘制另外包一层 pcall。出错时：
  - 写一行 `[AutoGuardGS] ui err: …`（受「每类 20 行」上限约束）；
  - 这一节显示「菜单出错，见日志」；
  - 不影响放刀一节。
  - 审查修订：2 s 后重画，不再一直降级到 Reset（出错多半是瞬时的；一直出错也只是每 2 s 试一次，警告照样每类最多 20 行）。放刀一节出过错后仍是 v1.6 的简化菜单（等价测试比状态行）。
  - 审查修订：`gs_action_param` 对 `get_Catalog()` 判空。PlayerManager 在、Catalog 暂时为 nil 时（推测：标题画面、读盘时；没直接测到）返回 nil，菜单走 v1.4.2 已有的「防御角度：等待读取角色数据……」，不算出错。同一个函数也用在受击钩子（改角度）和无限蓄力里：Catalog 为 nil 时这一下不改角度、照常判断防御，无限蓄力这一帧不改；v1.4.2 这时整个钩子 / 帧抛错（这一下不防御、清掉肩撞请求）。只在这种故障下和 v1.4.2 不同，而且更可用。
- `imgui.tree_pop()` 不论出不出错都要调，保证 imgui 的栈配对。v1.4.2 的菜单没包 pcall，这是顺手修掉的缺陷。

---

## 6. 测试计划

### 6.1 归档：作为对照的原版脚本

| 归档文件 | 来源 | 用途 |
|---|---|---|
| `tools/archive/AutoParryGS_v1.6.lua` | 现在的 `src/reframework/autorun/AutoParryGS.lua`，md5 `a83527d92432e618885c38d561199338`；2026-10-11 核对，和游戏 autorun 里的逐字节相同 | 参照组 A0：133 个场景的被测放刀模块 |
| `tools/archive/AutoGuardGS_v1.4.2.lua` | 现在的 `src/reframework/autorun/AutoGuardGS.lua`，md5 `85fedcc0b0e1073987736d4a6c689897`；同上核对 | 防御场景的参照组 G-ref；回滚用 |

- **先归档、再改 `src/`**。归档后用 md5 核对，写进实现记录。
- 归档文件不部署、不在 `check.sh` 的默认检查范围里（默认只查 `src/`、`probes/`）。
- `run.lua` 找归档的顺序：先找 `tools/archive/<名字>`，再找 `tools/mock/archive/`（同 V16 第 8.5 节）。

### 6.2 mock 怎样加载合并后的脚本

**1. 被测脚本表**

- 原来的 `RC_SCRIPTS.v16` 改指向 `tools/archive/AutoParryGS_v1.6.lua`。`--rc` 参数保留，用来指定别的副本。
- 新增 `RC_SCRIPTS.merged`：
  ```
  { name = "AutoGuardGS", rec_tag = "AutoParryGS",
    path = opts.merged or ROOT .. "/src/reframework/autorun/AutoGuardGS.lua",
    role = "rc", guard = true, ver = "merged", policy = "no_release" }
  ```
- 新增 `GUARD_SCRIPTS.v142`：指向归档的 v1.4.2，`role = "guard"`，只给防御场景的参照组用。
- 加载顺序按 REF 的文件名字母序（1.4）：AutoGuardGS 在 AutoParryCalib 之前，AutoParryCalib 在 AutoParryGS 之前。

**2. 别名**

场景里写的 `AutoParryGS` 意思是「放刀模块」。合并模式下，`run.lua` 在建场景时把它改写成合并脚本：

- `faults[].scripts.AutoParryGS` → `AutoGuardGS`。
- `ui[].script = "AutoParryGS"` → `AutoGuardGS`。同时 `match` 按下表改成带 ID 的写法。必须改，因为菜单是按「标签包含这段文字」匹配的，只写「启用」会先匹配到防御的启用开关。

  | 原来的 match | 改成 |
  |---|---|
  | 启用 | `##ap_enabled` |
  | 提前量 | `##ap_lead` |
  | 清零统计 | `##reset_stats` |
  | 调试日志 | `##debug_log` |
  | 写出数据 | 这项操作直接丢掉，记一条 info |

- `config.AutoParryGS` 照原样写成 `AutoParryGS.json`，作为旧文件，走迁移。
- 另写 `AutoGuardGS.json`：内容是 `{debug_log = <这一组的开关>}`，其余键用默认值；不含 `auto_parry`、`parry_lead`，好让迁移路径一定被走到。

**3. 要补的桩**

`mock_ref.lua` 的类型库：

- `app.cHunterHealth`，方法：
  - `requestDamage(app.HunterCharacter, System.Single, System.Single, System.Boolean, System.Boolean, System.Boolean, System.Boolean, System.Boolean, System.Boolean)`；
  - `requestRedDamage(System.Single)`；
  - `get_HealthMgr()`。
- `app.cHealthManager`，方法：`get_Health()`、`get_MaxHealth()`、`set_Health(System.Single)`。
- `app.HunterCharacter`：加 `get_HunterHealth()`。
- `app.HunterDef.ACTION_ATTR`：现在是空枚举，要补上 `BLOCKED_ATTR_NAMES` 里的 28 个名字，值互不相同就行。缺了它们，加载时会写 28 行「not found」警告，而且「不能举剑」的属性检查会整个失效。（实现记录更正：原稿写 29；v1.4.2 和合并版里都是 28 个）
- 已经有的不用补：STATUS_FLAG 的 GUARD、TECHNICAL_GUARD、GUARD_POINT、POWER_GUARD、SUPER_ARMOR、HYPER_ARMOR；`ACTION_CANCEL_INDEX.Invalid`；Wp00ActionParam 和 cCharge 的字段；`PlayerManager.get_Catalog`；`checkContainsActionInCurrentBTable`；`HitInfo.get_AttackOwner`；按 `is_a` 找组件的 `getComponent(System.Type)`。

`game_sim.lua`：

- **血量模型**：
  - 主角带 `cHunterHealth` 和 `cHealthManager`，`MaxHealth` 默认 150；
  - 身体挨打时，经过钩子分发调用一次 `requestDamage`：如果某个前置钩子返回 `SKIP_ORIGINAL`，就不扣血；否则在这一帧末尾扣血；
  - 场景可以设「红血伤害」，走 `requestRedDamage`。
- **状态标志**：`FlagGroup.on/off` 要真的置位和清除（现在是空操作），并记成副作用（帧号、阶段、标志）；`status_flag` 要反映强开的标志。
- **动作请求**：
  - `on_request` 接受从 (2,5)/(2,6)/(2,7)/(2,11) 发出的 (2,15)/(2,17) 请求，下一帧生效，记法同 (2,23)；
  - 加上普通蓄力的时间线：(2,5)→(2,6)→(2,7)→(2,11)，带 SUPER_ARMOR；
  - 加上拔刀待机 (1,14)。
- **场景开关**，都可以按时间窗口设：
  - `can_guard`（`checkContainsActionInCurrentBTable` 的返回值，默认 false，同现在）；
  - `attrs`（例如 `DODGE` 在某段时间里为真）；
  - `weapon_on`（默认 true）。

`run.lua`：

- `ALLOWED_HOOKS` 加两项：
  - `app.cHunterHealth.requestDamage(app.HunterCharacter,System.Single,System.Single,System.Boolean,System.Boolean,System.Boolean,System.Boolean,System.Boolean,System.Boolean)`；
  - `app.cHunterHealth.requestRedDamage(System.Single)`。

**4. 合并模式下每个场景都查的断言**

替换 v1.6 的发布版断言：

- **加载与语法**：
  - 加载不报错，不写全局变量，日志里没有 FMT_ERR；
  - imgui 栈配对，控件标签都带 `##`，菜单文字里没有 `°` 和全角空格。
- **钩子**：恰好 5 个，即 `receiveGameMessage`、`HunterCharacter.evHit_DamagePreProcess`、`HunterCharacter.evHit_Damage`、`cHunterHealth.requestDamage`、`cHunterHealth.requestRedDamage`；不钩 `onParryHitPreProcess`。
- **副作用白名单**（按调用参数归属到放刀或防御；探针一个副作用都不许有）：

  | 副作用 | 允许的条件 |
  |---|---|
  | `changeActionRequest(0, (2,23), false)` | 帧开头的快照是 (2,21)/(2,22) |
  | `changeActionRequest(0, (2,15) 或 (2,17), false)` | 快照是 (2,5)/(2,6)/(2,7)/(2,11)，且有肩撞请求在等 |
  | `FlagGroup.on`（GUARD / TECHNICAL_GUARD） | 只在受击前置钩子里 |
  | `FlagGroup.off` | 只在受击后置钩子、帧开头、Reset |
  | `set_field`：Wp00ActionParam 的 `_GuardDegree` / `_AimGuardDegree` | 受击前置钩子里改写；还原只在后置钩子、帧开头、Reset |
  | `set_field`：cCharge 的 `_OverheatTime` | 只在无限蓄力开关切换、主角消失或换了武器、Reset 时 |
  | `cHealthManager.set_Health` | 只在锁血开着时 |
  | 钩子返回 `SKIP_ORIGINAL` | 只在锁血开着时，且只对主玩家的 requestDamage / requestRedDamage |

  另外：**同一帧最多一个 changeActionRequest**。
- **引用记账**（V16 第 8.2 节原样）：
  - 手动 release 次数 0，`OVER_RELEASE` 0，`ADD_REF_PERMANENT` 0；
  - `DEAD_OBJECT` 0（负对照除外）；
  - 持有时长：IsAttackFinished 之后不超过 1.5 s；距最后一条消息不超过 9.5 s；主角消失、换人、关开关、自停之后不超过 0.5 s；
  - 模拟 Reset 之后，共享计数全部归零。
- **日志格式**：
  - `[AutoParryGS]` 行只有 HDR、FIRE、RES、ERR、RED 五种，字段顺序按 4.2，布尔值写 1/0；
  - HDR 每次加载恰好一行，并且在第一行别的 `[AutoParryGS]` 行之前；
  - 调试日志关着的时段里，没有 FIRE、RES；
  - ERR 每次加载不超过 20 行；
  - `[AutoGuardGS]` 行不解析、不限速，这是 v1.4.2 原有的行为；只查里面没有 FMT_ERR。
- **文件**：不写任何 `AutoParryGS_*.json`；`AutoParryGS.json` 的字节不变；存下的 `AutoGuardGS.json` 的键按 3.4。

### 6.3 逐刀等价测试（本轮最重要的验收）

**三组跑法**，场景、随机种子、探针设置完全相同：

- **A0**：归档的 v1.6，加上场景原来的探针。这就是现在这套 133 个场景的跑法，原有断言全部照查。
- **B**：合并脚本，调试日志**开**，加上同样的探针。
- **C**：合并脚本，调试日志**关**，加上同样的探针。

**跑法**：`lua tools/mock/run.lua --merged [场景…]` 对每个场景依次跑 A0、B、C。

- 输出：`tools/mock/out/<场景>/`（A0）、`.../merged_on/`（B）、`.../merged_off/`（C），以及 `.../equiv.txt`。
- **任何一项不同，场景就算失败**，退出码 1。

**每组抽出的「轨迹」**：

| 项 | 从哪里取 | 怎么比 |
|---|---|---|
| 请求序列 | mock 记下的 `changeActionRequest` 中，目标是 (2,23)/(2,24) 的那些：帧号、时刻、是否被接受，包括被拒的 | B、C 都必须和 A0 **逐项相同** |
| FIRE | A0 取 JSON / 日志里的 FIRE，B 取日志里的 FIRE，按 id 对齐 | B 对 A0：`t`、`L`、`R0`、`he0`、`ent`、`res`、`em`、`keep`、`from`、`C1`、`Cf`、`mf`、`nchg`、`dX`、`A0`、`Q0` 的**文本逐字相同**；A0 独有的 `src`、`Qp`、`Qe1`、`mode`、`vq` 不比 |
| RES | 按 id 对齐 | B 对 A0：`t`、`outcome`、`dt`、`to` 逐字相同；B 的 `entered` 等于 A0 那一刀 FIRE_END 的 `entered` |
| 计数 | B、C 取场景结束时的菜单文字。A0 从记录推算：放刀数 = FIRE 条数；26、27、RECOIL、NOCATCH 各自 = RES 里对应结局的条数。如果场景里点过「清零统计」，只数清零之后的记录 | B、C 都必须和 A0 相同 |
| 自停与红状态 | RED 行的 `(t, mod, why)` | 逐行相同；json 模块引起的 RED 不比（合并版已没有 json 模块） |
| 错误 | 前 20 条错误的 `(mod, level, 发生时刻)`。A0 取 JSON 里的 ERR 记录（发生时刻是补写的 t）；B、C 取日志行的模拟时刻 | 去掉 json、cfg 两个模块后逐条相同。cfg 不比，因为配置文件换了 |
| 状态行 | 场景结束时菜单的放刀状态行，先归一化：去掉「版本 1.6  」前缀，去掉括号里的数字，再拆成 5.2 表里的条目集合 | B、C 都必须和 A0 相同 |
| 引用记账 | `MANUAL_RELEASE`、`OVER_RELEASE`、`DEAD_OBJECT` | 三组都是 0 |

**哪些场景比**：

- 123 个 v16 场景，减去两个负对照，共 **121 个，B、C 两组都比**。审查修订：补了 11 个 v16 场景（6.5 末尾），现在 134 个 v16 场景、**132 个比较**，参照组 A0 共 144 个场景。
- 两个负对照（`v16_ref_neg_probe`、`v16_ref_local_noaddref`）本来就要求出现悬空访问，访问之后的行为没有可比性；它们另有合并版的对应场景（6.5）。
- rc1 的 9 个场景和 v15 的 1 个场景不涉及合并脚本，照旧只跑 A0。

**豁免表：现在为空**。实现时如果有场景需要豁免，必须证明差异只来自 2.7 的 C 类读取，把场景名、差异和原因写进本节，并在实现记录里列出。

**参照组的自检**：A0 就是现在这套 133 个场景（只是被测脚本改成从归档读），原有断言必须 0 失败。如果不是 0，说明归档或 mock 的改动出了问题，先修这个，再看等价结果。

### 6.4 旧场景：因为去掉记录而改成新断言的

旧场景对 A0 的断言一个不改，这些断言证明参照组本身是对的。合并模式下，下面这些类别的场景，原来靠记录做的断言改成「等价比较 + 新断言」：

| 类别 | 场景 | 原来的断言靠什么 | 合并模式的新断言 |
|---|---|---|---|
| 否决原因 | `long_veto`、`v151_grab_*`（6 个）、`v16_sg`、`v16_veto_tie`、`v16_veto_failopen`、`v16_multi_attr`、`v16_multi_attr_enum` | VETO 行的 why 和 hs | 请求序列等价；没有 VETO 行 |
| 该接过滤 | `v16_pb`、`v16_ug`、`v16_fc_*`（3 个）、`v16_guard_unknown`、`v16_guard_enum_normal`、`v16_guard_enum_ug`、`v16_effect_enum_missing`、`v16_pb_unreadable`、`v15_filter_throw`、`v15_filter_nil`、`v151_dmgtype_throw`、`v151_effect_enum` | SKIP 行、`excl` / `fclosed` 计数 | 等价（这些条目都不放刀）；没有 SKIP 行 |
| | | | 缺的枚举名在 HDR 的 `enum_skip` 里（`v151_grab_enum`、`v16_guard_enum_ug`）；filter_enum 报黄照旧 |
| U 在视野内 | `v16_mixed_result`、`v16_uview_other`、`v16_uview_min`、`v16_u_nofire` | UVIEW 行、`uview` 计数 | 等价；没有 UVIEW 行 |
| 研究计数 | `v16_vetoq`、`v16_sidmis`、`v16_sidmis_badc`、`v15_replica`、`v15_master_*`、`v15_items_*`、`v16_c_*`、`v16_clock_switch` 等 | STAT 字段（vetoq、sidmis、replica、failopen、readerr、speedfail、speedhold、clockskip） | 等价；计数已删；状态行等价 |
| 配置迁移 | `v15_default`、`v15_upgrade28`、`v151_upgrade26`、`v151_upgrade35`、`v151_keep26`、`v151_upgrade_nodbg`、`v151_upgrade_frac`、`v151_upgrade_nolead`、`v15_clamp_hi`、`v15_clamp_lo`、`v16_cfg_*`（7 个） | DBG cfg_upgrade、HDR lead、存下的 `AutoParryGS.json` | 等价（L 相同，所以放刀相同） |
| | | | 新断言：加载时就写回的 `AutoGuardGS.json` 里，`auto_parry` / `parry_lead` 等于 v1.6 的有效值，没有 `cfg_ver`；`AutoParryGS.json` 字节不变；没有 DBG |
| | | | 例外：`v15_default`、`v16_cfg_nofile` 没有旧文件，所以不写回 |
| 菜单改配置 | `v15_cfg`、`v16_window`、`ui_toggle`、`v15_menu_misc` | CFG 行恰好一行；STAT 在清零之后的值 | 等价；没有 CFG 行；清零之后菜单计数等于 A0 的推算值 |
| | | | 在 C 组里，`v15_menu_misc` 在 7 s 打开调试日志：7 s 之前没有 FIRE / RES，之后有；HDR 正好在第一行 FIRE 之前 |
| JSON | `v15_json`、`v15_json_busy`、`v15_reset_json` | JSON 写出的时机、写失败的 ERR | 等价（`v15_reset_json` 里 json 模块的 ERR 不比）；没有任何 `AutoParryGS_*.json` |
| 菜单降级 | `v15_ui_degrade` | ui 报黄、简化菜单里点「写出数据」 | 等价；ui 报黄；放刀一节变成简化版（5.3）；「写出数据」那项操作按 6.2 第 2 条丢掉 |
| DBG 事件 | `action_gap`、`transient_throw`、`v16_gap_hunter`、`v15_stop_idle` | DBG no_action、read_fail、self_stop 等 | 等价；没有 DBG；RED self_stop 照旧 |
| 引用负对照 | `v16_ref_neg_probe`、`v16_ref_local_noaddref` | 要求出现 DEAD_OBJECT | 不比等价；改用合并版的负对照 `merge_ref_neg_probe`、`merge_ref_local_noaddref`（6.5） |

### 6.5 新场景（只在合并模式下跑）

**防御功能**：参照组 G-ref 是归档的 v1.4.2，单独加载，不带放刀模块。两组的「防御副作用轨迹」必须逐项相同，防御计数（菜单文字）也必须相同。「防御副作用轨迹」= 6.2 第 4 条表里除 (2,23) 请求之外的各项。另有各场景自己的期望：

| 场景 | 内容 | 期望 |
|---|---|---|
| `guard_basic` | 拔刀待机 (1,14)，`can_guard = true`，被怪物打中 | 前置钩子开 TECHNICAL_GUARD，后置钩子关掉；自动防御 +1 |
| `guard_type_normal` | 同上，`guard_type = 2` | 开的是 GUARD |
| `guard_armor_skip` | 带 SUPER_ARMOR 时挨打 | 不开标志；「跳过：霸体」+1 |
| `guard_already` | GUARD 已经开着 | 「本来就在防御」+1 |
| `guard_blocked_attr` | DODGE 属性为真；`weapon_on = false` 时再打一次 | 「不能举剑」+1，各一次 |
| `guard_tackle_lv1` / `guard_tackle_lv3` | 在 (2,6) / (2,7) 蓄力中挨打 | 下一帧请求 (2,15) / (2,17)，进入后「自动肩撞」+1 |
| `guard_tackle_cancel` | 挨打后、请求之前就松手离开了蓄力 | 不请求，tackle 被取消 |
| `guard_angle` | `guard_angle = 120` | 前置钩子把两个角度字段改成 120，后置钩子还原成 70 |
| | 在 (2,21)/(2,23) 里挨打 | 不改写 |
| | 场景让某一次后置钩子没被调用 | 下一帧开头还原 |
| `guard_infinite_charge` | 开、关；主角换成别的武器；主角消失；Reset | 开时 7 个 `_OverheatTime` 改成 99999；其余四种情况都还原成 3.0 / 2.5 |
| `guard_lock_health` | 锁血开着时挨打（requestDamage）、吃红血（requestRedDamage）；关掉后再挨打 | 开时：主玩家的两种伤害都返回 SKIP_ORIGINAL、不扣血，「已拦下」计数对；每帧把血补满 |
| | | 关后：正常扣血 |

**配置迁移**：3.5 表里的 10 条，分成 `merge_migrate_v16`、`merge_migrate_old_ver`、`merge_migrate_none`、`merge_migrate_bad`、`merge_migrate_write_fail`、`merge_no_remigrate`、`merge_guard_keys` 七个场景。

**交互、开关、隔离**：

| 场景 | 内容 | 期望 |
|---|---|---|
| `merge_interaction` | 同一场景里依次发生：(2,6) 普通蓄力中挨打；(2,21) 抵消蓄力中有可接的 DANGER；(2,21) 中挨了一下身体打击；(2,6) 中有 DANGER 进入窗口 | 第 1 段只出肩撞；第 2 段只放刀，Q 和时刻与 A0 相同；第 3 段不出肩撞、不开防御标志 |
| | | 第 4 段不放刀；全程每帧最多一个 changeActionRequest |
| `merge_debug_toggle` | 调试日志一开始关着，10 s 时打开，20 s 时关掉 | 10 s 前一行 `[AutoParryGS]` 都没有；第一行 FIRE 前恰好一行 HDR；20 s 后没有 FIRE / RES |
| | | 请求序列等于全程关着、和全程开着的两种跑法 |
| `merge_debug_off_silent` | 调试日志关着，没有任何错误 | 整个日志没有一行 `[AutoParryGS]`；`[AutoGuardGS]` 只有 loaded 那一行，可能再有一行 game guard angle |
| `merge_init_isolation_guard` | 场景把 `app.cHunterHealth` 拿掉 | 防御初始化失败，菜单写明原因；受击时不开标志 |
| | | 放刀的请求序列等于 A0 |
| `merge_init_isolation_parry` | 场景把 `app.AttackAreaResult.RESULT_TYPE` 拿掉 | 写 RED why=init；状态「已自停」；一刀不放 |
| | | 防御功能照常，`guard_basic` 那几项都成立 |
| `merge_reset_restore` | 一次挨打的结算中途（前置钩子跑了、后置钩子没跑）就 Reset，同时开着无限蓄力 | 角度还原；7 个 `_OverheatTime` 还原 |
| | 让 `restore_hit_state` 抛错 | 无限蓄力照样还原（v1.4.2 这时不会还原，是本轮顺手修的缺陷） |
| `merge_menu` | 检查菜单本身；在两节分别注入 imgui 故障 | 树节点和全部控件 ID 按 5.1；放刀一节出错只降级它自己；防御一节出错不影响放刀一节 |
| `merge_ref_neg_probe` | 合并版 + 归档 APCal 1.0.1；V16 第 8.4 节第 40 条的流程 | 出现 `DEAD_OBJECT`，说明模型在合并版下仍然能抓到 2c 那类故障 |
| `merge_ref_local_noaddref` | 测试脚本生成一份去掉 `r:add_ref()` 的合并版副本 | 出现 `DEAD_OBJECT` |
| | | 合并版源码里 `r:add_ref()` 必须恰好出现一次，否则这个变体生成失败、场景判失败 |

实现时补了两个场景（实现记录）：`merge_reset_restore` 的「让 `restore_hit_state` 抛错」拆成单独的 `merge_reset_restore_throw`；新增 `merge_veto_read_order`（A0 和合并版各跑一遍，比 filter 报黄的时刻），专抓 6.7 表里「否决侧见到第一个否决就停」那条变异。新场景共 29 个。

**审查补的场景**（2026-10-12，审查修订；每个场景抓一个原来全套场景都抓不住的变异，见 6.7 表末尾）：

| 场景 | 内容 | 抓什么 |
|---|---|---|
| `v16_emid_throw`（逐刀等价） | 登记时 get_EmID 抛错：这条预告不登记、不放刀，ERR msg 红一条；下一招照常 | get_EmID 挪走或包 pcall（2.7） |
| `v16_horizon92`（逐刀等价） | 长窗口条目 hs ≈ 92 时短条目进区间：不否决，照常放 | 否决视野放宽 |
| `v16_long_warning`（逐刀等价） | 400 帧的预告，登记后约 6.2 s 进区间 | 过期时间改短 |
| `v16_cand_w65`（逐刀等价） | C = 2、A = 200、窗口 65 帧，进 Q 区间时 hs ≈ 122~128（否决视野外）：不放 | 候选的窗口宽度上限 |
| `v16_entered0`（逐刀等价） | 请求在区间内一直被拒：streak 没进 (2,23) 就结束，RES entered=0、NOCATCH，「没接住」+1 | RES 的 entered、「没接住」的口径 |
| `v16_shell_order`（逐刀等价） | ShellIndex 一直抛错，先来效果攻击、后来普通攻击：filter 报黄在普通攻击进区间时 | 弹体最后读 |
| `v16_intermittent_err`（逐刀等价） | 读主角每隔一帧抛错 3 s：容忍期过后出错帧计红，成功帧清零连续计数，不自停 | 「连续」30 帧 |
| `v16_lose_res`（逐刀等价） | 进了 (2,23)、还在等结局时主角消失：当场 NOCATCH | lose_hunter 结算 res_wait |
| `v16_rehold_res`（逐刀等价） | CREDIT 内又回到抵消蓄力放第二刀：新 streak 开头结算上一刀 | start_streak 结算 res_wait |
| `v16_weapon_switch`（逐刀等价） | 预告登记后换成别的武器、动作编号仍是 (2,21)：不放；换回大剑照常 | active 里的「拿大剑」 |
| `v16_negative_window`（逐刀等价） | DANGER 条目 he < hs：不进候选 | 候选的 w ≥ 0 |
| `guard_read_fault` | 读动作控制器抛错 1 s（放刀容忍期内），期间关无限蓄力、扣一次血：还原、补血和 v1.4.2 同一帧 | 审查修订 1（防御段自己读） |
| `guard_tackle_read_fault` | 肩撞请求在等时读动作抛错一帧：清掉请求、不出肩撞，同 v1.4.2 | guard_tick 出错清 tackle |
| `guard_double_hit` | 同一帧两次受击前置钩子：角度原值只存一次，最后还原成 70 | apply_angle 的防重复保存 |
| `guard_angle_close` | 手动上捞斩接住后在 (2,28)、(2,29) 里挨打：不改写角度 | 抵消族上界 29 |
| `guard_tackle_timeout` | 肩撞请求前 22 次被拒（约 0.24 s），第 23 次接受 | 肩撞超时 0.3 s |
| `merge_isolation_parry_frame` | 放刀初始化失败（自停）后，肩撞请求、无限蓄力改写与还原、锁血补满照常，和 v1.4.2 相同 | 放刀自停不停防御的帧逻辑 |
| `merge_menu_catalog_nil` | Catalog 0~2 s 为 nil：显示「等待读取角色数据」，不报菜单错误，之后照常 | 审查修订 3（判空） |
| `merge_cfg_read_throw` | 读 AutoGuardGS.json 抛错 / 文件不存在两组（3.5 第 11、12 条） | 审查修订 2 |
| `merge_cfg_only_auto_parry` | 3.5 第 13 条 | 迁移条件看两个键 |
| `merge_cfg_lead_clamp` | 3.5 第 14 条；45 那一组的请求序列和归档 v1.6 读到 50 相同 | 读 AutoGuardGS.json 时也要 `clamp_lead` |

另外：`merge_menu` 的 guard_fault 一组加了「2 s 后防御一节恢复」的期望（审查修订 3 的重试）；`tools/mock/check_selftest.sh`（新）自测 `check.sh` 的引用记账和字形两项。

### 6.6 分析脚本与端到端

- `PYTHONIOENCODING=utf-8 python tools/apcal_analyze.py --selftest` 全部通过：原有 154 项，加上 4.4 第 4 条新增的三例。
- 回归按 4.4 末尾：第 1 轮基线的每一行都在；2a、2b、2c 只多报告头一行。
- `tools/mock/e2e_analyze.py` 加参数 `--sub merged_on`，把 B 组的输出喂给分析脚本（`--strict`）。要求：
  - 不崩溃，内部错误 0 处；
  - FIRE 一致性核对全部一致（没有 Qe1 的写法）；
  - 影子对照：nchg = 0 的放刀相差不超过 1 帧，原因不明的 0 刀；
  - rc 的自评和离线判定一致；
  - 探针版本项是「通过」。
  - 如果 e2e 在 B 组上报「原因不明」，先查分析脚本是不是在用 STAT、SKIP、VETO 来解释。如果是，改成用 ERR 和探针数据解释，不许为此恢复这些记录。

### 6.7 静态检查、部署脚本自测、变异确认

**`tools/check.sh` 改三处**：

1. 引用记账检查的文件名从 `AutoParryGS.lua|AutoParryCalib.lua` 改成 `AutoGuardGS.lua|AutoParryCalib.lua`。
2. 新增一项：去掉注释后，`src/` 下的 `.lua` 里不许出现 `°`（U+00B0）和全角空格（U+3000）。只查代码不查注释，因为原来的头注释里写过「35°」。
3. 头注释同步改。

**部署脚本自测**：用 `MHWILDS_DIR` 指向 scratchpad 里搭的假游戏目录，按 7.1 的期望逐条跑：

- 有旧 `AutoParryGS.lua` → 被挪走，新文件被复制；
- 再跑一次 → 什么都不挪；
- `autorun_disabled/` 里已有同名文件 → 新挪的文件名加上时间戳；
- 废弃文件不存在 → 什么也不做；
- 清单里的路径同时也在 `src/` 里 → 报错退出，一个文件都不复制；
- 挪动失败（例如目标目录只读）→ 报错退出，一个文件都不复制。

**变异确认**：改坏的副本只放在临时目录，仓库文件不动。每一条都必须被抓住：

| 变异 | 应当抓住它的测试 |
|---|---|
| `catchable` 去掉 pb 判断 | 等价测试：`v16_pb`、`v16_pb_unreadable`（多放一刀） |
| E5c 累加改用本帧的 m（应当用上一帧的 m） | 等价测试：`v16_e5c_change`、`v16_noncharge` |
| 否决侧见到第一个否决就停止读后面的条目 | `merge_veto_read_order`：长窗口否决 + 后一条的 `_GuardType` 读不出，filter 报黄的时刻和 A0 比（不改决策，但会被报出来）。实现记录更正：原稿写的 `v16_multi_attr` 抓不到它，121 个 v16 场景都抓不到（实测），所以补了这个场景 |
| 读主角失败时不走容忍期，直接按帧逻辑出错 | 等价测试：`transient_throw`、`v16_gap_hunter` |
| 迁移不看旧文件的 cfg_ver | `merge_migrate_old_ver`；等价测试：`v151_keep26` |
| 调试日志关着时跳过 `res_wait` 的记账 | C 组的计数比较 |
| `next_id` 只在写 FIRE 时才递增 | B、C 两组 RES 的 id 对不上；`merge_debug_toggle` |
| 帧开头不调 `restore_hit_state` | `guard_angle`（后置钩子缺席的那一段） |
| 钩子里改用帧开头的动作快照 | `guard_angle`：同一帧里先进 (2,23)、再发生刀上碰撞；场景要造出「帧开头不在抵消族、钩子时已在抵消族」的时刻 |
| 防御出错计入放刀的红黄计数 | `merge_init_isolation_guard` 的状态行 |
| `deploy.sh` 把挪动改成删除 | 部署脚本自测 |
| 审查修订补的（2026-10-12）：get_EmID 包进 pcall | `v16_emid_throw`（A0 不登记这一招，变异多放一刀） |
| 成功的帧不把 `consec_err` 清零 | `v16_intermittent_err`（变异约 0.7 s 后自停，之后不放刀） |
| `lose_hunter` 不结算 `res_wait` | `v16_lose_res`（B 组 RES 的时刻、dt 不同） |
| 开新 streak 时不结算 `res_wait` | `v16_rehold_res`（B 组 RES 晚一帧） |
| active 去掉「拿大剑」 | `v16_weapon_switch`（变异在别的武器上放刀） |
| 候选去掉 w ≥ 0 | `v16_negative_window` |
| 否决视野 hs ≤ 90 改成 ≤ 95、≤ 100 | `v16_horizon92` |
| 过期 8 s 改成 6 s | `v16_long_warning` |
| 候选的窗口宽度上限 60 改成 70 | `v16_cand_w65` |
| RES 的 entered 恒写 1；没进 (2,23) 的不计「没接住」 | `v16_entered0`（B 组的 entered；B、C 组的计数） |
| `catchable` 第一句先读 ShellIndex | `v16_shell_order`（filter 报黄的时刻） |
| 帧回调里放刀一自停就整段返回（防御的帧逻辑跟着停） | `merge_isolation_parry_frame` |
| `apply_angle` 去掉「已经改过还没还原就别再保存」 | `guard_double_hit` |
| 抵消族上界 29 改成 28 | `guard_angle_close` |
| 肩撞超时 0.3 改成 0.2 | `guard_tackle_timeout` |
| 迁移条件只看 `parry_lead` | `merge_cfg_only_auto_parry` |
| 读 AutoGuardGS.json 时 `parry_lead` 不经 `clamp_lead` | `merge_cfg_lead_clamp` |
| 审查修订 1 撤回（快照抛错时防御段直接跳过这一帧） | `guard_read_fault` |
| guard_tick 出错时不清 tackle | `guard_tackle_read_fault` |
| 审查修订 2 撤回：AutoGuardGS.json 读不出表也在加载时写回；读盘抛错的那次加载照常存配置 | `merge_cfg_read_throw`（两组各抓一个） |
| 审查修订 3 撤回：`get_Catalog()` 不判空；菜单分块出错后一直降级 | `merge_menu_catalog_nil`；`merge_menu` |
| `check.sh` 换回原来的正则 | `check_selftest.sh`（5 条判失败的写法漏掉） |
| 分析脚本合并版的 sidmis 判通过 | `apcal_analyze.py --selftest`（158/159） |

### 6.8 完成标准（全部通过才算实现完成；本轮不部署）

1. `bash tools/check.sh` 通过。`src/` 下没有 `AutoParryGS.lua`。`AutoGuardGS.lua` 里没有下列任何一项：
   - 引用操作：`:release(`、`.release` 当函数传、`force_release`、`add_ref_permanent`；
   - 已删记录的标识：`FIRE_END`、`VETO`、`STAT`、`CFG`、`UVIEW`、`SKIP`、`DBG`；
   - 数据文件写盘：`json.dump_file` 只用来写配置文件。
2. `lua tools/mock/run.lua`：133 个场景（参照组）0 失败；`--smoke` 的 23 个 0 失败。（审查修订后是 144 个。）
3. `lua tools/mock/run.lua --merged`：
   - 121 个场景的 B、C 两组对 A0 **0 差异**（审查修订后是 132 个）；
   - 6.5 的新场景 0 失败；
   - 负对照符合预期。
4. `lua tools/mock/run.lua --merged --gc-every-frame` 跑引用相关的场景：`v16_ref_shared`、`v16_ref_local`、`track_full`、`track_evict`、`player_swap`、`ui_toggle`、`v16_x0_keep`、`v16_gap_hunter`，0 失败。
5. 分析脚本自检全部通过，回归按 4.4；e2e 的 B 组 0 问题。
6. 部署脚本自测全部通过；6.7 的变异全部被抓住。
7. 行数不超过 1250，超了就说明原因。
8. 实现记录写进本文末尾：改了什么；验证的命令和结果；两份归档的 md5；豁免表（应当为空）。

---

## 7. 部署

### 7.1 `tools/deploy.sh` 的废弃清单

在 `deploy.sh` 里加一个清单。路径相对游戏根目录，并且必须在 `reframework/autorun/` 下：

```bash
# 已废弃、旧版部署过的文件。部署时挪到 reframework/autorun_disabled/，不删除。
# 为什么挪、不删：REF 只加载 autorun/ 下的脚本，挪走就不会和新脚本同时运行；
# 要回滚时原样挪回来就行（docs/autoparry/MERGE.md 第 7 节）。
OBSOLETE=(
    "reframework/autorun/AutoParryGS.lua"   # AutoGuardGS v1.5 起并入 AutoGuardGS.lua；两个同时跑会重复放刀
)
```

执行顺序：

1. 先跑 `check.sh`（原样）。
2. **一致性检查**：清单里的文件名如果也出现在 `src/` 里，报错退出。清单写错了会把刚部署的新文件挪走。
3. **先撤废弃文件**。对清单里每一项：
   - 如果在游戏目录里存在：先 `mkdir -p "$GAME/reframework/autorun_disabled"`；
   - 目标文件已经存在时，新挪的文件名改成 `名字.<YYYYmmdd-HHMMSS>.lua`；
   - `mv` 过去，并打印 `  ↷ reframework/autorun/AutoParryGS.lua → reframework/autorun_disabled/…（已废弃）`；
   - `mv` 失败就报错退出（`set -e`），**一个新文件都不复制**。顺序反过来的话，可能出现新旧两个脚本同时在 autorun 里的局面。
4. **再复制 `src/`**（原样）。
5. 最后汇总：撤下了 N 个废弃文件、更新了 M 个文件。

**探针不进清单**：

- `AttackTimingProbe.lua` 和 `AutoParryCalib.lua` 不是 `deploy.sh` 部署的，研究时还要手动放回去；
- 如果进了清单，每次部署都会把它们挪走，以后想同时跑探针就做不到了；
- 这次由主线程手动处理（7.2）。

脚本运行期间挪文件：REF 加载脚本时把文件读进内存，之后不占用文件，所以游戏开着时也能挪（推测）。万一挪不动（文件被占用），按第 3 步的规则失败退出，一个文件都不复制。

### 7.2 测试环境收尾（主线程负责，需要用户同意）

1. 把游戏 `reframework/autorun/` 里的 `AttackTimingProbe.lua`、`AutoParryCalib.lua` 挪到 `reframework/autorun_disabled/`。这个目录游戏里已经有，里面是更早的探针。仓库里 `probes/` 下的文件不动。
2. 运行 `tools/deploy.sh`：它会挪走 `AutoParryGS.lua`，再复制新的 `AutoGuardGS.lua`。
3. 部署是会改变用户环境的动作，每一次都要先问用户。

### 7.3 部署后用户要做什么

1. 在游戏里打开 REF 菜单，点 **Reset Scripts**，或者重启游戏。
2. **核对菜单**：Script Generated UI → **大剑自动防御 v1.5**。
   - 里面有「自动放刀（实验）」一节，提前量是 28，这是从旧配置迁过来的值。
   - **不应该再有**单独的「自动放刀（实验）」树节点。如果有，说明旧的 `AutoParryGS.lua` 还在 autorun 里，按 `deploy.sh` 的输出排查。
3. **核对日志** `re2_framework_log.txt`：
   - 应当有：`[AutoGuardGS] v1.5 loaded`；用户的调试日志是开着的，所以紧接着还有一行 `[AutoParryGS] HDR ver=1.6 … host=AutoGuardGS-v1.5`。
   - 不应当再有：`[APCal] HDR`、`[ATP] HDR`，以及不带 `host` 字段的 `[AutoParryGS] HDR`。
4. `reframework/data/AutoGuardGS.json` 里多了 `auto_parry`、`parry_lead` 两个键。
5. **持续监控**：「调试日志」保持开着。用户当前的配置就是开着的。打完一局后：
   - 把日志发回来，或者自己 grep `[AutoParryGS] FIRE` / `RES`；
   - 离线分析用 `python tools/apcal_analyze.py <任意目录> --log <日志路径> --session <HDR 里的 session>`。
6. **可选清理**：`reframework/data/` 下的旧研究数据不会再增长了。
   - 包括 `AutoParryGS_*.json` 1084 个、`APCal_*.json` 640 个，以及 `ATP_*.json`。整个 data 目录现在约 165 MB，大部分是这些文件（2026-10-11 实测）。
   - 挪不挪由用户决定；`deploy.sh` 不碰 data 目录。
   - 旧配置 `AutoParryGS.json` 留着无害，回滚时还要用。

### 7.4 回滚

1. 把 `reframework/autorun_disabled/AutoParryGS.lua` 挪回 `reframework/autorun/`。
2. 把 `tools/archive/AutoGuardGS_v1.4.2.lua` 复制到游戏的 autorun，文件名改成 `AutoGuardGS.lua`。
3. 点 Reset Scripts。

**配置不用动**：

- v1.4.2 会忽略 `AutoGuardGS.json` 里的两个新键；存配置时会把它们丢掉，所以以后再升级会重新迁移一次，结果相同。
- v1.6 照旧读 `AutoParryGS.json`，合并版从来不写这个文件。

---

## 8. 文档改动清单

| 文件 | 改什么 |
|---|---|
| `README.md` | **功能表**加一行「自动放刀」：按住抵消蓄力时，读怪物发给主角的攻击预告；危险攻击的真实剩余时间（按怪物速度修正）落进窗口，就在帧开头请求抵消上捞斩；伤害、火花、弹开都来自刀和攻击的原生碰撞。状态写「**实验**」 |
| | **不放刀的情况**：弹体；咆哮、风压、震动；抓取；会把刀弹开的攻击（`_IsParryBreak`）；UNABLE_GUARD、SKILL_GUARD；1.5 s 内有长窗口或抓取攻击时整帧不放；联机副本怪 |
| | **验收现状**写成：机制检验（A 阶段）在 5 只新怪上通过；正式验收（B 阶段）**没做**；实际只在缠蛙（em19，设计数据里的旧怪）上试打过，**7 刀接住 5**（2026-10-11） |
| | 删掉「自动放刀……已暂时搁置……」那一句 |
| | 设置段：放刀设置在同一个菜单里；首次加载会从旧 `AutoParryGS.json` 迁移，旧文件不动 |
| | 「注意」段加两条：联机时副本怪不放刀；打开调试日志后，每次放刀写两行 `[AutoParryGS]` |
| | 开发段：加上 mock（参照组、`--merged` 等价测试）、`apcal_analyze.py --selftest`、`deploy.sh` 的废弃清单、`tools/archive/` |
| `docs/NOTES.md` | 「怪物攻击预告」一节，依据是 SPEED 第 8 节第 15 条、V16 第 12 节第 10 条，见下表 |
| | 「抵消上捞斩」一节，见下表 |
| | 「大剑动作编号」表，见下表 |
| | 「走过的弯路」表，见下表 |
| `docs/autoparry/V16.md` | 顶部「状态」加一段（2026-10-11）：v1.6 的放刀逻辑已经并入 AutoGuardGS v1.5，见 MERGE.md |
| | 独立的 `AutoParryGS.lua` 已删，归档在 `tools/archive/AutoParryGS_v1.6.lua` |
| | 规则（E5c、L = 28、该接过滤 g1、否决口径）一处没改，有逐刀等价测试为证 |
| | 第 6 节（记录）、第 7 节（分析脚本 1.4）、第 8 节（mock）描述的是归档的独立 v1.6；合并版的日志格式见 MERGE 第 4 节 |
| | 第 9 节 B 阶段验收**没做**，只在缠蛙上试打过 7 刀；调试日志就是持续监控的手段；第 9 节的协议留着备用 |
| `docs/autoparry/MERGE.md` | 实现完成后在末尾追加「实现记录」 |
| `tools/mock/run.lua`、`tools/mock/scenarios.lua` 头注释 | v16 改指向归档；说明合并模式、别名规则、三组跑法 |
| `tools/check.sh` 头注释 | 引用记账检查改查 `AutoGuardGS.lua`；加上「`°` 和全角空格」那项检查 |
| `CLAUDE.md`（可选，一行） | 调试日志那条补一句：「放刀记录的标签是 `[AutoParryGS]`，写在 AutoGuardGS.lua 里」 |

NOTES 的具体改动：

| 位置 | 改成 |
|---|---|
| 「怪物攻击预告」：「攻击期间每帧重发」 | 每个结果对象只发一条消息，内容实时更新（实测：1620/1620） |
| 「怪物攻击预告」：剩余帧「实时倒数」 | 剩余帧的初值是怪物在 1 倍速下的名义帧，之后接收端按真实时间每秒减 60 |
| 「怪物攻击预告」：「剩余帧归零 ≈ 激活」 | 只在 C = 1 时成立；C > 1 时攻击早到约 A·(1 − 1/C)/60 秒 |
| 「怪物攻击预告」（新增） | CoreState 按招在进入动作的那一帧设定，正好是发消息的那一帧，所以要从下一帧的帧回调读 |
| 「怪物攻击预告」（新增） | 卡顿时计时器单帧最多扣约 0.133 s（8 帧） |
| 「怪物攻击预告」（新增） | E5c 公式；A 阶段结果：5 只新怪 210 个单位，5 条判据全部通过（SPEED 第 7.1.1 节） |
| 「怪物攻击预告」：引用记账一段的「改法（待做）」 | 已做：v1.6 和 APCal 1.1 都改了。v1.6 试打约 63 分钟，STAT 里 red 一直是 0 |
| 「抵消上捞斩」：预判放刀规则 | 改成 E5c 的 Q，L = 28（真实剩余帧）；L 的变迁历史补上 v1.6 |
| 「抵消上捞斩」：G1 结论 | (2,25) HitS 是 RECOIL，即被弹开、随即挨打，**不算接住**；RECOIL 的 4/4 都是 pb = 1，WAIT 的 53/53 都是 pb = 0 |
| | SKILL_GUARD 只出现在抓取上；UNABLE_GUARD 只出现在 GESTURE 上，能不能抵消从没测过（实现记录更正：「只在 GESTURE 上」是设计数据的说法，A 阶段 em15 有 12 个 UNABLE_GUARD 条目、伤害类型 NONE；NOTES 已按这个写） |
| 「抵消上捞斩」：抓取否决 | 扩展到 SKILL_GUARD 家族 |
| 「抵消上捞斩」（新增） | v1.6 试打结果（第 9 节第 1 条的那组数）；APCal 同时在跑，那两刀没接住的离线分类本文没做 |
| 「大剑动作编号」表：(2,21) 一行 | 「**不会**进入 (2,22)」不对：v1.6 试打 7 刀里有 3 刀是从 (2,22) cParryCharge 放出的（FIRE 的 `from=(2,22)`，实测）；(2,22) 能放刀，早先 14:57:01.594 也实测过（实现记录更正：旧说法对 (2,21) 本身成立，两份日志里 (2,21) → (2,22) 都是 0 次；(2,22) 是从纵斩、肩撞等攻击之后接出时直接进的。两个都能放刀。14:57:01.594 那条在现存日志里核对不到，NOTES 改引第 1 轮） |
| 「大剑动作编号」表：(2,25)~(2,27) | 注明 (2,25) 是被弹开 |
| 「走过的弯路」表（新增几行） | 把 hs 当真实剩余时间 → C > 1 时放早（2c 的 em27：有接触的 6 刀里 5 刀放早） |
| | 在消息钩子里读 CoreState → 读到上一招的值 |
| | 用 os.clock 当 X 的时钟 → 卡顿时漂移 |
| | 时钟上限固定为 30 → 断档后放刀偏晚 |
| | 两个脚本各自 release 同一个对象 → 悬空指针 |
| | 在 pb = 1 的招上放刀 → 被弹开 + 挨打 |
| | 把 (2,25) 算作接住 → 接住率虚高 |
| | 在抓取上放刀 → 被抓（259 伤害） |

---

## 9. 风险与未决

1. **v1.6 的正式验收（B 阶段）没做**。实测证据只有 2026-10-11 的试打（session 1791712779）：
   - 7 刀全打在 em19（缠蛙）上，em19 是设计数据里见过的怪；
   - 接住 5 刀：HitL 3 刀（id 1、4、7），HitM 2 刀（id 2、6）；
   - 没接住 2 刀（id 3、5）：都在 (2,23) 停到结算，`to=-`。两刀的 C1 都是 1.155。是空挥还是先砍中把怪打断，没有分类；
   - 被弹开 0 次；否决 3 次（都是长窗口）；错误 0。
   - 试打时的条件（审查修订：原稿没写；游戏日志里 APCal 的 HDR 的 `cfg_guard`，实测）：AutoGuardGS v1.4.2 的自动防御开着，【测试】锁血、【测试】无限蓄力开着，防御角度 360；探针 APCal 1.1 和 ATP 同时在跑。这些开关不进放刀的判断和结局判定（代码）；但无限蓄力让抵消蓄力不会 2.5 s 过热自动放出、锁血让人倒不下，放刀的机会和节奏和正常打不一样（推测不影响每一刀接没接住）。用户现在的 `AutoGuardGS.json` 还开着这几项，部署后靠调试日志的监控也是在这些条件下采样。
   - **正式验收（B 阶段，V16 第 9.2 节）时这些测试开关开不开，没定，等用户定**：协议本身没写。选项是照试打的条件（好收集样本，验收结论只代表这种条件），或者全关（接近正常打法，要打更久）。不管哪种，HDR 里都要能看出当时的开关（APCal 的 `cfg_guard` 已经记）。
   - 新怪上的接住率、空放率都没有数。A 阶段的机制检验通过了（SPEED 第 7.1.1 节），但没覆盖到：存活期间 C 有变化的单位 0 个；C 最高只到 1.155；历战个体没有确认。
   - 合并之后，「调试日志 + 离线分析」就是持续监控的手段。
2. **防御在抵消动作族里会不会强开防御标志**（1.4）：如果关掉 `respect_armor`，(2,21)/(2,23) 里由行为表决定，没测过。合并前后相同，本轮不改。如果以后要加「抵消动作族里不强开防御」，那是改防御的行为，要单独做一轮。
3. **探针 APCal 的 HDR `cfg_parry` 读的还是 `AutoParryGS.json`**：合并后那个文件不再更新。以后重新部署探针做研究时，要看 `cfg_guard` 里的 `auto_parry` / `parry_lead`。探针本轮不改。
4. **分析脚本对合并版的能力有缺口**：
   - 没有 STAT，开销要看 PERF 行（4.4 第 5 条可选，本轮没做：合并版的 D16 开销项写「—」，D16 只会判样本不足或需复核）；
   - 没有 CFG，开关的切换看不到，滑块改动靠 FIRE 的 L 推断；
   - HDR 是懒写的，如果调试日志中途才打开，HDR 记的是那一刻的值。
   - 结论：要用合并版做正式验收，需要把调试日志整局开着、同时跑探针，并先把 4.4 第 5 条做了。
5. **版本号撞名**（1.1）：靠「HDR 的 ver 是规则版本」加上 `host` 字段区分。人看日志时要注意：`[AutoGuardGS] v1.5` 和 `[AutoParryGS] ver=1.6` 指的是两个不同的版本号。
6. **合并后一个脚本挂了两部分**：语法错误会让两部分一起失效，靠 `check.sh` 和 mock 在部署前拦住。运行时错误靠 1.5 的隔离。
7. **请求了 (2,23) 却进了 (2,24)**（V16 第 12 节第 6、12 条）：合并后不变，仍记作没进入 + NOCATCH。
8. **低帧率**：L = 23 时窗口只有 1 帧宽（V16 第 12 节第 7 条），合并后不变。

---

## 附录 A：v1.6 的函数逐个去留

「保留」= 逻辑原样保留，只删函数体里写记录、写计数的行。

| v1.6 函数 | 合并后 | 删掉了什么 |
|---|---|---|
| `clean_str`、`int_s`、`finite`、`hex`、`safe_fmt` | 保留，挪到 §1 当公共工具 | — |
| `fmt_value` | 保留 | 只返回日志文本，删掉 JSON 那一份值 |
| `SPEC` 构造 | 保留 | 只剩 5 种（4.2） |
| `round4`、`build`、`emit` | 合成 `rec(kind, vals)` | JSON；没有 t 时补 t；改成第一次写之前补写 HDR |
| `dbg_line`、`dbg` | **删** | — |
| `set_red` | 保留 | — |
| `err_flush` | **删** | — |
| `note_error` | 保留：分级、`mod_off`、`times` 都在 | `recent`、`queue`、`json_n`、`final`；ERR 前 20 条立刻写 |
| `write_json` | **删** | — |
| `clamp_lead` | 保留（§3 用） | — |
| `load_config` | **删**，改用 §3 的 `load_config` / `migrate_parry_config` | — |
| HDR 的写出 | 改成懒写 | — |
| `enum_value` | 保留 | — |
| `self_stop_init`、初始化代码块 | 保留，放进 `init_parry` | DBG grab_enum / guard_enum → HDR 的 `enum_skip` |
| `master_hunter` | 合进共享的 `read_frame` | — |
| `addr_of`、`request_slash` | 保留 | — |
| `drop_track`、`release_all_tracks` | 保留 | — |
| `drop_oldest` | 保留 | DBG |
| `read_master` | 保留 | 只返回 m；删掉 `snd` 和那次 get_address |
| `on_message` | 保留，所有读取照旧（含 `get_EmID`） | 字段 fo、sk、fe、snd、ql、qf；failopen、replica 计数 |
| 消息钩子的注册 | 保留，套上 `timed("msg", …)` | `hook_ms` |
| `core_read`、`core_of` | 保留，只返回 C | 怪物地址、why |
| `clock_delta` | 保留 | — |
| `speed_step` | 保留 | clockskip、speedfail、speedhold 计数；sidmis；DBG speed_fail（判断条件的写法不变：仍是「在区间里才累加」） |
| `read_items`、`has_shell`、`shell_of`、`ap_field`、`classify` | 保留 | — |
| `filter_error` | 保留 | ferr、fe |
| `filter_reason` | 改成 `catchable`（2.7） | — |
| `keep_text` | 保留，只在写 FIRE 时调 | — |
| `keep_or_nil` | 保留，作为 FIRE 的 keep 读取：读不到写 `-`，不计错误 | — |
| `skip_entry`、`set_veto` / `WHY_RANK`、`pick_u` | **删** | — |
| `consider` | 保留，遍历和读取顺序不变 | Qp、vq、U 候选、failopen、SKIP；否决改成 `ev.veto = true` |
| `process_track`、`evaluate` | 保留 | — |
| `finish_res` | 保留 | 计数拆开；RES 只在调试日志开着时写，带 entered |
| `start_streak` | 保留 | vetoq、qe1、UVIEW；FIRE 只在调试日志开着时写 |
| `end_streak` | 保留 | FIRE_END；`res_wait` 记上 entered |
| `update_fire` | 保留 | VETO、`veto_on`、vetoes、`streak.n` / `r1` |
| `lose_hunter` | 保留 | `veto_on` |
| `read_hunter` | 合进共享的 `read_frame` | — |
| `read_failed` | 保留 | DBG |
| `frame_logic` | 保留，读主角的结果由参数传进来 | `action_gap`、DBG、`act_cat` / `act_idx` |
| `self_stop` | 保留 | DBG self_stop；`act_cat` 清零 |
| `is_idle`、`stat_emit`、`periodic` | **删** | — |
| 帧回调 | 合进唯一的帧回调（1.3） | `lua_win`、`periodic`、`err_flush` |
| `set_cfg` | **删**，改成直接赋值 | — |
| `draw_status` | 保留，文字按 5.2 | — |
| `draw_dump`、`draw_menu_min`、`draw_menu` | 合成菜单里放刀那一节（第 5 节） | — |
| Reset 回调 | 合进统一的 Reset，见下 | STAT、JSON、ERR 补写 |
| 存配置回调 | 合进统一的存配置 | `cfg_ver` |
| 最后一行 DBG「loaded」 | **删** | — |

统一的 Reset 依次做三件事，每件各自 pcall：先 `restore_hit_state`，再 `restore_overheat`，最后丢弃预告跟踪、结算没结束的放刀和结局。

v1.4.2 的函数全部保留，逻辑不变。有改动的地方：

- `release` 改名为 `restore_hit_state`；
- 帧回调里的 `update_tackle` / `charge_index` 改用快照；
- 钩子、帧逻辑、菜单、Reset、存配置都包上 pcall；
- 警告加上每类 20 行的上限；
- `prof` 加 msg；
- 初始化放进 `init_guard`；
- 「启用」的文字改了。

---

## 实现记录（2026-10-12）

实现分三块并行做：合并脚本（B1）、测试与工具（B2）、文档（B3）；之后集成，把第 6.8 节的验收在定稿上从头跑了一遍。**没部署**；游戏目录只读过（核对 md5、跑 `deploy.sh --dry-run`）；没动 git 状态。

### 1. 改了什么

| 文件 | 改动 |
|---|---|
| `src/reframework/autorun/AutoGuardGS.lua` | AutoGuardGS v1.5 = v1.4.2 + v1.6 的放刀逻辑，按第 1~5 节；1414 行 |
| `src/reframework/autorun/AutoParryGS.lua` | 删掉（它在 git 里本来就没跟踪，`git status` 里看不到这次删除） |
| `tools/archive/AutoParryGS_v1.6.lua`、`tools/archive/AutoGuardGS_v1.4.2.lua` | 新增：原样归档（第 6.1 节） |
| `tools/mock/run.lua`、`game_sim.lua`、`mock_ref.lua`、`scenarios.lua` | 合并模式 `--merged`（第 6.2、6.3 节）；v16 场景改跑归档；29 个新场景（第 6.5 节） |
| `tools/mock/e2e_analyze.py` | 加 `--sub`（第 6.6 节） |
| `tools/mock/deploy_selftest.sh` | 新增：`deploy.sh` 废弃清单的自测（第 6.7 节），只用临时目录 |
| `tools/apcal_analyze.py` | 1.5（第 4.4 节第 1~4 条），自检 154 → 159 项 |
| `tools/check.sh` | 第 6.7 节三处 |
| `tools/deploy.sh` | 废弃清单（第 7.1 节），另加 `--dry-run` |
| `README.md`、`docs/NOTES.md`、`docs/autoparry/V16.md`（只加顶部「状态」一节） | 第 8 节 |
| 本文 | 本节；正文里标「实现记录更正」的几处 |

### 2. 归档与 md5（2026-10-12 核对）

| 文件 | md5 | 核对 |
|---|---|---|
| `tools/archive/AutoParryGS_v1.6.lua` | `a83527d92432e618885c38d561199338` | 和游戏 autorun 里现在部署的 `AutoParryGS.lua` 逐字节相同 |
| `tools/archive/AutoGuardGS_v1.4.2.lua` | `85fedcc0b0e1073987736d4a6c689897` | 和游戏 autorun 里现在部署的 `AutoGuardGS.lua` 逐字节相同 |
| `src/reframework/autorun/AutoGuardGS.lua`（合并版） | `afcf39a99cdb9c2df4fff30fe11fabfd` | 第 3 小节的验证都跑在这一份上 |

- v1.4.2 的归档是集成时补的：实现阶段 B1 的文件范围里没有它，B2 先在 `tools/mock/archive/` 放了一份同 md5 的测试副本。集成时把它挪到 `tools/archive/`，`run.lua` 改用这一份。
- git 里只有更早的 AutoGuardGS v1.3，所以这份归档是回滚（7.4）唯一的来源。

### 3. 验证命令与结果（集成时在定稿上重跑）

mock 的输出集成时用 `--out` 写到临时目录，和默认的 `tools/mock/out/` 等价。

| 第 6.8 节 | 命令 | 结果 |
|---|---|---|
| 1 | `bash tools/check.sh` | 13 个文件全过（src 1 个、probes 12 个），退出码 0 |
| 1 | 去掉注释后 grep | 没有 `:release(`、`.release` 当函数传、`force_release`、`add_ref_permanent`；`add_ref()` 恰好 1 处 |
| | | 整词 FIRE_END / VETO / STAT / CFG / UVIEW / SKIP / DBG：0 处（连注释里也是 0） |
| | | `json.dump_file` 只在 `save_config`；全文没有 ° 和全角空格的字节；`%d` 只用在 v1.4.2 原有的整数上 |
| 1 | 游戏引用的静态核对：脚本里的字符串字面量，对两份归档的并集 | 没有新的类型、方法、字段名。唯一「新」的是 requestDamage 的签名拆成了两段字面量，拼起来和 v1.4.2 一字不差 |
| 2 | `lua tools/mock/run.lua` | 133 个场景 0 失败（约 60 s） |
| 2 | `lua tools/mock/run.lua --smoke` | 23 个场景 0 失败 |
| 3 | `lua tools/mock/run.lua --merged` | 162 个场景 0 失败（约 3.6 min） |
| | | **121 个 v16 场景，B、C 两组对 A0 都是 0 差异** |
| | | 29 个新场景 0 失败；两个合并版负对照各出现 1 次 DEAD_OBJECT（预期） |
| 4 | `lua tools/mock/run.lua --merged --gc-every-frame`，8 个引用场景加 2 个合并版负对照 | 10 个场景 0 失败；8 个等价比较 0 差异 |
| 5 | `python tools/apcal_analyze.py --selftest` | 159/159（原 154 项 + 1.5 新增 5 例） |
| 5 | 第 1 轮回归：`python tools/apcal_analyze.py tools/out/round1_data` | `round1_report_baseline.md` 的 316 行按顺序全在；新报告 423 行，内部错误 0 |
| 5 | 2a、2b、2c、trialB0：`--session <各自的> --calib-session 1791644664 --calib-dir tools/out/round1_data` | 和 1.4 的输出比，只多报告头 1 行（1.5 的修订说明），一行没少；内部错误 0 |
| 5 | `python tools/mock/e2e_analyze.py <out> --sub merged_on` | 121 个场景（都是 v1.6 session）：FIRE 一致性核对 155 行全部一致；影子对真 FIRE 150 刀；影子不触发 5 刀，逐条有原因；问题 0 处 |
| | 不带 `--sub`（A0） | 133 个场景，同样的数，问题 0 处 |
| 6 | `bash tools/mock/deploy_selftest.sh` | 6 组全过 |
| 6 | 变异确认 | 第 5 小节，全部抓住 |
| 7 | 行数 | 1414，超了，原因见第 6 小节第 5 条 |
| — | `bash tools/deploy.sh --dry-run`（真实游戏目录，只读） | 列出 `↷ reframework/autorun/AutoParryGS.lua → reframework/autorun_disabled/AutoParryGS.lua` 和 `→ reframework/autorun/AutoGuardGS.lua`。前后比对了游戏 autorun 的目录列表和 md5，什么都没改 |

- 「1.4 的输出」是 B2 在改分析脚本之前用 1.4 跑的（01:25 生成，分析脚本 01:29 才改）；1.4 没有单独归档，集成时没法再生成一遍。第 1 轮的基线不依赖这一点。

### 4. 豁免表：空

121 个场景全部 0 差异，没有豁免。

已知的错误口径差异，来自 2.7 的 C 类删读取。它们不在场景集里，所以不进豁免表。实现阶段自建了三个故障场景实测过：差异只在错误记录和状态行，请求序列、FIRE、RES、计数都相同。

| 故障 | v1.6 | 合并版 | 对应 |
|---|---|---|---|
| 不该接条目的 ShellIndex 抛错 | 报 filter 黄（SKIP 路径读了它） | 不读、不报 | C 类第 3 条 |
| 放刀那一帧视野里 U 条目的 ShellIndex 抛错 | 报 filter 黄（UVIEW 读了它） | 不读、不报 | C 类第 4 条 |
| 放刀时读 keep 抛错 | 计一次 frame 红错误 | FIRE 里写 `-`，不计 | C 类第 5 条，本轮唯一有意改的错误口径 |

以后把这类场景加进集合，要按 6.3 写进豁免表。

### 5. 变异确认

集成时用仓库的 `run.lua --merged-path <改坏的副本>` 跑指定场景，副本只放在临时目录：

| 变异 | 抓住它的场景 |
|---|---|
| `catchable` 去掉 pb | `v16_pb`（多放一刀，探针多记一次结局）、`v16_pb_unreadable`（请求序列不同） |
| E5c 累加改用本帧的 m | `v16_e5c_change`、`v16_noncharge`（FIRE 的 dX、Q0 不同） |
| 否决侧见到第一个否决就停 | `merge_veto_read_order`（filter 报黄从 1003.0111 变成 1003.8778）；`v16_multi_attr` 抓不到 |
| 读主角失败不走容忍期 | `transient_throw`（多出 RED 3in10s）、`v16_gap_hunter` |
| 迁移不看 cfg_ver | `merge_migrate_old_ver`、`v151_keep26`（提前量成了 26，应为 28） |
| 调试日志关着时不记 `res_wait` | `two_entries`、`v16_catch_tiers`（C 组的接住计数是 0） |
| `next_id` 只在写 FIRE 时递增 | `merge_debug_toggle`（中途打开那组 FIRE 的 id 对不上）；`v15_menu_misc` 抓不到（C 组不比 FIRE 的 id） |
| 帧开头不调 `restore_hit_state` | `guard_angle` |
| 钩子里改用帧开头的动作快照 | `guard_angle`（在抵消动作族里改写了角度） |
| 防御出错计入放刀的红黄计数 | `merge_init_isolation_guard` |
| `deploy.sh` 把挪动改成删除 | `deploy_selftest.sh` |

实现阶段另做过：B1 12 个（用自己的等价驱动），B2 合并脚本 16 个、`deploy.sh` 4 个、分析脚本 5 个，全部抓住。

### 6. 和正文的出入

1. **结构**：两份脚本合起来，顶层有 248 个局部变量，超过 Lua 一个函数 200 个的上限，luac 直接报错。
   - 所以防御（§5）、放刀（§6）各放进一个 do 块，只露出 8 个函数：guard_tick、restore_hit_state、restore_overheat、draw_guard、draw_tests、parry_tick、parry_reset、draw_parry。
   - 两部分互相看不见对方的状态。两节菜单的绘制函数也就放在各自的 do 块里，§9 只负责拼起来。
2. **命名**：1.2、1.3 里的 `read_frame` 实际叫 `read_hunter`，调用顺序同 1.3。
3. **多删了一个变量 `frame_no`**：删掉 Qp 之后它只写不读，属于 2.7 的 A 类。
4. **`init_guard` 加了 `need()`**：类型、方法拿不到时报出名字，例如「app.cHunterHealth not found」，菜单里的初始化失败原因看得懂。
5. **行数 1414，超过目标 1250**：
   - 构成：代码 1118 行、注释 200 行、空行 96 行。两份原稿是代码 1242、注释 215、空行 103，合计 1560。
   - 代码比两份原稿合计少 124 行。超出目标的是本文新加的结构：分段 pcall、两部分初始化隔离、菜单分块降级、配置迁移、HDR 懒写、防御警告限次。
   - 要压到 1250 只能删「为什么」的注释，没有这样做。
6. **6.5 的新场景**：多了 `merge_reset_restore_throw`、`merge_veto_read_order`（见 6.5 末尾），共 29 个。
7. **6.7 表的「否决侧见到第一个否决就停」**：原稿说 `v16_multi_attr` 能抓到，实测 121 个场景都抓不到，改由 `merge_veto_read_order` 抓（已改 6.7 表）。
8. **6.2 第 3 条**：ACTION_ATTR 是 28 个名字，不是 29（已改）。
9. **分析脚本**：
   - 4.4 第 4 条要三例自检，实际加了 5 例，共 159 项。
   - 4.4 第 5 条（解析 PERF 行）没做，见第 9 节第 4 条。
10. **放刀初始化失败时的状态行**：沿用 v1.6 的措辞「已自停（帧逻辑连续出错）」，为的是和 v1.6 等价。初始化失败时这句话不太贴切，要不要另写一句由用户定；改了要同时改等价比较里状态行的归一化。
11. **文档阶段的更正**（B3 只读核对游戏日志得出）：(2,22) 的入口、14:57:01.594 那条记录、UNABLE_GUARD 出现在哪些攻击上。第 8 节对应几行已标更正，NOTES 按更正后的写。
12. **第 8 节 CLAUDE.md 那条可选的一行**：没加。

### 7. 部署前后（主线程负责，每一步都要先问用户）

1. 测试环境收尾（7.2）：把游戏 autorun 里的 `AttackTimingProbe.lua`、`AutoParryCalib.lua` 挪到 `autorun_disabled/`。仓库 `probes/` 下的文件不动。
2. 运行 `tools/deploy.sh`：dry-run 已核对过，它会挪走 `AutoParryGS.lua`，再复制新的 `AutoGuardGS.lua`。
3. 用户点 Reset Scripts 后按 7.3 核对：
   - 只有一个树节点「大剑自动防御 v1.5」，里面有「自动放刀（实验）」一节，提前量 28；
   - 日志里有 `[AutoGuardGS] v1.5 loaded`，紧接着一行 `[AutoParryGS] HDR ver=1.6 … host=AutoGuardGS-v1.5`（用户的调试日志开着）；
   - `AutoGuardGS.json` 多了 `auto_parry`、`parry_lead` 两个键。
4. mock 里的游戏行为是按 NOTES 和代码推测建的，包括扣血、状态标志、刀上碰撞时序、蓄力和肩撞的时间线。所以防御部分的场景只证明「同样的模拟输入下，合并版和 v1.4.2 的副作用一致」；游戏里的实际效果要靠第 3 步实测。

### 8. 审查修订（2026-10-12）

两份审查：运行时等价 5 条、测试与文档 9 条（1 条 major，是测试强度；其余 minor；没有 critical）。14 条全部成立，没有驳回。有 3 处没照审查的原话做，理由写在表里（运行时 2、测试 2 的 (2,24)、测试 7）。**放刀部分（§6）一行没改**；脚本只改了 §3 配置、§5 防御里的两个函数、§9 菜单。

#### 8.1 逐条处理

| # | 发现 | 处理 |
|---|---|---|
| 运行时 1 | 快照读到一半抛错（`rok = false`）时防御帧逻辑整帧跳过：快照比 v1.4.2 多读武器、动作控制器，这几项出错时，关无限蓄力后的还原、锁血补满都要拖到故障结束 | 修。`guard_frame` 在 `rok` 为 false 时照 v1.4.2 自己再读，只读这一帧用得到的、顺序同 v1.4.2；自己读也抛错时由 `guard_tick` 清肩撞请求（1.3 表已改）。场景 `guard_read_fault`、`guard_tackle_read_fault` |
| 运行时 2 | `AutoGuardGS.json` 读失败时当成「两个键都没有」再迁一次，并在加载时写回，拿默认值盖掉用户的防御设置 | 修，比审查的最小修法多做一步。只做「读出了表才在加载时写回」的话，覆盖只是推迟到下一次存配置：审查自己的补丁副本在 mock 里跑，场景结束时的存配置照样写出了默认值（guard_type=1、没有 guard_angle、锁血关……）；REF 存配置的时机推测是关菜单和退出游戏。所以把审查说的「可选的更稳做法」也做了：读盘抛错的那次加载一律不写（含存配置），菜单顶上红字说明（3.3、3.4、3.5 第 11~12 条）。场景 `merge_cfg_read_throw`（两组） |
| 运行时 3 | 菜单分块出错后永久降级到 Reset；`gs_action_param` 对 `get_Catalog()` 不判空 | 修，两处都做：判空（Catalog 为 nil 时走「等待读取角色数据」）；分块出错后 2 s 重试（5.3）。判空也改了 Catalog 为 nil 时受击钩子和无限蓄力的行为（这一下不改角度、照常判断防御；这一帧不改 `_OverheatTime`；v1.4.2 是整个钩子 / 帧抛错），只在这种故障下和 v1.4.2 不同、更可用。场景 `merge_menu_catalog_nil`、`merge_menu`（guard_fault 一组加「2 s 后恢复」） |
| 运行时 4 | 10 处改动测试抓不到 | 补场景，每处至少一个，变异全部抓住（8.3）：P60 `v16_emid_throw`、P47 `v16_intermittent_err`、P55 `v16_lose_res`、P31 `v16_rehold_res`、P49 `v16_weapon_switch`、P03 `v16_negative_window`、D02 `guard_double_hit`、D01 `guard_angle_close`、D04 `guard_tackle_timeout`、C01 `merge_cfg_only_auto_parry`。mock 补了两样：神谕认 get_EmID 抛错（这条预告不登记）；场景可以声明提前结算 RES 的时段（`expect.res_forced`，主角消失、CREDIT 内又放一刀时 dt 按结算那一刻核对） |
| 运行时 5 | `check.sh` 引用记账的正则漏 `r.release(r)`、`r["release"]`、`r : release()` | 修正则；新增 `tools/mock/check_selftest.sh`（15 条：该拦的 9 种写法、不该误判的 4 种、字形 2 条）。新正则对合并版、APCal 1.1 0 误报，归档 rc1 里的 `pcall(obj.release, obj)` 照样拦 |
| 测试 1 | 逐刀等价管不住 5 处会改变放不放刀的边界（major） | 补 `v16_horizon92`、`v16_long_warning`、`v16_cand_w65`、`v16_emid_throw`，5 个变异都抓住；2.7 的「最终保证」改成「只在场景覆盖到的路径上成立」，列出已知没覆盖的 |
| 测试 2 | entered=0 的路径从没走到 | 补 `v16_entered0`（请求一直被拒）。审查另提的「请求后游戏切进 (2,24)」没做：mock 把进 (2,23)、(2,24) 都当一次尝试，参照组的断言会把 v1.6 正确写出的 entered=0 判错，要先改断言；列进 2.7 的已知缺口 |
| 测试 3 | 放刀自停后，帧开头驱动的防御没测 | 补 `merge_isolation_parry_frame`：肩撞请求、无限蓄力改写与还原、锁血补满三项一起，和 v1.4.2 单独跑比 |
| 测试 4 | 三条规格没有场景约束 | 补 `v16_shell_order`（弹体最后读）、`merge_cfg_lead_clamp`（读 `AutoGuardGS.json` 时也经 `clamp_lead`）。「读主角抛错时清肩撞请求」在运行时 1 修过之后改由 `guard_tick` 做，`guard_tackle_read_fault` 抓的是「guard_tick 出错不清」 |
| 测试 5 | README「读不到速度时这一次不放」和代码不符 | 改：刚出招时读不到这一招不放，中途读不到沿用上一帧 |
| 测试 6 | 唯一实测的试打条件没写 | README、NOTES、9.1、V16 状态节都补上（APCal HDR 的 `cfg_guard`，实测）；正式验收时这些测试开关开不开，写成待用户定（9.1） |
| 测试 7 | 分析脚本 D16 的 sidmis 项在合并版上判「通过」 | 改：合并版写「—（合并版不记…）」、判需复核，自检加断言（仍 159 项）。没照审查说的标「样本不足」：数据质量项本来只判需复核（探针版本、探针 RED、sidmis > 0 都是），样本够不够另有一项；标样本不足会在以后补上 PERF 解析后把「数据质量没数据」说成「样本不够」 |
| 测试 8 | mock 防御那一半的动作模型和 APCal ACT 实测不符 | 便宜的改对了：防御反应 (1,146) Tech、(1,144) Middle，松手的蓄力斩 (2,0)/(2,1)/(2,12)，类名；按时间升级的蓄力链没改（场景靠它进 (2,7)/(2,11)），`game_sim.lua` 头注释逐条写明和实测不符、只作占位，附实测次数（自己从两份日志复核过）；NOTES 的动作表补上实测编号 |
| 测试 9 | README 安装第 4 步的说法会让人误判（合并版里本来就有「自动放刀（实验）」勾选框） | 改成「顶层还另有一个单独的『自动放刀（实验）』树节点」 |

审查里一条「观察，不算问题」本轮没动：抓取名、黑名单名读不到时，v1.6 不管开关都写一行 DBG，合并版只进 HDR 的 `enum_skip`，调试日志关着时不留痕（2.1 定的取舍）。要不要「缺了枚举名就在加载时写 HDR」，由用户定。

#### 8.2 改了什么

| 文件 | 改动 |
|---|---|
| `src/reframework/autorun/AutoGuardGS.lua` | 运行时 1~3（+36 −11 行）。1439 行（代码 1131、注释 212、空行 96），md5 `3b92dd1ca7869e62a1a8592f7befb93a` |
| `tools/mock/scenarios.lua` | 21 个新场景（11 个逐刀等价、10 个只在合并模式跑）；`merge_menu` 加期望；头注释补 `res_forced` |
| `tools/mock/run.lua` | 配置模型（读盘抛错不写；`AutoGuardGS.json` 读不出表时加载时不写）、`expect.res_forced`、头注释的场景数 |
| `tools/mock/game_sim.lua` | 神谕认 get_EmID 抛错；防御反应、蓄力斩的编号和类名按实测；头注释写明占位 |
| `tools/mock/check_selftest.sh` | 新增 |
| `tools/check.sh` | 引用记账的正则（`REF_BAD_RE`） |
| `tools/apcal_analyze.py` | D16 的 sidmis 项；自检断言；1.5 的修订说明（报告头那一行多了 sidmis 一句） |
| `README.md`、`docs/NOTES.md`、本文、`docs/autoparry/V16.md`（只改状态节） | 见 8.1 |

#### 8.3 验证（在定稿上重跑）

mock 的输出写在临时目录（`--out`）。

| 命令 | 结果 |
|---|---|
| `bash tools/check.sh` | 13 个文件全过 |
| `bash tools/mock/check_selftest.sh` | 15/15 |
| `lua tools/mock/run.lua` | 144 个场景 0 失败（约 60 s） |
| `lua tools/mock/run.lua --smoke` | 23 个 0 失败 |
| `lua tools/mock/run.lua --merged` | 183 个场景 0 失败（约 4.3 min） |
| | **132 个 v16 场景，B、C 两组对 A0 都是 0 差异** |
| | 39 个只在合并模式跑的场景 0 失败；两个合并版负对照各 DEAD_OBJECT 1 次（预期） |
| `--merged --gc-every-frame`：8 个引用场景，加 `v16_lose_res`、`v16_rehold_res`、`v16_weapon_switch`、`v16_emid_throw` 和两个负对照 | 14 个 0 失败，12 个等价比较 0 差异 |
| `python tools/apcal_analyze.py --selftest` | 159/159 |
| 第 1 轮回归 | 基线 316 行按顺序全在；新报告 423 行，内部错误 0 |
| 2a、2b、2c、trialB0（同第 3 小节的参数） | 和 1.4 的输出比，都只多报告头 1 行（1.5 的修订说明），一行没少；内部错误 0 |
| `python tools/mock/e2e_analyze.py <out> --sub merged_on` | 132 个场景（v1.6 session 132）：FIRE 一致性 166 行全部一致；影子对真 FIRE 158 刀；影子不触发 7 刀逐条有原因（比集成时多的 2 刀是 `v16_lose_res` 的，这个场景不载探针）；问题 0 |
| 不带 `--sub`（A0） | 144 个场景（v1.6 session 134），同样的数，问题 0 |
| `bash tools/mock/deploy_selftest.sh` | 6 组全过 |
| `bash tools/deploy.sh --dry-run`（真实游戏目录，只读） | 挪走 `AutoParryGS.lua`、复制 `AutoGuardGS.lua`；前后比对 autorun / autorun_disabled 的目录列表、4 个脚本和两个配置文件的 md5，什么都没改 |
| 修复前的合并版（md5 `afcf39a9…`）跑 5 个修复场景 | 4 个失败（`guard_read_fault`、`merge_cfg_read_throw`、`merge_menu_catalog_nil`、`merge_menu`）：场景确实抓得住原来的缺陷。`guard_tackle_read_fault` 修复前也通过（修复前同样清掉请求），它守的是修复之后的路径 |

#### 8.4 变异确认

改坏的副本只放在临时目录，用仓库的 `run.lua --merged-path` 跑对应场景（通过就算漏掉）。27 个全部抓住：

- 撤回这次的修法（7 个）：防御段快照抛错时直接跳过（`guard_read_fault`）、`guard_tick` 出错不清肩撞请求（`guard_tackle_read_fault`）、读不出表也在加载时写回（`merge_cfg_read_throw` 的 no_guard_file 组）、读盘抛错那次照常存配置（`merge_cfg_read_throw` 的 read_throw 组）、`get_Catalog()` 不判空（`merge_menu_catalog_nil`）、菜单分块出错后永久降级（`merge_menu`）、`check.sh` 换回旧正则（`check_selftest.sh` 5 条失败）。
- 审查报告里原来全套场景抓不住的（19 个，6.7 表末尾）：P60、P47、P55、P31、P49、P03、D02、D01、D04、C01、M11、M11b、M18、M12b、M43、M44、M40、N47、N55。
- 分析脚本：合并版 sidmis 判回「通过」 → `--selftest` 158/159。

（第 1、2 条加起来 25 个改坏的 `AutoGuardGS.lua`，另 1 个 `check.sh`、1 个分析脚本。）

#### 8.5 豁免表：仍为空

132 个场景全部 0 差异。

#### 8.6 行数

1439 行，比集成时多 25 行，都是这次三处修法的代码和「为什么」的注释；仍超出目标 1250，原因同第 6 小节第 5 条。

#### 8.7 部署

步骤同第 7 小节，没有变化。部署后多核对一条：菜单顶上没有红字「读不出配置文件 AutoGuardGS.json」（有的话说明这次读配置抛错，按红字 Reset Scripts 重读）。

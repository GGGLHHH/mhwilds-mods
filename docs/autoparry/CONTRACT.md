# 自动放刀第 1 轮：实现约定（CONTRACT）

本文是 4 个部件共同遵守的接口约定。设计依据和全部推理见同目录的 `PLAN.md`（定稿方案）；两者冲突时以本文为准，本文没写到的细节按 `PLAN.md` 实现。

| 部件 | 文件 | 日志标签 | 说明 |
|---|---|---|---|
| 放刀模块 rc | `src/reframework/autorun/AutoParryGS.lua` | `[AutoParryGS]` | 正式规则 + 第 1 轮专用的 L 轮换和机关扫描。**会改游戏**（只调 changeActionRequest） |
| 测量探针 | `probes/AutoParryCalib.lua` | `[APCal]` | 只记录，不改游戏 |
| 模拟测试 | `tools/mock/mock_ref.lua`、`tools/mock/scenarios.lua`、`tools/mock/run.lua` | — | 不开游戏，用假的 REF API 逐帧驱动 rc 和探针 |
| 离线分析 | `tools/apcal_analyze.py` | — | 读 JSON（日志兜底），按预注册规则分类、定参、出报告 |

`probes/AutoParryPredictProbe.lua` 已作废（第 119 行用 `%d` 格式化浮点），只在头注释标明作废，不再部署。

---

## 1. 运行约束（游戏内两个脚本都要遵守）

- REFramework Lua 5.4。`string.format("%d", 19.5)` 会抛错：**凡是可能是浮点的值一律用 `%.1f`/`%.2f`/`%.3f`/`%.4f`**；整数也建议 `math.tointeger` 后再 `%d`，或统一用 `%s` + `tostring`。所有格式化走 `safe_fmt`（`pcall(string.format, ...)`，失败输出 `FMT_ERR <fmt>` 并计错误）。
- `tools/check.sh` 只允许这些全局名：`sdk re imgui log json ValueType draw fs pairs ipairs pcall tostring tonumber string math table type error select next print os`。需要其他 **Lua 标准库** 全局（如 `setmetatable`、`assert`、`rawget`）时，可以在 `tools/check.sh` 的 `ALLOWED` 里追加，不许追加非标准名。不要用 `_G`、`require`、`dofile`。
- 改动作只能在 `re.on_pre_application_entry("UpdateBehavior", fn)` 里用 `hunter:call("changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)", 0, id, false)`（`id` 用 `ValueType.new(sdk.find_type_definition("ace.ACTION_ID"))` 设 `_Category`/`_Index`）。**禁止** `changeActionImmediate`、伪造/重放 HitInfo、`notifyHitProc`、写任何游戏字段。探针完全不改游戏。
- **禁止钩高频函数**：`cHunterWeaponHandlingBase.onParryHitPreProcess`（每秒 6~18 万次）。允许的钩子见第 4、5 节，都是每秒几十次以内（`ColliderSwitcher.activateAttack` 频率未知，必须带自停守卫）。
- 每个钩子、每个帧回调都用 `pcall` 包住；出错按第 3.4 节分级，不许静默吞错。
- 跨帧持有的托管对象用 `obj:add_ref()`，丢弃时 `pcall(obj.release, obj)`；主角为 nil、主角地址变化、`re.on_script_reset`、关开关时全部释放。
- 中文注释写「为什么」并标明哪些是实测结论（出处写日志时间或 PLAN.md 条目）；菜单文字用中文，控件标签带 `##英文ID`；避开 `°`、全角空格。
- 性能：每帧 Lua 平均耗时目标 ≤0.3 ms；日志平均 ≤5 行/秒（SERIES 这类高频数据只进 JSON，不打日志）。

### 1.1 已实测可用的 API 写法（照抄）

参考现有代码：`src/reframework/autorun/AutoGuardGS.lua`（v1.4.1）、`git show feat/auto-offset-slash:src/reframework/autorun/AutoGuardGS.lua`（v1.3，预告消息钩子、粘住估算）、scratchpad 里的 `AutoGuardParryCall_r12.lua` 和 `agpcall_r13_21.diff`（抵消流程钩子、怪物模块路径、特效钩子写法）。

| 用途 | 写法 |
|---|---|
| 主角 | `sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer"):call("get_Character")` |
| 大剑 | `hunter:call("get_WeaponType") == 0` |
| 当前动作 | `local ctrl = hunter:call("get_BaseActionController")`；`ctrl:call("get_CurrentActionID")` 的 `_Category`/`_Index`；`ctrl:call("get_CurrentAction"):get_type_definition():get_full_name()` |
| 状态标志 | `local flags = hunter:call("get_HunterStatus"):get_field("_HunterStatusFlag")`；`flags:call("check(System.UInt32)", v)`，`v` 取 `app.HunterDef.STATUS_FLAG` 静态字段 `get_data(nil)`（见 v1.4.1 的 `any_flag`） |
| 预告消息 | 钩 `app.cMasterPlayerControllerEntity.receiveGameMessage(ace.cGameMessage)`，`msg = sdk.to_managed_object(args[3])`，类型名 `app.game_message.cMsgEmAttackAreaResult`，`r = msg:call("get_AttackAreaResult")` |
| 预告字段 | `r:call("get_TargetCharacter")`、`get_ResultType`、`get_IsAttackFinished`、`get_KeepActionID`（`_Category`/`_Index`）、`get_EmID`、`get_EmSystemIndex`、`getClosestDetectedData`、`get_DetectedDataList`；条目 `d:call("get_ResultType")`、`get_HitStartRemainFrame`、`get_HitEndRemainFrame`（**返回 System.Single**） |
| 主角受击 | 钩 `app.HunterCharacter.evHit_DamagePreProcess(app.HitInfo)`，`args[2]`=猎人，`args[3]`=HitInfo；`info:call("get_AttackOwner")`、`get_DamageObj`、`get_CollisionLayer`、`get_AttackData`；post 里 `sdk.to_int64(retval) & 0xFFFFFFFF` 是 `app.Hit.RESULT` |
| 敌方判定 | `go:call("getComponent(System.Type)", sdk.typeof("app.EnemyCharacter"))` 非 nil |
| 抵消事件 | 钩 `app.cHunterWeaponHandlingBase.onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3)` 和 `onParrySuccess(app.HunterDef.PARRY_STATE)`；用 `hunter:call("get_WeaponHandling"):get_address()` 过滤主角；状态 `sdk.to_int64(args[3]) & 0xFFFFFFFF` |
| 怪物被打 | 钩 `app.EnemyCharacter.evHit_DamagePreProcess(app.HitInfo)`，攻击者地址等于主角 GameObject 地址才记 |
| 怪物模块 | `enemy:get_field("_Context"):get_field("_Em")`，其 `:get_field("Hit")`（cEmModuleHit）；`:call("get_EmID")` |
| 怪物动作 | `enemy:call("getCurrentAction()"):get_type_definition():get_full_name()` |
| 伤害结算 | 钩 `app.HunterCharacter.evHit_Damage(app.HitInfo)`，post 里读 `hunter:call("get_DamageInfo")` 的 `_TotalDamage` |
| 枚举表 | 遍历 `sdk.find_type_definition(枚举):get_fields()` 里 `is_static()` 的字段取 `get_data(nil)` |
| 配置 | `json.load_file("X.json")` / `json.dump_file("X.json", tbl)`（读写 `reframework/data/`） |

### 1.2 TDB 里存在、但 Lua 运行时没用过的接口（必须 pcall + 失败降级）

`List.get_Item(Int32)`、`get_Count`；`DetectedData` 的 `get_ShellIndex`/`get_RequestSetID`（Nullable：读 `_HasValue`/`_Value` 字段，或直接看返回是否 nil）、`get_AttackParam`、`get_Obb`；`cAttackParamEm` 字段 `_GuardType`、`_DamageType`、`_IsParryBreak`、`_IsParryFix`、`_IsParryStockOnly`、`_IsTechGuardBreak`、`_IsBlockEnable`、`_UserData`；`_Context._Em.Target`（`cEmModuleTarget`）的 `getTarget(System.Boolean, app.cEmModuleTarget.TARGET_ORDER)`；`_Context:call("get_IsMaster")`；`app.EnemyManager.findEnemy_SystemIndex(System.Int32)`；`calcMotionSpeedTotal(System.Boolean)`；`act:get_field("_RawTotalElapsedSecond")`（备选 `act:call("get_RawTotalElapsedSecond")`）、`act:call("get_CharaElapsedSecond")`；`hunter:call("checkHunterContinueFlag(app.HunterDef.CONTINUE_FLAG)", v)`；`_HunterMotionSupporter._BaseBasicMotionSeq` 的 `_ParryImmdiate` 等；`HunterCharacter.evHit_ShellDamagePreProcess(app.HitInfo)` 与 `info:call("getActualAttackOwner")`；`hunter:call("get_AttackAreaResult")._AttackAreaResultList`；`via.motion.TreeLayer` 的 `get_Frame`/`get_Speed`；`get_Transform():call("get_Position")`/`get_AxisZ`；`draw.text(text, x, y, color)`。

**规则**：这些读取全部包 pcall；第一次失败就关闭所属模块（黄），不影响核心测量；rc 的条目逐条读取失败时退回 `getClosestDetectedData()`（记 `src=FB`）。

---

## 2. 公共记录机制 `emit`

两个脚本各自实现同名机制（不共享状态，REF 下各脚本互不可见）：

```
emit(kind, fields, opts)
  fields: 有序字段表 { {"t", 12.3456}, {"em", "em20#3"}, ... }（或 kind 专属的序列化函数）
  opts.log  默认 true：写一行 log.info
  opts.json 默认 true：追加进内存缓冲，择机写 JSON
```

- **日志行格式**：`[TAG] KIND k1=v1 k2=v2 ...`。值不能含空格（空格换成 `_`）；布尔写 `1`/`0`；nil 写 `-`；浮点按字段约定的小数位。
- **JSON 记录**：`{ "k": "KIND", "t": ..., 字段... }`，只用基本类型；地址写成十六进制字符串（`string.format("%X", addr)`，addr 先 `math.tointeger`）；坐标拆成 `x/y/z`；NaN、inf 换成 null（`v ~= v` 或 `math.abs(v) == math.huge`）。
- **时间**：`t` = 事件发生时的 `os.clock()`（同一进程两脚本共用，离线按 t 关联），格式 `%.4f`。`f` = 本脚本的帧计数（每次 pre-UpdateBehavior 加 1）。
- **JSON 文件**：`reframework/data/<前缀>_<session>_<seq>.json`，前缀 `APCal` 或 `AutoParryGS`；`session = os.time()`（加载时取一次）；`seq` 从 1 递增，上限 300。内容：
  ```json
  { "kind": "APCal", "ver": "...", "session": 1760000000, "seq": 3, "why": "idle", "records": [ {...}, ... ] }
  ```
  `why` = 这份是怎么写出的（`idle` / `button` / `reset`，探针另有 `valve` / `hard` / `stop`）：离线据最后一份的 `why` 提示「有没有正常收尾」（不是按钮/重置写的 → 可能崩溃或忘了点「写出数据」，只提示、不算崩溃）。
  每个文件只含上次写出之后新增的记录。写出时机：① 空闲帧（没有未结束回合，主角不在 (2,21)~(2,29)，距上次写出 ≥60 s）；② 菜单「写出数据」按钮；③ `re.on_script_reset`。`json.dump_file` 返回值为假记一次核心错误。
  探针另有安全阀：缓冲 ≥6 万条时不等空闲帧，但仍要求没有 PT、不在 (2,23)~(2,29)、没有未结束回合（蓄力中可以写）；≥15 万条才无条件写（几 MB 的 JSON 可能卡 0.1~0.3 s，不能压在判定时机上）。
- 离线分析**优先读 JSON**；JSON 缺失时从 `re2_framework_log.txt` 解析同名记录（字段相同，只是没有 SERIES 等只进 JSON 的记录）。

### 2.1 错误分级（两个脚本都要）

- 每个模块独立 pcall。
- **核心模块**（探针：HDR、CLOCK、MSG、SERIES、ACT、PT、CT、DMG、PH/PS、EMHIT、EP、JSON；rc：消息、帧逻辑、放刀、JSON）：10 s 内出错 ≥3 次 → **红**，HUD 显示「停下发日志」。rc 帧逻辑连续 30 帧出错 → rc 自停（不再放刀）并标红。
- **可选模块**：第一次出错 → 停用该模块、标**黄**，测量继续。
- 每条错误都写 `ERR mod=<模块> level=red|yellow msg=<错误文本>` 进 JSON（每个脚本上限 500 条）；日志只写前 20 条，**排队**按 1 行/秒补写（不许因为限频直接丢弃，Reset 时把排队的一次写完）。
- **进入红状态**的那一刻两个脚本各写一行 `RED t=<时刻> mod=<模块> why=<3in10s|self_stop|init|selftest1|selftest2|hook|load>`（总写日志、总进 JSON，只写一次；rc 自停另写一行 why=self_stop）。离线**只把 RED 算「关键错误」**（C9(d)、C10），和 HUD 标红、用户按协议停下的口径一致；单条 level=red 的 ERR 单列为「核心模块错误」，不触发补测。
- **取主角 → 动作控制器 → 动作 ID 的调用抛错**（不是返回 nil，例如切场景时对象正在销毁）：1.5 s 内按「这一帧不存在」处理（rc 不求值、不放刀、streak 不动；探针沿用上一帧的动作状态），间隔 <0.5 s 的零星失败算同一段；持续 ≥1.5 s 才按核心错误处理（rc 帧逻辑出错、探针 ACT）。rc 进出这种状态各写一行 DBG（ev=read_fail / read_back），计数进 STAT 的 readfail；探针计数进 PERF 的 actfail。
- 探针的核心模块连续 30 帧每帧出错 → 暂停该模块 1 s（红照旧）：这版 REF 每截住一次访问冲突要写 60 多行寄存器转储，每帧都撞会刷屏卡帧。

---

## 3. 放刀模块 rc（AutoParryGS.lua）

### 3.1 配置 `AutoParryGS.json`

`{ "auto_parry": true, "parry_lead": 28, "lead_rotation": true, "scan": false, "debug_log": true }`。`load_config` 做类型校验，`parry_lead` 夹到 20~45。

### 3.2 常量

`LEAD_MIN=18`、`LONG_WINDOW=60`、`VETO_HORIZON=90`、`CREDIT=1.3`（秒）、`TRACK_MAX=32`、`TRACK_STALE=8.0`（秒）、`ROTATION={20,24,28,32,36}`（每 5 次一组，组内用 `math.random` 乱序；`math.randomseed(session)`；只有真的进入 (2,23) 才前进一档）。`RT_DANGER`、`DAMAGE_TYPE` 的 `EAR/WIND/QUAKE` 从枚举读。

### 3.3 规则（每帧 pre-UpdateBehavior）

完全按 PLAN.md「DECISION RULE · A」：前提 P1~P3 → 跟踪集 R（只认 `TargetCharacter` 地址 == 主角地址）→ 否决 V（存在 DANGER 条目 `he-hs > LONG_WINDOW` 且 `hs ≤ VETO_HORIZON` 且 `he ≥ 0`）→ 候选 C（DANGER、`hs ≥ LEAD_MIN`、`0 ≤ he-hs ≤ LONG_WINDOW`、ShellIndex 无值、DamageType ∉ {EAR,WIND,QUAKE}；读取失败按通过并计数 `failopen`）→ `Q* = min hs` → `Q* ≤ L` 就请求 (2,23)。streak 合并连续请求帧；不设超时。逐条读取出错且整体 DANGER 时退回 closest（`src=FB`）。

预告跟踪与释放按 PLAN.md 参数表「预告跟踪与释放」：消息钩子 + add_ref，同一对象重发刷新 `t_msg`；IsAttackFinished / 全部条目 `he < -30` 且距 `t_msg ≥ 1 s` / 距 `t_msg ≥ 8 s` / 主角变化 / 关开关 / reset 时 release；最多 32 条，满了丢最旧的。两个细节（探针、mock 神谕同一口径）：
- 「全部条目 he<−30」**只对非空条目列表成立**：未结束、暂时没有条目的结果继续持有到 8 s（之后不重发消息就冒出来的 DANGER 条目也要看得到）；
- 「最旧的」= **`t_msg` 最旧**（最久没收到消息的那条），不是登记最早的。

### 3.4 rc 记录种类（`[AutoParryGS]`）

| KIND | 字段（顺序） | 何时 |
|---|---|---|
| `HDR` | `ver session auto_parry lead rotation scan L_min W_long H_veto credit` | 加载时 |
| `FIRE` | `id t L R0 he0 src ent res em keep from` | streak 第一帧（`id` 递增；`L` 是本次轮换值；`R0`=Q* `%.2f`；`ent`/`res` 条目和结果地址；`em`=`em<EmID>#<SystemIndex>`；`keep`=`(c,i)`；`from`=`(2,21)` 或 `(2,22)`） |
| `FIRE_END` | `id t R1 n entered` | streak 结束（`entered`=是否进入 (2,23)；`R1`=进入那一帧的 Q*；`n`=请求帧数） |
| `VETO` | `t hs he res ent em` | 每个否决 streak 一行 |
| `RES` | `id t outcome dt` | `outcome`=`CATCH25/26/27` 或 `NOCATCH`（CREDIT 秒内是否进入 (2,25..27)）；`dt`=距 FIRE 秒数 |
| `SCAN` | `id t phase X t0 Dc t_req status reason` | 扫描每个样本一行；`phase`=`learn/fire/done`；`status`=`OK/VOID`；done 的 `reason` 另有 `lost`（扫描中主角对象没了/换了） |
| `STAT` | `fires catches vetoes fb failopen errors`，之后追加 `red yellow lua_ms_avg lua_ms_max hook_ms_ps readfail` | 每 60 s 一行；点「写出数据」和 Reset 时先补写一行。追加项：核心/可选错误数、本窗口帧回调每帧耗时、钩子体每秒耗时（C9(d) 估开销用）、读主角抛错跳过的帧 |
| `ERR` | `mod level msg` | 见 2.1 |
| `RED` | `t mod why` | 进入红状态时一行，见 2.1 |

### 3.5 机关扫描（rc 测试模式，默认关）

按 PLAN.md 参数表「机关扫描」和 probe_spec P20：认机关（第一次敌方接触的攻击者，且它当前动作的完整类名以 `app.Em0165_00Action.` 开头 —— 只有训练机关有 cSmallAttack；别的怪先打到主角不认）→ 前 2 个有效周期只学 `D_c`（首次接触 − `cSmallAttack` 首帧）→ 之后按 `t_req = t0 + D_c − X − δ` 到点请求放刀（0.05 s 内每帧重试；主角不在蓄力中就把 X 放回队列）→ 作废条件 4 条 → 粗网格 `{0.24,0.28,0.32,0.36,0.40,0.50,0.60,0.70,0.80,0.90,1.00}` 乱序各 1 次，再在交界两侧细化（步长 0.02，每条边界最多 6 点），交界点各重复 1 次；有效样本满 24 完成，上限 36 个或 10 分钟，每个 X 最多尝试 3 次。扫描模式下 rc 自己钩一次 `HunterCharacter.evHit_DamagePreProcess` 认机关、拿接触时刻。完成后自动关扫描；扫描中主角对象换了（切场景：重新出现的主角地址和上次见到的不同）也结束扫描（`SCAN phase=done reason=lost`）、自动关扫描；主角只是短暂为 nil 则只放掉机关对象，下次被打到按类名重新认机关。

### 3.6 菜单与 HUD

菜单 `自动放刀 rc##AutoParryGS`：启用、提前量滑块（轮换期间只显示不可调）、轮换开关、扫描开关、统计（放刀/接住/否决/兜底/fail-open/错误）、调试日志、清零、写出数据。
HUD（`re.on_frame` + `draw.text`，失败退回 `imgui.begin_window`，再失败只在菜单里显示）：一行 `自动放刀 rc L=<当前L> 放刀 n 接住 k 否决 v` + 扫描状态（等待机关出招 / 按住 / 重新按住 / 扫描 n/24 / 扫描完成）。红色错误时整行换成「自动放刀 rc 出错，停下发日志」。

---

## 4. 测量探针（AutoParryCalib.lua）

按 PLAN.md 的 probe_spec P01~P18、P21、P22 实现（P19、P20 在 rc 里，P23 是分析脚本）。纯计算部分（epoch 切分、在线结局分类、角度 θ）写成不依赖 sdk 的局部函数，方便 mock 测。

### 4.1 模块与级别

| 模块 | 级别 | PLAN 条目 |
|---|---|---|
| HDR 自检与表头 | 核心 | P01 |
| CLOCK 帧时钟、HITCH/GAP、PERF | 核心 | P02 |
| MSG 预告消息与跟踪 | 核心 | P04 |
| SERIES 条目时间序列 + TYP | 核心 | P05 |
| ENT 条目静态属性 + 自检2 | 可选 | P06 |
| ACT/ARM 主角动作、计时、霸体 | 核心 | P07 |
| PT 放刀尝试 | 核心 | P08 |
| CT 接触（含弹体路径；弹体路径本身可选） | 核心 | P09 |
| DMG HP 损失 | 核心 | P10 |
| PH/PS 核心；PMSG/EMPARRY 可选 | 混合 | P11 |
| EMHIT 上捞斩砍中怪物 | 核心 | P12 |
| EMSTATE/EMINFO 怪物状态 | 可选 | P13 |
| ATK 攻击判定激活（带频率守卫） | 可选 | P14 |
| SIG 窗口候选信号与动画时钟 | 可选 | P15 |
| HOLD 预告持有者对照 | 可选 | P16 |
| POSE 位姿与来向 | 可选 | P17 |
| EP 回合 | 核心 | P18 |
| JSON 持久化 | 核心 | P21 |
| HUD/菜单 | HUD 可选、菜单核心 | P22 |

### 4.2 探针记录种类（`[APCal]`；★ = 只进 JSON 不打日志）

| KIND | 字段（顺序） |
|---|---|
| `HDR` | `ver session net guard_deg aim_deg overheat_parry cfg_guard cfg_parry enums`（`cfg_*` 是两个 mod 配置的 JSON 字符串去空格；`enums` 是关键枚举数值的紧凑串） |
| `SELFTEST` | `stage ok total failed`（`stage`=1 加载时 / 2 首次 DANGER；`failed`=失败项名，逗号分隔） |
| `HITCH` / `GAP` | `t f dt` |
| `PERF` | `t fps maxdt hooks lua_ms_avg lua_ms_max tracked red yellow`（`hooks`=各钩子每秒调用次数紧凑串）；之后追加 `hook_ms_ps`（钩子体每秒耗时）、`actfail`（读主角抛错、容忍期内跳过的帧）、`red_state` |
| `MSG` | `t f obj new tme em keep rt n mstart mend closest fin`；之后追加 `snd`（发送者 GameObject 名）、`snd_em`（发送者身上 EnemyCharacter 的地址：P23「攻击者相同」的首选键，和 CT 的 `atk_em` 直接比） |
| `TYP` | `t f obj ent type hs he`（类型变化、hs 回跳 >2 帧、条目增减时） |
| `SER`★ | `t f obj ent type hs he charge`（`charge`=主角是否在 (2,21)/(2,22)） |
| `ENT` | `obj ent idx closest shell reqset guard dmgtype dmglv filter vguard pbreak pfix pstock tgbreak block name` |
| `ACT` | `t f from to from_name to_name raw_prev raw_new chara_new` |
| `ARM` | `t f act sa ha nd raw` |
| `PT` | `id t_obs raw0 t_start from hold lv contacts_blade contacts_body ph ps hit_t hit_idx recoil emhit dmg online_class`（`online_class` 只给 HUD 用；正式分类在离线） |
| `CT` | `t f k atk atk_em dmgobj layer cls ps res act raw sa shell px py pz`（`cls`=`BLADE`/`BODY`/`OTHER`） |
| `DMG` | `t total react` |
| `PH` | `t state target raw chara delay` |
| `PS` | `t state` |
| `PMSG` | `t state` |
| `EMPARRY` | `t em ap` |
| `EMHIT` | `t raw chara dmgobj layer em` |
| `EMSTATE` | `t em act`（有未结束回合的怪，以及被上捞斩砍中后 1.5 s 内的怪：被打断那一招的回合常在同一帧结束） |
| `EMINFO` | `t em when tgt speed_t speed_f ts master x y z`（`when`=`DANGER`/`FIRE`/`CT`） |
| `ATK` | `t em a4 a5` |
| `SIG` | `t name val raw chara frame` |
| `ANIM`★ | `t raw frame speed motion` |
| `HOLD`★ | `t n addrs` |
| `POSE` | `t when px pz fx fz ex ez theta dist`，之后追加 `em`；`when=FIRE`（PT 首帧）对每只有未结束 DANGER 回合的怪各写一条，离线 g2/g4 只用同一只怪的 POSE |
| `EP` | `id obj epoch em keep reason n_msg first_type first_hs types rate_med rate_min rate_max stall maxdt charge_all atk_on t0 t1`，之后追加 `end hold pts snd snd_em` |
| `PROG` | `t phase swings scan_pt b_pt b_contact b_danger`（进度，每 30 s 或变化时） |
| `ERR` | `mod level msg` |
| `RED` | `t mod why`（进入红状态，见 2.1） |

`(c,i)` 动作写成 `2_23` 这种无逗号形式也可以，但全文统一。离线脚本以本表为准解析。

### 4.3 HUD 与菜单

屏幕角一行：`APCal 自检 OK 错误 r/y | <阶段>`；阶段文字：`空挥 n/3` → `B 段：放刀 n/45 接触 k/20 DANGER m/60`；首次 DANGER 后追加 `自检2 x/y`。「帧率降 x%」提示的 fps 基线在每次换场景后（主角对象变化、一帧超过 1 s）重新取前 10 s 的中位数（训练场和野外 fps 本来就差一倍，不能跨场景比；只是提示，不进判定）。菜单 `APCal 测量探针##APCal`：错误详情、进度、「写出数据」、「停止记录」开关；加载 90 分钟后自动停止记录。

---

## 5. 模拟测试（tools/mock）

- 运行方式：仓库根目录执行 `lua tools/mock/run.lua [场景名]`，不带参数跑全部场景；退出码 0 = 全部通过。输出写到 `tools/mock/out/<场景>/`（日志 `ref.log` + 两个脚本写出的 JSON）；`tools/mock/out/` 加进 `.gitignore`。
- `mock_ref.lua`：假的 `sdk`、`re`、`imgui`、`log`、`json`、`draw`、`ValueType`、`fs`，以及可控的 `os.clock`。每个游戏脚本用 `load(源码, 名字, "t", env)` 在**各自独立的环境表**里运行（模拟互不可见）。要能：返回 19.33 这样的浮点、nil、无值 Nullable、空 List；按设定抛异常；对象带地址且 `add_ref`/`release` 计数；`json.dump_file` 拒绝 NaN、inf、userdata、函数并返回 false；`sdk.hook` 登记钩子供场景调用；`re.*` 登记回调供逐帧驱动。
- `scenarios.lua` 至少覆盖：两条条目 hs 不同；中途降级；长窗口否决；remain=0；多个结果；机关空预告周期 + 扫描调度；手动放刀；空放；接住那一帧同时有身体接触；弹体条目；读取异常导致 FB 兜底；可选模块出错自停（黄）；核心模块连续出错（红）。
  审查第 1 轮后补：未结束的结果先是空列表、之后不发消息就冒出 DANGER（empty_then_danger）；Nullable 有值时直接返回数字（shell_num）；get_Item 返回 nil 而不抛错（fb_nil）；扫描中切场景（scan_swap）、扫描时真怪先打到主角（scan_realfirst）；读主角接口瞬时抛错 0.1 s（transient_throw）；条目对象被复用（entry_reuse）；同一帧连出两条错误（err_burst）；跟踪满了按 t_msg 淘汰（track_evict）；被打断后记下受击动作（whiff 的 emstate_after_interrupt）。场景可声明 `expect.red`（允许/要求的 RED 行），没声明的 RED 判失败。
- `run.lua` 逐帧驱动两个脚本，断言：日志里没有 `FMT_ERR`、没有意外的 `ERR`（场景声明预期的除外）；只在 `[L_min, L]` 区间的第一帧请求放刀；否决生效；探针 PT 结局互斥；写出的 JSON 能被 `json` 解析；`add_ref` 与 `release` 成对（场景结束 reset 后计数归零）；rc 只调用 `changeActionRequest` 这一个有副作用的方法，探针一个都不调。

## 6. 离线分析（tools/apcal_analyze.py）

- 用法：`python tools/apcal_analyze.py <数据目录> [--log <re2_framework_log.txt>] [--session N [N ...]] [--calib-session N [N ...]] [--crashed] [--out report.md]`。数据目录里找 `APCal_*.json` 和 `AutoParryGS_*.json`；默认取最新 session。
  - `--session` 给多个：每个 session 各自做时间关联（游戏重启后 os.clock 归零，时间轴不能直接合并），派生样本（放刀结局、残差、回合、漏报、扫描点）合在一起算 C1~C10，报告写明每个 session 的贡献。
  - `--calib-session`：只从这些 session 取定标量（扫描窗口、T_armor、δ），默认用全部 `--session`。C10 补测（只补真怪段、不重做扫描）用 `--session 新 --calib-session 旧`，或 `--session 旧 新` 合并。
  - `--crashed`：用户报告游戏崩溃过。
- 实现 PLAN.md「DECISION RULE」的 B 节（结局互斥分类）、C1~C10、D 节，以及 P23 的预注册匹配规则（攻击者相同；接触落在 `[t_hs0−0.35, t_he0+0.30]`；多个候选取 `|t−t_hs0|` 最小；报告未匹配数和有歧义数）。部署前定下的口径（第 1 轮审查后）：
  - **c_first**（B、C2、C9(a)、回合归因共用）按 PLAN 字面：`t_req` 之后**该攻击者**的首个接触，不经 P23；窗口到 `max(min(t_req+1.3, 这一刀离开 (2,23..29)), t_req+he/60+0.3)`，并在下一次放刀请求处截断。P23 只用于没放刀回合的接触归属；放过刀的回合 P23 窗口起点取「触发条目归零」和「本回合在 t_req 时最早归零的 DANGER 条目」中较早的那个。报告「放刀首个接触落在 P23 窗口外」的次数。
  - **CATCH/RECOIL** 只看 `min(t_req+1.3, 这一刀离开 (2,23..29), 下一次放刀请求)` 之前（手动放刀同理）。
  - **攻击者相同**：直接相同的键（发送者 EnemyCharacter 地址 = CT 的 atk_em、GameObject 名、SystemIndex）或学到的别名；接触侧 SystemIndex 在预告侧从没出现过（或自检2 报 sysidx 不一致）时降级，只按地址/名字和共现学习匹配，报告头报警。
  - **C3**：d̄ 只用「穿越 L 触发」的放刀（触发前一帧读数 > L）；晚触发的样本（DANGER 晚出现/晚蓄力/否决刚结束）在 L ≥ R0 时触发读数就是它自己的 R0。
  - **C9(d) fps 部分**：第 1 轮没有「mod 关着」的同场景基线，按 mod 开销占帧时间估：（探针每帧帧回调耗时 + rc 每帧帧回调耗时）× fps + 两个脚本钩子体每秒耗时，除以 1000 ms，各 PERF 周期的中位数 ≤5% 通过（不含 REF 钩子分发开销，报告注明）；fps 只按场景分段描述。**关键错误** = RED 记录数。**崩溃** = `--crashed` 或所选 session 日志范围内的未处理异常/崩溃转储行（排除 CrashHandler/CrashReport/crasher_fn 和被 REF 截住的 VMContext 访问冲突——后者单列警告）。
  - **漏报**只算 B 段（第一个 DANGER 回合之后）；「被长窗口规则否决」按影子回放的全局否决区间判断（跨怪）；Q 落进 [L_min, L] 时主角不在蓄力单列。
  - **C6、F_shadow** 第 1 轮按设计基本不可评估（rc 对所有合格回合都放刀），报告写明、维持默认；改用真放刀评估需改 PLAN 口径，由用户决定。
  - **离线 1**：扫描窗口在 wall/raw/chara/动画 Frame 四种时钟下各估一次；真怪核对、C2 残差、C9(a) 按「首个接触前有没有同一只怪的 EMHIT」分组报告（只描述，不改判定）。
- 输出 Markdown 报告：参数表；每个 L 的覆盖曲线；留一招式交叉验证；空放与漏报归因表；闸门评估（附评估过的候选数）；可行性结论（C9 逐项）；是否需要补测（C10）。
- 必须能在 mock 输出上跑通（样本不足时如实报告「样本不足」而不是崩溃）。

## 7. 完成标准（部署前）

1. `tools/check.sh` 全部通过（含新文件）。
2. `lua tools/mock/run.lua` 全部场景通过。
3. `python tools/apcal_analyze.py tools/mock/out/<场景>` 在每个场景上都能产出报告。
4. 用 MCP 只读 `get_type` 核对两个脚本里用到的全部类型名、方法签名、字段名（1.2 节的接口只能核对「存在」，运行时形态靠游戏内自检）。

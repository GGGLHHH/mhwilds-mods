# 研究笔记：《怪物猎人：荒野》内部结构

开发 AutoGuardGS（v1.5 起含自动放刀）时用 REFramework、re-engine-mcp 和探针（`probes/`）摸清的东西。

- 标注：**实测** = 由数据或日志直接得出（带样本量或出处）；**推测** = 由类型库、源码或机制推断，没有直接测到。没有标注的条目是开发时在游戏里直接验证过的。
- 自动放刀的数据、推导和规格在 `docs/autoparry/`：`SPEED.md`（怪物速度与放刀时机）、`V16.md`（放刀规则 v1.6）、`MERGE.md`（并入 AutoGuardGS v1.5）。这里只摘结论。
- 数据代号：第 1 轮、2a、2b、2c 是设计阶段的 4 段数据（怪 em19 缠蛙、em20、em23、em27）；A 阶段是 2026-10-11 在 5 只新怪上只记录、不放刀的机制检验；v1.6 试打是 2026-10-11 开着放刀的实测。
- 自动放刀从 AutoGuardGS v1.5 起写在 `AutoGuardGS.lua` 里（独立的 `AutoParryGS.lua` 已删，归档在 `tools/archive/`）；放刀记录的日志标签仍是 `[AutoParryGS]`。

## 角色与动作

- 主玩家：`app.PlayerManager:getMasterPlayer()` → `cPlayerManageInfo`
  - `:get_Character()` → `app.HunterCharacter`
  - `:get_Controller():get_ControllerEntity()` → `app.cMasterPlayerControllerEntity`（输入、行为表、游戏消息）
- 动作控制器：`HunterCharacter:get_BaseActionController()` → `ace.cActionController`
  - `ACTION_ID = { _Category, _Index }`，对应 `_ActionList[cat][idx]`
  - 大剑（Wp00）：分类 0 是通用动作，分类 1 是大剑基础动作，分类 2 是大剑攻击动作
- 武器类型 `get_WeaponType()`：大剑 = 0
- 动作属性 `isActionAttrCurrentAction(app.HunterDef.ACTION_ATTR)`：游戏给动作打的标签（DODGE、DAMAGE、ITEM_USE、WP_OFF……），所有武器通用，适合做过滤条件

### 大剑动作编号（部分）

| ID | 动作 |
|---|---|
| (1,14) | cIdle 拔刀待机 |
| (1,19)～(1,23) | cDodge 系列翻滚 |
| (1,141) / (1,142) | cGuard 防御 / cGuardEnd |
| (1,143)～(1,150) | cGuardReaction_* 防御反应：(1,143) Small、(1,144) Middle、(1,145) Large、(1,146) Tech（精确防御）、(1,147) TechMiddle、(1,148) Block（类名实测） |
| (2,0) / (2,1) / (2,12) | 纵斩 / 强纵斩 / 真蓄力斩（cSpiritVerticalSlash）：蓄力松手后出的就是它们 |
| (2,5) / (2,6) / (2,7) / (2,11) | 开始蓄力 / 蓄力 / 强蓄力 / 真蓄力（类名 cIdleToCharge / cCharge / cStrongCharge / cSpiritCharge） |
| (2,9) | cVerticalFly（不是蓄力斩） |
| (2,15) / (2,17) | 肩撞（类名都是 cTackle；一段蓄力出 15，强蓄力和真蓄力出 17） |
| (2,54) | cAttackToWalk |
| (2,21) | cIdleToParryCharge 抵消蓄力：从待机、移动、翻滚按出时进这里；按住一直停在这里，**不会**转进 (2,22) |
| (2,22) | cParryCharge 抵消蓄力：从纵斩、强纵斩、肩撞、真蓄力斩的派生、精确防御反应等**攻击之后接出**时直接进这里 |
| (2,23) / (2,24) | cParrySlash 抵消上捞斩 / cParrySlashForward 前进版 |
| (2,25) | cParrySlashHitS：**被弹开**（抵消状态 RECOIL），随即身体挨打，不算接住 |
| (2,26) / (2,27) | cParrySlashHitM / cParrySlashHitL：接住（27 时怪物进 cDamageParry） |
| (2,28) / (2,29) | cCloseMove / cCloseSlash（类名实测，含义没查） |

- 蓄力怎么升级（实测，APCal 的 ACT 记录，`tools/out/stageA_data/` 的日志副本加 10-11 的游戏日志）：按住不放不会从 (2,6) 升到 (2,7)（0 次）。松手出蓄力斩：(2,6)→(2,0) 255 次、(2,7)→(2,1) 194 次、(2,11)→(2,12) 148 次；(2,7) 是从 (2,0) 纵斩（84）、(2,54)（70）、(2,15) 肩撞（60）接出来的，(2,11) 从 (2,1)（74）、(2,42)（41）、(2,54)（25）、(2,17) 肩撞（18）。精确防御反应 (1,146) 之后多数进 (2,54)（62 次），偶尔直接进 (2,22)（2 次）
  - `tools/mock/game_sim.lua` 的普通蓄力按时间 (2,6)→(2,7)→(2,11) 升级是占位（头注释写明了），两个脚本都只按动作编号判断，不受影响
- (2,21) 和 (2,22)（实测，探针 APCal 的 ACT 记录）：2026-10-10 16:03～10-11 15:43 的游戏日志（副本在 `tools/out/stageA_data/`）进 (2,21) 162 次、进 (2,22) 32 次；10-11 17:01 起的游戏日志进 (2,21) 94 次、进 (2,22) 10 次；两份里 (2,21) → (2,22) 都是 0 次。
  - 旧笔记「按住时不会进入 (2,22)」对 (2,21) 本身成立，但 (2,22) 另有入口。**两个都能放刀**：v1.6 试打 7 刀里 3 刀是从 (2,22) 放出的（FIRE 的 `from=(2,22)`），第 1 轮也有。

## 关键规律：改状态 vs 改动作

- **改状态**（状态标志、参数）可以在受击结算中途做：在 `evHit_DamagePreProcess` 前置里改，在 `evHit_Damage` 后置里还原
- **改动作**必须在帧开头（`re.on_pre_application_entry("UpdateBehavior")`）调用 `HunterCharacter:changeActionRequest(LAYER=0, ACTION_ID, false)`，让动作控制器走正常的进入流程，被拒绝就每帧重试。自动肩撞、自动放刀都是这样请求动作的
  - `changeActionImmediate` 在结算中途硬切：动作对象换了，但动画和霸体没跟上，表现错乱 ✗
  - 从 MCP 的 HTTP 线程调用游戏方法会被拒（不在主线程）✗

## 防御

- 状态标志：`hunter:get_HunterStatus()._HunterStatusFlag`（`ace.cSafeContinueFlagGroup`，方法是 on/off/check(UInt32)），枚举是 `app.HunterDef.STATUS_FLAG`
  - `GUARD`：普通防御；`TECHNICAL_GUARD`：精确防御（单开它就会进 cGuardReaction_Tech）
  - `SUPER_ARMOR` / `HYPER_ARMOR`：霸体（蓄力从第一帧起就有 SUPER_ARMOR，肩撞会额外加 HYPER_ARMOR）
- **受击时判定为防御**：在 `evHit_DamagePreProcess` 前置里打开标志，游戏会按自己的规则（角度、体力、削伤）结算，零误触发
- 能不能举剑：`checkContainsActionInCurrentBTable(cGuard, 0, ACTION_CANCEL_INDEX.Invalid)`（在 controller entity 上调用）判断行为表里有没有通往防御的路，但**不看时机**（拔刀翻滚、倒地起身时也返回 true），所以要配合 ACTION_ATTR 黑名单
- 防御角度：`PlayerManager:get_Catalog():getWeaponActionParam(0)` → `Wp00ActionParam._GuardDegree` / `_AimGuardDegree`，都是**全角**（70 = 正前方左右各 35°），所有大剑共用
- 刀上的抵消碰撞也会走进受击钩子：抵消时怪物的攻击打中大剑（碰撞层 ATTACK_PARRY_GET），同样进 `evHit_DamagePreProcess`，而且在同一帧的抵消结算之前（实测，v1.4.1 开发时的日志）。所以 v1.4.1 起在抵消动作族 (2,21)～(2,29) 里不改写防御角度，免得共用的角度混进放刀的结果，或造成 mod 导致的「全向抵消」假象

## 输入

- 合并后的输入：`cPlayerCommandController._MergedVirtualInput`（键鼠走 `_VirtualInputPc`，手柄走 `_VirtualInput`，两者每帧都会被真实设备覆盖）
- 在 `mergeAndUpdateInput` 后置里改 `getKey(PAD.ATTACK_SP=2)`，等于虚拟按住大剑防御键，实测可以举剑并保持
- 但**蓄力中按这个键不会出肩撞**（连按 28 帧都没反应），所以肩撞改用 changeActionRequest

## 蓄力

- `Wp00ActionParam._ChargeParam*`（`cCharge`）：`_OverheatTime` 是蓄满后再按住多久会过热自动放出（普通、强、真蓄力 3 秒，抵消 2.5 秒）

## 怪物攻击

- 攻击判定激活：`app.ColliderSwitcher.activateAttack(Boolean, UInt32, UInt32, …)`（怪物只用这个重载；关闭判定会每帧调用）
  - 激活那一帧读到的判定框位置是**旧的**，要下一帧才会更新
  - 判定激活到命中约 0.14～0.17 秒；判定框以每秒 25～30 米的速度扑过来

### 攻击预告

- **怪物攻击预告**（本来给 NPC AI 用）：怪物每切一次动作，就给目标猎人发一条 `cMsgEmAttackAreaResult`
  - 在 `cMasterPlayerControllerEntity.receiveGameMessage` 里截取（这个钩子训练场/野外约 70~90 次/秒，集会大厅 0 次）。猎人身上的 `mcHunterAttackAreaResultHolder` 其实是激活的：第 1 轮里 93% 的 DANGER 回合，对象 ≥95% 的时间都在它的 `_AttackAreaResultList` 里（旧笔记说「未激活」是 MCP 显示 bug）
  - `AttackAreaResult`：TargetCharacter（**恒为接收者**，看不出怪物在打谁；要读怪物 `_Context._Em.Target:getTarget(false, FIRST)`）、ResultType（SAFE/CAUTION/DANGER）、KeepActionID、IsAttackFinished、EmID、EmSystemIndex、`get_DetectedDataList()`（每段攻击一条 DetectedData：自己的 ResultType、`HitStartRemainFrame`/`HitEndRemainFrame`（下面记作 hs / he，**System.Single**，单位 1/60 秒，倒数方式见下一节）、ShellIndex（Nullable）、AttackParam（cAttackParamEm）、Obb）
  - DANGER 只按身体胶囊（半径 0.3 m、高 1.5 m）判定。多段攻击要逐条看、取最早的一段，`getClosestDetectedData` 的选取规则不明
  - 预告数据是每只怪预烘焙的 `EnemyParamPack._AttackAreaParam`；**训练机关的表长度为 0**，所以没有预告
  - 结果对象：一次攻击一个对象，**每个对象只发一条消息**（4 段数据 1620 个对象全部只发一次，实测；旧笔记写的「攻击期间每帧重发」不对），之后内容由接收端每帧更新；攻击之间不复用（第 2b 段 590 个结果对象地址各不相同）。`IsAttackFinished` 没有对应字段，是 getter 现算的
  - 发送者：`msg:call("get_SendGameObject")` 就是怪物本体（100%）；怪物 `_Context:call("get_IsMaster")` 可读（联机副本为 false）

### 倒数怎么生成（SPEED 第 2 节；A 阶段又核对了一遍）

- **初值是名义帧**：hs 初值 = `app.AttackAreaData.AttackStartFrame`（烘焙表里这一段的起始帧）− `DetectedData.initData(EnemyCharacter, AttackAreaData, Single, Capsule, …)` 的 Single 参数。A 阶段 1489 条打主角的条目残差 0.000 帧，最小二乘 R² = 1.0000（实测，ATP 探针 + `tools/atp_analyze.py` C1）
  - Single 实测等于 60 × 怪物当前动作的 `_RawTotalElapsedSecond`（|差| 中位 0.002 帧，相关 1.000），即建结果时动作已经走过的帧数，中位 0.89 帧；动作中途才建的结果会到上百帧
  - 初值**不含**怪物速度：按 CoreState 分档，「hs 初值 − AttackStartFrame」各档中位都在 −0.95～−0.81 帧，和 C 无关（实测，A 阶段 286 个单位）。初值要是含速度，A = 100、C = 1.1 就会差 9 帧
- **之后按真实时间倒数**：主角身上的 holder 每帧调 `DetectedData.update(Single, Capsule)`，扣掉上一帧开头的引擎 DeltaTime（实测：A 阶段 |差| 中位 0.003 帧，约 21 万对；倒数速率中位 0.99988），和怪物速度无关（倒数速度和怪物平均速度的相关系数 0.02）
  - 单帧太长时扣减被钳在约 0.133 s（8 帧）：2a 最长一对 Δt = 0.158 s 只扣了 8.0 帧（实测）。推测怪物也按同一个 dt 走（没有直接测过）
- **怪物按 CoreState 倍速推进**：C = `EnemyCharacter:get_MotionSpeed_CoreState()`，含发怒、疲劳和按招的倍率。所以：
  - C = 1 时，hs 归零 ≈ 攻击判定激活（全局偏移 b ≈ −0.022 s）。归零的是判定激活，不是碰到身体
  - C > 1 时攻击比倒数早到约 A·(1 − 1/C)/60 秒（A = 登记后第一次读到的 hs）。2c 的 em27 C 在 1.08～1.264，按 hs/60 放刀，有接触的 6 刀里 5 刀放早（实测）
  - C < 1（疲劳）时晚到
- **只积 CoreState，不能积总速度**：`calcMotionSpeedTotal` / `_TotalMotionSpeedThisFream`（tot，12 个分量之积）里的招式因子 Sequence（以及 BlendTree）已经烘焙进名义帧，再乘一遍就是重复修正
  - 动画（动作层帧号）确实按 tot 播，但攻击判定激活跟的是「名义帧 + CoreState」：A 阶段倒数期间 Sequence ≠ 1 的 80 段（em14、em15、em31），只积 CoreState 的预测残差中位 −0.008 s，积 tot 是 −0.151 s；逐段比，只积 CoreState 更准的 63 段、积 tot 更准的 5 段（实测，atp_analyze C7.4，按时间窗配对，仅供参考）；按 7.1 口径，Sequence ≠ 1 的 46 个单位残差对它的斜率 0.04，约为 0
  - 设计数据：按总速度修正，留一只怪的残差 IQR 0.253 s；只用 CoreState 是 0.055 s（实测）。Scale 也不乘（设计数据乘了反而更偏）
  - A 阶段倒数期间 Random、Replica、WaitPacket、BlendTree 等其余分量全程为 1。类型库里有动作中途随机变速的轨道（`app.motion_track.EnemyVisual.cRandomSpeed`），没见它生效过；用到它的怪，m 要改成 CoreState × Random（推测）
- **CoreState 的读取时刻**：它按招在进入动作的那一帧设定，正好是发消息的那一帧；消息钩子在帧中间，可能读到上一招的值（设计数据有一例被前后样本夹住的切换）。所以要从消息之后的下一个帧回调起读（A 阶段新怪上钩子时刻和首帧一致 286/286，没遇到切换）
  - 对象存活期间 C 会随接替动作变：设计数据 128 个单位里 13 个，多数在 em27 的接替链上；A 阶段 0 个
- 按 hs/60 预测（v1.5.x 的口径）的残差 r = 实际首个接触 − hs/60：第 1 轮（em19、em20，26 次有接触的放刀）中位 0.008 s、IQR 0.08 s；第 2 段的 em23、em27（v1.5，8 次有接触）中位 −0.06 s、IQR 0.14 s，攻击普遍早到。原因就是上面的 C > 1

### 放刀时机：E5c（v1.6 起；V16 第 2 节）

```
m  = max(1, C)                C：从登记后第一个帧回调起每帧读；C < 1 按 1（偏早放，远离放早）
X += Δhs · (m_上一帧 − 1)      Δhs：同一条条目相邻两帧 hs 的递减（用 hs 自己当时钟，不用 os.clock）
Q  = (hs − (X − X0_e)) / m    X0_e：条目第一次读到时的 X；Q = 真实剩余帧
```

- C 不变时 Q = hs − A·(1 − 1/m)（即 E1）。首帧读不到 C 的结果永不放刀、照样参与否决；不回退到 hs（hs 口径在设计数据上放早约 26%）
- 时钟条目一对读数之间 hs 递减的上限是 30 + 60 × 两次读数隔开的秒数：读条目出错、读主角抛错的容忍期会让一对读数跨好几帧
- **A 阶段机制检验通过**（2026-10-11，只记录、不放刀；SPEED 第 7.1.1 节，实测）：5 只新怪（em2 护火龙、em3 铠龙、em31 暗器蛸、em15 护凶爪龙、em14 护雷颚龙）210 个单位，5 条判据全过
  - 残差 r（真实激活 − E5c 预测 − b）中位 −0.005 s、IQR 0.037 s；E0 残差对修正量的斜率 1.094；计时器速率中位 0.99988；初值各档中位 −0.95～−0.81 帧
  - 计时器那条是看过数据后澄清的口径（按引擎 DeltaTime 比，用户确认）：按 os.clock 逐对比，3 次 50～70 ms 的卡顿各出现一正一负超过 2 帧的读数，是两个时钟错开造成的测量伪影
  - 没有一只怪被标「系统性失败嫌疑」；左尾（r < −0.10 s）10/210，集中在 em3 (0,57) 的接替链和 em31 (0,49) 的配对错位
  - **没覆盖到**：存活期内 C 变过的单位 0 个（逐帧积分比只读一次更准的那部分没检验到）；C 最高只到 1.155（设计数据到过 1.264）；C < 1 只有 1 个；历战个体没确认

### 跨帧持有与 REF 的引用记账（REF 源码 `src/mods/bindings/Sdk.cpp` 核对过）

- 对象每次被交给 Lua 时，REF 自动 add_ref 一次，按地址在整个 Lua 状态里只记一份。所有 autorun 脚本共用一个状态
- 脚本自己调 `add_ref()` 时，如果这一份已经在了，就什么都不做；`release()` 扣掉的正是这共用的一份；userdata 被回收时 REF 还会自动 release 一次
- 所以两个脚本同时持有同一个对象时，谁先 `release()`，谁就扣掉了唯一的游戏侧引用。另一个脚本手里的对象这时已经没人引用，游戏一回收就成了悬空指针
- 实测（2026-10-11，v1.5 带探针）：AutoParryGS 帧逻辑出现 2 次 `caught (...) exception`。其中一次就在探针 release 同一个结果后的下一帧，紧接着出现的「release attempted…」告警说明记账已经被扣光。2c 也复现了一次：探针 release 后 15 ms（SPEED 5.7）
- 放刀模块单独跑（不带探针）时不会出现这种情况
- 「release attempted…」告警平时就很多：手动 release 之后，userdata 回收时的自动 release 也会打这一条，不代表出错
- **改法（已做）**：持有方都只 add_ref、不手动 release，丢弃时只删掉 Lua 引用，让 userdata 回收时 REF 自动 release。放刀 v1.6 和探针 APCal 1.1 都改了，合并后的 AutoGuardGS v1.5 照旧；`tools/check.sh` 静态检查，不许出现手动 release
  - 实测（v1.6 + APCal 1.1 试打，2026-10-11，约 63 分钟）：放刀模块的 STAT 里 red 一直是 0，没有一行 ERR / RED，日志里「release attempted…」告警 0 条；之前那次 v1.5.1 + APCal 1.0.1 的加载（约 30 分钟）有 14 条
  - 附带的好处（推测）：只要还有脚本持有，游戏就回收不了这个对象，地址也不会被新对象复用

## 血量

- 主玩家：`HunterCharacter.get_HunterHealth()` → `app.cHunterHealth`，其 `get_HealthMgr()` → `app.cHealthManager`（`get_Health`/`get_MaxHealth`/`set_Health(Single)`，底层是 `via.rds.DahliaFloatBox` 的 `_Health`/`_MaxHealth`）
- 扣血分两步：受击时 `cHunterHealth.requestDamage(HunterCharacter, Single, Single, Boolean×6)` 登记（累加进 `_RequestedTotalDamage`），`update` 里结算；红血是 `requestRedDamage(Single)`。cHunterHealth 自带 `_IsNoDamage`（`set_IsNoDamage`），语义未验证
- v1.4.2 的【测试】锁血：锁血时对主玩家跳过 requestDamage / requestRedDamage，另外每帧把血补满兜底。血条不动这一点还待游戏内确认；已确认开着锁血时探针 DMG 照常记到伤害数值（第 2b 段 90 条里 65 条非零），离线分析不受影响

## 抵消上捞斩

### 抵消是怎么触发的

- 成功条件：上捞斩的刀和怪物攻击**实际碰撞**。抵消检查（`cHunterWeaponHandlingBase.onParryHitPreProcess` → `onParryHit(WAIT)` → `onParrySuccess`）是由刀的碰撞触发的，不是由挨打触发的
  - 实验：蓄力中受击时强开 `IsParryInfoContinue`，游戏不会走抵消流程 ✗
  - 正常抵消时，怪物攻击打中的是大剑物体 `it0000_0002_0`、碰撞层 `ATTACK_PARRY_GET`；普通挨打是 `MasterPlayer`、`ATTACK_GET`。抵消检查就挂在这条受击流程里
  - 实验（AutoGuardParryCall）：蓄力中受击时把受击数据传给 `onParryHitPreProcess` ✗（仍是 NONE）；伪造成「打中大剑 + ATTACK_PARRY_GET」再传 ✗；**直接调用 `onParryHit(WAIT, 怪物, 位置)` ✓ 状态变成 WAIT**，但蓄力动作不会接着触发成功，松手后被清回 NONE
- 正常抵消的完整调用顺序（同一帧）：怪物 `EnemyCharacter.evHit_AttackParry(HitInfo, cAttackParamEm)` → 猎人 `onParryHit(WAIT)` → 怪物 `cEmModuleHit.onParryDamage(TARGET_ACCESS_KEY, true, 怪物)` → 猎人 `onParrySuccess(SUCCESS)`（由怪物的 onParryDamage 回调）→ 下一帧猎人进 (2,25)～(2,27)、怪物进 `cDamageParry`
  - 怪物端开关：下一帧 `cEnemyContext.Hit`（cEmModuleHit）的 `IsParryStocked=true`、`DamageActionType=PARRY`、`DamageActionID`=该怪的 cDamageParry；再下一帧被游戏清空
  - 取怪物模块：`EnemyCharacter._Context`（字段，没有 get_Context）→ `_Em` → `Hit`
  - `TARGET_ACCESS_KEY`（{Category, UniqueIndex}，单人主角是 PLAYER/0）按指针传，钩子里用 `sdk.to_valuetype(args[i], 类型)` 读
  - 上捞斩一般先砍中怪物（早 10～40 帧）再判定抵消；抵消碰撞还有专门的火花特效
- 「受击时强行抵消」实验（分支 `feat/auto-offset-forced-parry`）：自己按上面顺序调用 + 直接写怪物端开关 + 切 (2,27) 并补回 ParryState，能让角色出成功动作、怪物被弹开；但没有上捞斩本身的伤害和碰撞特效，看起来假，已搁置
  - 自己调 `onParryDamage` 不会登记抵消（内部还有条件），只能直接写字段；`evHit_AttackParry` 单独调用什么都不触发；切出蓄力动作会清空 ParryState
  - 怪物端是本地直接写字段，联机不会同步
- 命中特效（第 13～21 轮实验）：
  - 抵消碰撞那一帧没有命中特效；手动抵消看到的火花是上捞斩砍中怪物时的 `EffectID_Hit.PL_PARRY_*`（「抵消斩」这招的命中特效），和上捞斩伤害同一帧
  - 命中特效由**被打的怪物自己的** `EnemyCharacter._EffectController`（`_SetupFlag=0x7`，命中+受伤+通用）播，另有一份由全局 `AppEffectManager.get_EffectController()`（`0x1`，只有通用）跟随怪物关节播
  - 参数对象 `cEffectOverwriteParams`：正常命中 `_BitFlag._Value=0x31`、`_ExParam0`=怪物编号（`_Context._Em:get_EmID()`）
  - `playEffectCore` 正常命中时也返回 nil（只是排队），返回值不能当成功判据
  - 在下一帧开头或受击钩子里、用完全相同的控制器 / ID / 参数自己请求，画面上都**不出特效**，原因未查明，已停止
  - 重放保存的上捞斩 HitInfo（`HitController.notifyHitProc`，怪物端调用）会让**游戏崩溃**，不要再试
- **不要钩 `onParryHitPreProcess`**：抵消蓄力时它每秒被调用 6～18 万次（大多是空数据），挂 Lua 钩子会掉到约 22 fps

### 抵消窗口与放刀时机

- **抵消窗口就是刀的攻击判定开着的时段**（`HunterDef.CONTINUE_FLAG.WP_ATTACK_COLLISION_ON`；G1 只读研究，实测，V16 第 3.1 节）：
  - 出刀后 raw 0.321～0.342 s 打开（和下面机关扫描的 W0 = 0.328 s 对得上），动画约第 58 帧关：没有顿帧时约 0.836 s，顿帧可以拖到 1.22 s（所以结局等 1.3 s 再判）
  - 1202 次刀上接触全在开着的时候
  - 机关扫描的 W1 ≥ 0.944 s 晚于无顿帧的 0.836 s，推测是刀先砍中机关的顿帧把窗口拖长了
- **抵消窗口（第 1 轮机关扫描实测，24 个样本，分界无例外）**：以进入 (2,23) 为 0，首个接触在 **0.328 s 之前**一律接不住（身体先挨打），**0.331~0.944 s** 一律接住（扫描上限，W1 ≥ 0.944 s）。真怪 26 次有接触的放刀与这个窗口一致 100%
  - 从帧开头请求 (2,23) 到动作开始几乎没有延迟（δ ≈ 0）：第 1 轮 34 次请求全部第一次就被接受，包括从 (2,22) 发起的；v1.6 试打 7/7 也是（实测）
  - 请求 (2,23) 时玩家推着方向，会进 (2,24) 前进版（2c 第 4 刀，实测 1 次）；这一刀记作没进入、没接住
  - 空放时 (2,23) 会停到玩家有输入为止；SUPER_ARMOR 一直持续到约 **3.3 s**，空放代价很小
  - 上捞斩自己的刀约 0.32~0.33 s 砍中怪物。提前量越大，越容易**先砍中把怪物打出硬直/倒地/麻痹**，攻击被打断、不出抵消动作（第 1 轮 8 次「空放」里 6 次是这样，真正「攻击没来」只有 1 次）
- **预判放刀的规则**（v1.6 起，并入 AutoGuardGS v1.5 后不变；V16）：按住 (2,21)/(2,22) 时，打主角的 DANGER 条目里最早一段**该接的**（见下一节）真实剩余帧 Q（E5c）落进 [L_min, L] 就放，L_min = 22、L 默认 28；视野（原始 hs ≤ 90、he ≥ 0）里有长窗口（he − hs > 60）、抓取或 SKILL_GUARD 家族的攻击就整帧不放；联机副本怪不放。v1.5.x 用的是 hs
- 提前量 L 的经过：
  - 第 1 轮 L* 平台是 26~33（hs 口径，全部接住）。v1.5 取下沿 26，想让碰撞尽量早于自己先砍中
  - 到了 em23、em27 上，L=26 有接触只接住 11/18：攻击比预告早到，接触落在 0.328 s 之前
  - 三段合并（46 次有接触），平台是 31~39，L*=32；L=30 覆盖 43/46。v1.5.1 改回预注册的 30
  - 2c 发现早到的原因是怪物速度（上面「倒数怎么生成」），只调 L 修不好：hs 口径要把放早压到 5% 以下，L 得加到约 42，那时 C ≈ 1 的怪空放超过 40%（SPEED 3.3）
  - v1.6 改用 Q（真实剩余帧）。设计数据回放（样本内）给出 25 和 28 两个候选；用户定「先砍中把怪打断」不算空放，所以取 28：接触层回放窗口内 88/90、放早 0/90，em27 在攻击一激活就碰到人（g = 0）时的放早上界 9%（L = 25 时 24%）
- 空放（v1.5.x，hs 口径）：三段合并 19%（11/57），只去掉有硬直、倒地、麻痹证据的打断是 13%；把「上捞斩先砍中了怪物」都算作打断（SPEED 3.5，63 刀口径），纯空挥只有 1 次（约 2%）

### 结局与「该接」

- **结局按动作判**（G1，实测）：抵消状态 PARRY_STATE 从 WAIT 变 SUCCESS → 下一帧进 (2,27) HitL、怪物进 cDamageParry；WAIT → HIT → (2,26) HitM；RECOIL → (2,25) HitS，**被弹开、随即身体挨打，不算接住**。第 2b 段 3 次记成「CATCH25」的放刀实际都是 RECOIL（伤害 103.4 / 70.0 / 0 + 0.4 s 后 27.8）
- 进入 cParrySlashHitL 时收到 `cMsgParrySuccess(SUCCESS)`，HitM 时没有收到；按动作统计成功更可靠。第 1 轮接住 25 次：HitM 12、HitL 13，RECOIL 0
- **能不能抵消看攻击参数**（`DetectedData.get_AttackParam()` → `app.cAttackParamEm`；G1，实测）：
  - `_IsParryBreak`（Boolean，下面记作 pb）为真 = 会把刀弹开：RECOIL 的 4/4 都是 pb = 1 的招，进入 WAIT 的 53/53 都是 pb = 0。A 阶段 5 只新怪的候选条目里 pb = 1 的 0 个
  - `_GuardType`（`app.Hit.GUARD_TYPE`，定义在 `app.cAttackParamBase`；读到 5 个值：NORMAL 0、ALL_RANGE 1、UNABLE_GUARD 2、SKILL_GUARD 3、SKILL_GUARD_ALL_RANGE 4）：
    - SKILL_GUARD 只出现在抓取（DamageType CATCH）上，刀碰到也不触发抵消（怪物侧的闸门拒绝，没有 onParryHit）。A 阶段新怪上也只有 em31 的 1 条，同样是 CATCH
    - UNABLE_GUARD：设计数据里只在 em27 的 GESTURE 条目上；A 阶段 em15 有 12 个候选条目是 UNABLE_GUARD、伤害类型 NONE。**能不能抵消从没测过**
    - ALL_RANGE 和 NORMAL 一样，不影响抵消
  - `_DamageType`：咆哮、风压、震动（EAR / WIND / QUAKE）不是能抵消的打击；抓取（CATCH / CATCH_ZAKO / CATCH_SLINGER）抵消不了（见下）
  - 不影响抵消的字段：`_IsTechGuardBreak`、`_IsParryFix`、`_IsBlockEnable`、`_VersusGuardPower`（≤ 70 时）
  - 弹体（ShellIndex 有值）碰不到刀
- v1.6 的「该接」过滤（V16 第 3 节）：不是弹体、pb 为假、GuardType ∈ {NORMAL, ALL_RANGE}、不是效果攻击和抓取；任何一项读不准就不放。理由是放错比不放糟：pb = 1 上放刀是被弹开加挨打，抓取上放刀是被抓；不放最多是这一刀没抵消
- **抓取攻击抵消不了**（DamageType CATCH，guard SKILL_GUARD）：
  - 第 2a 段 em27 的抓取，刀碰到了也不触发抵消，吃了 259 伤害
  - (2,23) 的 SUPER_ARMOR 开着，照样被抓
  - v1.5.1 对 1.5 s 内的 DANGER 抓取条目整帧否决；v1.6 起 SKILL_GUARD 家族（SKILL_GUARD、SKILL_GUARD_ALL_RANGE）也整帧否决。现有数据里 SKILL_GUARD 只出现在抓取上，两者等价

### 实测结果与验收现状

- **v1.6 试打**（2026-10-11，session 1791712779，约 63 分钟，实测）：
  - 7 刀全在缠蛙 em19 上：接住 5（HitL 3、HitM 2），没接住 2，被弹开 0；否决 3 次（都是长窗口）；错误 0；7 刀都是第一次请求就被接受，其中 3 刀从 (2,22) 放出
  - 试打时的条件（游戏日志里 APCal 的 HDR 的 cfg_guard，实测）：AutoGuardGS v1.4.2 的自动防御、【测试】锁血、【测试】无限蓄力都开着，防御角度 360；探针 APCal 1.1 和 ATP 同时在跑。这些开关不进放刀的判断和结局判定（代码），但无限蓄力让抵消蓄力不会 2.5 s 过热自动放出、锁血让人倒不下，放刀的机会和节奏和正常打不同（推测不影响每一刀接没接住）
  - 没接住的 2 刀（id 3、5）都在 (2,23) 停到结算（`to=-`），两刀的首帧 C 都是 1.155。是空挥还是先砍中把怪打断，没有分类；APCal 当时也在跑，数据还在，可以离线分
  - 开销：放刀模块帧回调平均 0.015～0.039 ms，钩子 0.17～0.55 ms/s，同期帧率 60～124（中位 77），折合占帧时间约 0.1%～0.5%（中位约 0.2%）
- **B 阶段（正式验收）没做**：V16 第 9.2 节的协议（A 阶段那几只新怪、每只至少 15 次有接触的放刀）没有执行。新怪上的接住率、空放率都没有数；em19 是设计数据里见过的怪
- **之后怎么监控**：合并进 AutoGuardGS v1.5 后，打开「调试日志」，每次放刀写 `[AutoParryGS] FIRE` / `RES` 两行，用 `tools/apcal_analyze.py` 离线汇总（合并版只有日志，没有 JSON、STAT、SKIP、VETO）。要细分放早、空挥、打断，需要同时跑 APCal
  - 用户现在的 `AutoGuardGS.json` 仍开着上面那几个测试开关，部署后的监控样本也是在这些条件下采的。正式验收（B 阶段）时开不开还没定

## 走过的弯路

| 尝试 | 结果 | 原因 |
|---|---|---|
| 预判举剑：判定框距离 + 速度外推 | 误触发无法消除 | 同一时刻「会打中」和「打不中」的距离曲线一模一样 |
| 受击中途 changeActionImmediate 切肩撞 | 动作错乱 | 跳过了进入流程 |
| 虚拟按键出肩撞 | 没反应 | 蓄力中出肩撞不走这个键 |
| 受击时强开 IsParryInfoContinue 来抵消 | 无效 | onParryHitPreProcess 根本没被调用 |
| 受击时把（伪造的）受击数据传给 onParryHitPreProcess | 仍是 NONE | 函数内部还有检查，未定位 |
| 受击时强行走完抵消流程（分支 feat/auto-offset-forced-parry） | 能弹开怪物，但没有上捞斩伤害和特效 | 跳过了真实的刀与攻击碰撞，观感假 |
| 抵消蓄力时卡顿 | 掉到约 14～22 fps | 钩了 onParryHitPreProcess（每秒 6～18 万次调用） |
| 把剩余帧 hs 直接当真实剩余时间（v1.5.x） | 怪物加速时放早：2c 的 em27 有接触的 6 刀里 5 刀放早 | hs 是 1 倍速的名义帧，怪物按 CoreState 倍速走 |
| 按 calcMotionSpeedTotal（总速度）修正 | 误差更大：留一只怪的 IQR 0.253 s，只用 CoreState 是 0.055 s | 总速度里的招式因子已经算进名义帧 |
| 在消息钩子里读 CoreState | 可能读到上一招的值（悲观情景回放：放早 2/90 → 9/89） | CoreState 在发消息的那一帧按招切换，钩子在帧中间 |
| 用 os.clock 当速度积分的时钟 | 卡顿时漂移 | 游戏把单帧扣减钳在约 0.133 s，墙钟照走 |
| 时钟条目一对读数的 hs 递减上限固定为 30 | 断档后放刀偏晚、先挨打（mock：C = 1.264 时断档 0.6 s 晚 0.12 s、1.0 s 晚 0.21 s） | 跨多帧的正常递减被当成坏值整段丢掉；改成 30 + 60 × 隔开的秒数 |
| 两个脚本各自手动 release 同一个结果对象 | 悬空指针，帧逻辑 caught (...) exception | REF 按地址给整个 Lua 状态只记一份引用 |
| 在 pb = 1 的招上放刀 | 被弹开再挨打（2b 3 次） | 这类攻击会把刀弹开（RECOIL） |
| 把 (2,25) 算作接住 | 接住率虚高 | (2,25) 是 RECOIL；2b 的 3 次「CATCH25」实际都是被弹开 |
| 在抓取上放刀（v1.5，还没有抓取否决） | 被抓，吃了 259 伤害 | 抓取刀碰到也不触发抵消，(2,23) 的霸体也挡不住 |

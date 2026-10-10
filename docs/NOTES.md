# 研究笔记：《怪物猎人：荒野》内部结构

开发 AutoGuardGS 时用 REFramework、re-engine-mcp 和探针（`probes/`）摸清的东西。
所有结论都经过实测，未验证的会标注出来。

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
| (1,143)～(1,150) | cGuardReaction_* 防御反应（Tech = 精确防御） |
| (2,0) / (2,1) | 纵斩 / 强纵斩 |
| (2,5) / (2,6) / (2,7) / (2,11) | 开始蓄力 / 蓄力 / 强蓄力 / 真蓄力 |
| (2,15) / (2,17) | 肩撞（一段蓄力出 15，强蓄力和真蓄力出 17） |
| (2,21) | cIdleToParryCharge 抵消蓄力（按住时一直停在这里，**不会**进入 (2,22)） |
| (2,23) / (2,24) | cParrySlash 抵消上捞斩 / 前进版 |
| (2,25)～(2,27) | cParrySlashHitS/M/L 抵消成功后的特殊动作 |

## 关键规律：改状态 vs 改动作

- **改状态**（状态标志、参数）可以在受击结算中途做：在 `evHit_DamagePreProcess` 前置里改，在 `evHit_Damage` 后置里还原
- **改动作**必须在帧开头（`re.on_pre_application_entry("UpdateBehavior")`）调用 `HunterCharacter:changeActionRequest(LAYER=0, ACTION_ID, false)`，让动作控制器走正常的进入流程，被拒绝就每帧重试
  - `changeActionImmediate` 在结算中途硬切：动作对象换了，但动画和霸体没跟上，表现错乱 ✗
  - 从 MCP 的 HTTP 线程调用游戏方法会被拒（不在主线程）✗

## 防御

- 状态标志：`hunter:get_HunterStatus()._HunterStatusFlag`（`ace.cSafeContinueFlagGroup`，方法是 on/off/check(UInt32)），枚举是 `app.HunterDef.STATUS_FLAG`
  - `GUARD`：普通防御；`TECHNICAL_GUARD`：精确防御（单开它就会进 cGuardReaction_Tech）
  - `SUPER_ARMOR` / `HYPER_ARMOR`：霸体（蓄力从第一帧起就有 SUPER_ARMOR，肩撞会额外加 HYPER_ARMOR）
- **受击时判定为防御**：在 `evHit_DamagePreProcess` 前置里打开标志，游戏会按自己的规则（角度、体力、削伤）结算，零误触发
- 能不能举剑：`checkContainsActionInCurrentBTable(cGuard, 0, ACTION_CANCEL_INDEX.Invalid)`（在 controller entity 上调用）判断行为表里有没有通往防御的路，但**不看时机**（拔刀翻滚、倒地起身时也返回 true），所以要配合 ACTION_ATTR 黑名单
- 防御角度：`PlayerManager:get_Catalog():getWeaponActionParam(0)` → `Wp00ActionParam._GuardDegree` / `_AimGuardDegree`，都是**全角**（70 = 正前方左右各 35°），所有大剑共用

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
- **怪物攻击预告**（本来给 NPC AI 用）：怪物每切一次动作，就给目标猎人发一条 `cMsgEmAttackAreaResult`
  - 在 `cMasterPlayerControllerEntity.receiveGameMessage` 里截取；猎人身上的 `mcHunterAttackAreaResultHolder` 对玩家是未激活的
  - `AttackAreaResult`：TargetCharacter、ResultType（SAFE/CAUTION/DANGER）、`getClosestDetectedData().HitStartRemainFrame`（距离命中还剩多少逻辑帧，1/60 秒），会实时倒数
  - 实测：提前 1～2 秒给出，误差 ±0.2 秒以内；中途可能从 DANGER 降级成 CAUTION，但攻击照样打中（漏报）
  - **训练机关没有预告数据**（恒为 SAFE / 空）
  - 对象被怪物复用：要跨帧持有就 `add_ref`，用完 `release`

## 抵消上捞斩

- 成功条件：上捞斩的刀和怪物攻击**实际碰撞**。抵消检查（`cHunterWeaponHandlingBase.onParryHitPreProcess` → `onParryHit(WAIT)` → `onParrySuccess`）是由刀的碰撞触发的，不是由挨打触发的
  - 实验：蓄力中受击时强开 `IsParryInfoContinue`，游戏不会走抵消流程 ✗，所以「受击时判定为抵消」做不到
- 上捞斩放出后约 0.30～0.39 秒刀才有效，比怪物从判定激活到命中（约 0.15 秒）还慢，所以必须靠预告提前放刀
- 进入 cParrySlashHitL 时收到 `cMsgParrySuccess(SUCCESS)`，HitM 时没有收到；按动作统计成功更可靠

## 走过的弯路

| 尝试 | 结果 | 原因 |
|---|---|---|
| 预判举剑：判定框距离 + 速度外推 | 误触发无法消除 | 同一时刻「会打中」和「打不中」的距离曲线一模一样 |
| 受击中途 changeActionImmediate 切肩撞 | 动作错乱 | 跳过了进入流程 |
| 虚拟按键出肩撞 | 没反应 | 蓄力中出肩撞不走这个键 |
| 受击时强开 IsParryInfoContinue 来抵消 | 无效 | 抵消需要刀的碰撞 |
| 探针每帧大量读取游戏对象 | 掉到约 14 fps | 探针停用后恢复（具体是哪个没定位） |

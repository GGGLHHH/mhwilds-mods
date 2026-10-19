# SUMMARY
定稿结论。本次在定稿前另做了一轮只读核实，范围包括项目源码、游戏日志、会话记录和 MCP 类型库；没有改任何文件，也没有调用游戏方法。

**执行路径不变。** 只在帧开头用 changeActionRequest(LAYER 0,(2,23),false) 放刀；伤害、火花、顿帧、怪物弹开全部来自游戏原生的刀与攻击碰撞。

**运行时规则（v1.5）：**
- 只在 (2,21)/(2,22) 中生效。
- 对「打我的」预告逐条看，只取 DANGER 条目。
- 去掉弹体条目，以及咆哮、风压、震动类条目。
- 去掉判定窗口超过 60 帧的条目。
- 若有长窗口 DANGER 在 1.5 s 内到来或正在进行，否决放刀。
- 剩下的条目中，最小剩余帧 Q 落进 [L_min, L] 就放刀。默认 L=28、L_min=18，第 1 轮后按预注册规则定参。
- 不做墙钟外推，不看 closest，不用 CAUTION 或 ATK+ 触发。

**反方意见带来的四类修改：**
1. 主张降级。新规则只能排除「长窗口」和「remain≈0」两类误放。v1.3 的 3 次空放里只有 1 次属于这两类；其余空放的主因是「标了 DANGER 但攻击没来」，任何时序规则都去不掉。因此：
   - 第 1 轮的主要产出改为空放归因；
   - 预先写死三条退路：A 保守模式、B 提示模式、C 默认关闭的实验开关。
2. 测量链去掉「自己给自己打分」。
   - 结局互斥，接住优先。
   - 窗口一律按首个接触时刻 c_first 定义。
   - L* 取残差最大覆盖平台的中点。
   - 接住率用留一招式交叉验证。
   - 闸门必须有机制解释并满足绝对计数，最多 2 个。
   - 接触与回合的匹配规则在部署前写进分析脚本，并用 mock 数据跑通。
   - 第 2 轮保留只记录的探针，参数冻结。
3. 安全。
   - rc 独立成 AutoParryGS.lua，自带 pcall 和配置。
   - v1.4 只打一个补丁 v1.4.1：在抵消动作族 (2,21)~(2,29) 里不改写防御角度。原因是 v1.4 的 apply_angle 在刀上抵消碰撞的同一帧、抵消结算之前执行，而当前角度设为 360。
   - 机关扫描放进 rc 的测试模式，自己轮询机关动作。
   - 探针错误分两级：核心错误标红，要求停下；可选模块出错就自停该模块、标黄，测量继续。
4. 实测修正。
   - 机关出招周期为 4.6 s，被抵消后为 7.0 s。
   - 扫描的 X 上限定为 1.0 s，配作废规则，约需 6~10 分钟。
   - 空放代价比原先估计的大：(2,23) 不撞上时会停到玩家有输入为止（复核样本约 3.4~3.8 s），尾段没有霸体。为此增加 T_armor 测量和长窗口否决。

**轮次安排：**
- 第 1 轮：一次 Reset，依次做训练场空挥 3 次、机关扫描（≤10 分钟）、真怪（≤15 分钟）。
- 第 2 轮：两只怪验收。
- 只有命中预先写死的条件时，才补一次只含真怪段的短轮。

**当前现场（本次核实）：**
- 游戏从 16:03 起一直在运行。
- AutoParryPredictProbe.lua 已不在游戏 autorun 里，autorun 目录在 18:25 修改过，autorun_disabled 里也没有。
- 强行抵消实验探针 AGPCall 仍驻留在 Lua 状态中，直到下次 Reset。
- HitboxViewer 在 autorun 里，也钩了 activateAttack。
- 当前配置：enabled=false、guard_angle=360、infinite_charge=true、debug_log=true。

**部署前需要用户同意：** 移动 HitboxViewer、部署 rc 和 v1.4.1、复制探针；是否先本地提交 v1.4 基线。

# KEY INSIGHTS
- 「真实」只取决于什么时候松手，与实现路径无关。放刀只用帧开头的 changeActionRequest(LAYER 0,(2,23),false)。v1.3 放了 5 次，5 次都是第一次请求就被接受、下一帧进入 (2,23)，其中 1 次是从 (2,22) 发起的（14:57:01.594，本次在会话记录里复核）。伤害、火花、顿帧、弹开都来自原生的刀与攻击碰撞。
- 时序链是 c_first = R/60 + r − δ，必须落在抵消窗口 [W0, W1] 内。
- W0 约 0.30~0.36 s，有两种解释，要靠 PH 时刻裁决。
- W1 ≥ 0.654 s；71 帧那个样本约 0.73~0.84 s。
- 上捞斩自己约 0.32 s 时先砍中目标。
- r 的已知数据：em20 同一招、剩约 20 帧时读数，刀上接触为 +0.01~+0.04 s（n=2）；跨招式、按消息时刻读数为 −0.24~+0.16 s；(0,126) 的接触落在判定窗口末尾，约 +0.3 s。

所以单一 L 的成功率上限，取决于窗口宽度和 r 分布宽度谁大，只能实测。
- 空放的主因不是时序。v1.3 的 3 次空放里，新规则只能排除 1 次，即长窗口的 (0,9)；其余两次是标了 DANGER 但攻击没来（AI 转招、没出手、改打别人），任何时序规则都去不掉。因此第 1 轮的主要产出是空放归因，退路也预先写死。
- 消息里的 TargetCharacter 恒为接收者：≥36 条预告全部是「打我」，单看消息无法知道怪物在打谁。要读怪物的 cEmModuleTarget.getTarget(false, FIRST)。正常抵消时，主角的键实测为 PLAYER/0（本次在日志 16:12:47.046 的 onParryDamage key=PLAYER/0 复核）。
- 空放的代价被低估了。(2,23) 不撞上时会一直停到玩家有输入为止。复核样本 f4469→f4794 约 3.4~3.8 s，之后挨打被 v1.4 转成了精确防御，说明尾段已经没有霸体。由此带来三项改动：
- 测 T_armor；
- 晚侧余量按 min(W1, T_armor−0.05) 算；
- 长窗口 DANGER 即将到来时否决放刀。
- v1.4 的 apply_angle() 在 is_enemy 判断之后、config.enabled 判断之前执行（本次读源码第 368–373 行确认），所以每一次敌方命中都会触发它，包括刀上的 ATTACK_PARRY_GET 抵消碰撞，而且发生在同一帧的抵消结算之前（日志 16:12:47.045 复核）。当前 guard_angle=360。在抵消动作族里必须不改写角度，否则测量会混入这个因素，「全向抵消」也可能是 mod 造成的假象。
- 一次抵消成功的帧里，可以同时出现身体 ATTACK_GET 接触（16:12:47.045 手动抵消实测）。结局分类必须互斥、接住优先，否则计数会把一次成功同时记成失败。
- 机关是测窗口的仪器。
- 它的出招时序固定：从 cSmallAttack 开始，约 1.12~1.15 s 后接触；周期 4.6 s，被抵消后 7.0 s。虽然没有预告数据，也能按时间放刀。
- 局限：它只有一招、一种几何，扫描结果必须用真怪的接住/失败标签核对。
- X 的上限取 1.0 s，因为更大的 X 需要在 cSmallAttack 开始前就放刀，没法锚定。W1 ≥ 1.0 s 时按右删失处理即可。
- 计时字段：_RawTotalElapsedSecond 是真实字段（偏移 0x50）；get_CharaElapsedSecond 只是没有对应字段的计算 getter，语义未知（本次 MCP 复核）。窗口跟着动画时间走还是跟着墙钟走，要靠 raw、chara、动画层 Frame 三种时钟对照，并按「是否先砍中怪」分组来判断。
- 选参和评估必须分开：
- L* 取残差最大覆盖平台的中点；
- 接住率用留一招式交叉验证；
- 闸门最多 2 个，每个都要有机制解释，并满足绝对计数门槛；
- 接触与回合的匹配规则在部署前写进分析脚本。
- 本次在 MCP 类型库里核实存在、但还没在 Lua 运行时用过的接口：
- EnemyCharacter._Context（cEnemyContextHolder）的 get_IsMaster()；
- _Context._Em.Target（cEmModuleTarget）的 getTarget(Boolean, TARGET_ORDER)，返回 TARGET_ACCESS_KEY{Category, UniqueIndex}；
- EnemyManager.findEnemy_SystemIndex(Int32)，返回 cEnemyManageInfo，可调 get_Character()、get_Pos()、get_CharacterValid()；
- via.motion.TreeLayer 的 get_Frame() 和 get_Speed()。
- 当前现场：
- 游戏从 16:03 起一直在运行。
- AutoParryPredictProbe.lua 已不在游戏 autorun 里（18:25 起）。
- AGPCall 实验探针仍驻留，直到下次 Reset；它会在蓄力中挨打时伪造一次抵消。
- HitboxViewer 也钩了 activateAttack，并曾在缓存的 cEnemyBrowser 上触发访问冲突。

# DECISION RULE
【A 运行时规则（v1.5；rc 用同一规则，另加 L 轮换和读取兜底）】
- 求值时机：每帧在 re.on_pre_application_entry('UpdateBehavior') 里求值。
- 记号：t=os.clock()；me=主玩家 HunterCharacter；hs(d)、he(d) 是 System.Single，单位 1/60 s。
- 前提（任一不满足就结束 streak 并返回）：
  - P1 cfg.auto_parry 为真；
  - P2 me 存在，且 me:get_WeaponType()==0；
  - P3 me 基础层当前动作 ∈ {(2,21) cIdleToParryCharge, (2,22) cParryCharge}。
- 跟踪集 R：收到的 cMsgEmAttackAreaResult 中，TargetCharacter 地址等于 me 地址、且尚未释放的结果 r。
- 否决 V：存在 r∈R（¬r.IsAttackFinished）和 d∈r.DetectedDataList，满足 τ(d)=DANGER ∧ he(d)−hs(d) > W_long ∧ hs(d) ≤ H_veto ∧ he(d) ≥ 0。
- 候选集 C = { d | r∈R, ¬r.IsAttackFinished, d∈r.DetectedDataList, τ(d)=DANGER, L_min ≤ hs(d), 0 ≤ he(d)−hs(d) ≤ W_long, ShellIndex(d) 无值, AttackParam(d)._DamageType ∉ {EAR, WIND, QUAKE}, 且第 1 轮采用的每个闸门 g 都有 g(d) 成立 }。
  - ShellIndex 或 DamageType 读取失败时按「通过」处理（fail-open），并计数。
  - v1.5 中，如果第 1 轮核实了 get_IsMaster：发送者怪物 _Context:get_IsMaster()==false 时，它的条目不进入 C。
- 触发量：Q(d) = hs(d) + α·(he(d) − hs(d))，默认 α=0。
- 放刀：当 P1∧P2∧P3 ∧ ¬V ∧ C≠∅ ∧ Q* = min_{d∈C} Q(d) ≤ L 时，调用 me:changeActionRequest('app.AppActionDef.LAYER 0', ACTION_ID(2,23), false)。
- streak：
  - 条件连续成立的帧合并为一次放刀。首帧记录 t_req 和 R0=Q*；之后每帧重算 C 再请求。
  - 进入 (2,23) 时记录 R1 和请求帧数 n。
  - 条件不再成立，或离开 (2,21)/(2,22) 时，streak 结束。
  - 不设超时：Q 单调递减，离开 [L_min, L] 后自然停止。
- rc 专有：
  - L 取轮换值；
  - get_Item 或逐条读取出错时，如果 r.ResultType=DANGER，就用 getClosestDetectedData() 那一条代替，记 src=FB 并计数。
- 默认值：L=28，L_min=18，W_long=60，H_veto=90，α=0。
- 明确不做：
  - 墙钟外推（粘住）；
  - 只看 closest；
  - 用 CAUTION 触发；
  - 按怪或按招建表；
  - 用 ATK+ 触发；
  - 钩 onParryHitPreProcess；
  - 伪造或重放 HitInfo；
  - 用 changeActionImmediate；
  - 请求 (2,24)。

【B 结局分类（互斥，按优先级取第一个；时刻都相对 t_req）】
1. CATCH：1.3 s 内进入 (2,25..27)。同一帧或更早的身体接触不再另记为失败。附记 HP 损失；损失为 0 的另记一个 CLEAN 标签。
2. RECOIL：1.3 s 内进入类名以 cRecoil 结尾的动作，或 onParrySuccess / cMsgParrySuccess 的状态为 RECOIL。
3. FAIL_EARLY：该攻击者有接触，且 c_first < W0。
4. FAIL_LATE：c_first > W1；或在离开 (2,23) 之前（最长 4 s）身体被打，且当时没有 SUPER_ARMOR（收尾挨打）。
5. FAIL_OTHER：其他有接触但没接住的情况。
6. WHIFF：从 t_req 到 t_req + he/60 + 0.3 s，没有该攻击者的任何接触（含弹体路径），也没有 PH。he 取触发条目在 t_req 时的值。
   - 子类 INTERRUPTED：上捞斩先砍中该怪（EMHIT），且怪物在预测的 hs 归零之前离开了 KeepActionID、进入受击类动作。

【C 第 1 轮后定参（规则在部署前写进 tools/apcal_analyze.py，并用 mock 数据跑通）】
记号：
- t_start = (2,23) 首帧读到的时刻 − 当时的 _RawTotalElapsedSecond；
- c_first = 该攻击者首个接触的时刻 − t_start；
- δ = median(t_start − t_req)；
- d̄ = median(L − R0)，即帧离散化带来的偏差。

C1 窗口 [W0, W1]（以 c_first 为横轴）：
- 机关扫描样本为 (X_obs=c_first, PARRY/FAIL)。
  - 可分时：W0 = 最小 PARRY 与它下方最大 FAIL 的中点；W1 同理。
  - 重叠时：对下段、上段分别拟合 logistic，取 P=0.5 的点，附 bootstrap 80% 区间。
  - 上方没有 FAIL 时：W1 按右删失记为 ≥ 最大 PARRY。
- 用真怪核对：有接触的真放刀按是否 CATCH 标注。若与扫描窗口 ±0.03 s 的一致率低于 80%（n≥10），改用真怪标签同法估计，并与扫描窗口取交集。
- W1_eff = min(W1, T_armor − 0.05)，其中 T_armor 是空挥中 (2,23) 的 SUPER_ARMOR 结束时刻。

C2 残差：
- 对有接触、且触发时在蓄力中的真放刀 i：r_i = c_first,i − R0_i/60 + δ。
- 若 Spearman |ρ(r, R0)| ≥ 0.4，用斜率 b 校正：r_i(L) = r_i + b·(L − R0_i)；否则 r_i(L) = r_i。

C3 L*：
- L* = argmax_{L∈{18..45}} N(L)，其中 N(L) = Σ_i 1[W0+0.02 ≤ (L−d̄)/60 + r_i(L) − δ ≤ W1_eff − 0.03]。
- 最大值是平台时取平台中点（四舍五入）；有多个平台时取 L 较小的那个。
- 接住率 P_CV 用留一招式交叉验证：每次去掉一个 (EmID, KeepActionID) 组，用剩下的样本重算 L*，再拿它评估被去掉的这组。

C4 L_min* = clamp(⌈60·(W0 + 0.02 + δ − Q25(r))⌉, 15, L* − 6)，其中 Q25 是 r 的下四分位数。

C5 W_long*：默认 60。只有 he−hs ∈ (30, 60] 这组的接住率低于 50%（n≥4）时才降到 30；只许往保守方向调。

C6 估计量与 α：在「全程在蓄力中」的回合上，用留一招式比较 V0、V1(closest)、α=0.25、α=0.5 四种方案的残差 IQR。默认用 V0、α=0；其他方案只有 IQR 小 20% 以上才换。

C7 空放率 F = max(F_actual, F_shadow)：
- F_actual = 真放刀中 WHIFF 的比例；
- F_shadow = 在 L* 处会触发、且从 t_L 到 t_L+1.2 s 全程在蓄力中的回合里，直到 he 归零 + 0.3 s 都没有该攻击者接触的比例；
- INTERRUPTED 计入 F；同时另报一版不计入的。

C8 闸门（最多 2 个）：
- 候选：
  - g1 怪物当前目标不是我：getTarget(false, FIRST) ≠ PLAYER/0；
  - g2 |来向角| > 120°：用放刀帧的 AxisZ 和怪物根位置计算；正负号先用接触点角度的分布核实；
  - g3 _IsParryBreak 为真，或 _GuardType=UNABLE_GUARD；
  - g4 怪物距离 > 7 m；
  - g5 DANGER 连续不足 6 帧；
  - g6 按怪物总速度缩放：hs/(60·speed)；
  - g7 KeepActionID 与怪物当前动作不一致。
- 采用条件（三条同时满足）：
  - 有机制解释；
  - 在 L* 处去掉 ≥4 次空放或失败；
  - 损失 ≤1 次潜在接住。潜在接住的定义：会触发的回合在 t_L+1.2 s 内有该攻击者接触。
- 按净收益（去掉数 − 3×损失数）贪心选取，并报告评估过的候选总数。

C9 判定（每项只设一个门槛）：
- (a) 有接触的真放刀中，「c_first ∈ [W0, W1]」与「CATCH」不一致的次数 ≤ max(2, 10%)；
- (b) P_CV ≥ 0.75（有接触的回合 n≥15）；
- (c) F ≤ 0.25（n≥20）；
- (d) 关键错误为 0，没有崩溃，fps 中位数下降 ≤5%。

全部通过，v1.5 默认开启。否则把数字交给用户，三选一：
- A 保守模式：只对单条目、he−hs≤30、DANGER 持续 ≥12 帧的条目放刀，效果用回放数据给出；
- B 提示模式：同一规则，但不放刀，只在屏幕上提示松手。提前量取 L+12 帧，用来补人的反应时间；
- C 留作默认关闭的实验开关。

C10 补测条件（预先写死；只补真怪段，约 10 分钟）：
- 关键错误不为 0；或
- 有接触的放刀少于 15 次；或
- DANGER 回合少于 30 个；或
- 日志和 JSON 都丢了。

【D 第 2 轮验收】
- v1.5 参数冻结；探针只保留记录部分。
- 两只出招风格不同的怪，各打约 10 分钟，其中一只是新怪；至少一只要关掉无限蓄力。
- 按同一分类，验收标准：有接触的放刀接住率 ≥75%，空放 ≤25%，帧率不变，用户确认观感是原生的。
- 滑块的每次改动都写进日志；验收只用第一次改动之前的数据。

# PARAMETERS
- **parry_lead（L，放刀提前量，单位 1/60 s）** = 默认 28（约 0.467 s）。菜单滑块 20–45，第 1 轮之后改为 [L_min*, 45]。rc 版按 {20,24,28,32,36} 轮换：每 5 次一组，组内乱序；只有真的进入 (2,23) 才换下一档。轮换期间滑块不生效。 : 预计首个接触时刻 c_first ≈ L/60 + r − δ，其中 δ≈0.012。em20 在剩约 20 帧时读数，r 为 +0.01~+0.04（n=2）。取 L=28 时 c≈0.48，位于已证实的接住区间 [0.36, 0.654] 中部；晚侧还给「尾段可能没有霸体」留了余量。轮换的五档覆盖窗口的早、中、晚三段；其中 20 是唯一有实测 2/2 的值，留作对照。最终的 L* 按 decision_rule 的 C3 确定。
- **L_min（PARRY_LEAD_MIN）** = 18。第 1 轮后按 C4 重算，限定在 [15, L*−6]。 : R=L_min 时，预计接触时刻大约正好在 W0。v1.3 的两次成功都是在剩 19~19.5 帧时放刀，这是有证据支持的最低值。再低的话，放出去只会先挨打再丢掉蓄力；不放则由蓄力霸体硬吃、蓄力保留。这个下限还顺带排除了两种情况：remain≤0（已经在出招）和刚出现就已太晚的 DANGER。
- **W_long（LONG_WINDOW）** = 60（1.0 s） : 吐息、冲撞、持续扫尾这类长判定窗口，接触时刻由几何决定，从 HitStart 推不出来。旧依据有误，已按反方意见更正：已知的空放窗口多数 ≤30 帧，所以 W_long 只是安全阀，不是降低空放的手段。第 1 轮后只许往保守方向调整（C5）。
- **长窗口否决视野 H_veto** = 90（1.5 s）。条件：存在 DANGER 条目，满足 he−hs>W_long，且 hs≤90、he≥0（即将到来或正在进行）→ 本帧不放刀。 : 放刀后约 1.5 s 内，角色处在 (2,23) 或抵消成功序列中。如果此时长窗口攻击持续打过来，空放后的收尾段或成功后的后续动作会吃到没有霸体的完整受击。不放刀则由蓄力霸体硬吃，效果等于没装 mod。
- **弹体与效果攻击跳过** = 开启。以下条目不进候选：ShellIndex 有值；或 AttackParam._DamageType ∈ {EAR, WIND, QUAKE}。读取失败时按「通过」处理（fail-open），并计数。 : 从类型名看，远程攻击能被抵消是个别怪物专门开启的（Em0009 的 ENABLE_PARRY_LONG_RANGE_ATTACK）；NPC 闪避逻辑也忽略弹体；咆哮、风压、震动本身不是可以抵消的打击。用 fail-open，是因为这些读取接口第一次在真怪上运行时可能出错，不能因此一刀都不放、整轮拿不到数据。
- **触发量 Q 与 α** = Q = hs + α·(he − hs)，α=0 : (0,126) 那次接触落在判定窗口末尾，说明接触可能发生在 [hs, he] 的中段或后段。α 是一个通用参数，不按招式区分。只有留一招式交叉验证下残差 IQR 缩小 ≥20% 才启用（C6）。
- **估计量** = V0：逐条 DANGER 条目里取最小 Q。rc 中逐条读取失败时，退回 getClosestDetectedData()，记 src=FB 并计数。 : 有多个检测体时，closest 与时间最早的条目对不上；但「closest 取错段导致攻击早到」并没有被证实，所以不宣称 V0 能修复早到。V1（closest）作影子对照，按 C6 决定取舍。FB 计数为 0 时，终版删掉兜底。
- **生效动作与放出动作** = 只在 (2,21) cIdleToParryCharge 和 (2,22) cParryCharge 中判定；只请求 (2,23) cParrySlash。 : 按住蓄力时角色一直停在 (2,21)。从 (2,22) 放刀已实测被接受过 1 次（14:57:01.594，本次复核）。(2,24) 只有 1 个样本，而且出刀晚约 0.07 s。
- **请求与重试** = 在帧开头调用 changeActionRequest(LAYER 0,(2,23),false)。条件连续成立的帧合并为一次放刀，每帧重算后再请求，不设超时。 : v1.3 放了 5 次，5 次都是首次请求即被接受、下一帧进入 (2,23)。Q 单调递减，区间 [L_min, L] 宽度 ≤ 约 0.2 s，本身就构成重试上限；每次重试前也都会重新确认时机。
- **预告跟踪与释放** = 消息钩子 + add_ref，同一对象重发时刷新 t_msg。满足任一条件就释放：IsAttackFinished；全部条目 he<−30 且距 t_msg ≥1 s；距 t_msg ≥8 s；主角为 nil 或地址变化；关闭开关；Reset Scripts。最多跟踪 32 条，满了丢掉最旧的。 : 修掉 v1.3 的两个隐患：只认第一条消息、5 s 后一律丢弃。8 s 能覆盖实测最长的预告（402 帧，约 6.7 s）。改为直接读 holder 列表要等第 1 轮对照通过（P16）。
- **结局判定常数** = CREDIT=1.3 s。空放：直到 t_req + he/60 + 0.3 s 都没有该攻击者接触。收尾挨打一直统计到离开 (2,23)，最长 4 s。 : W1 可能到 0.84~0.9 s，怪物端 DelayFrame ≤10 帧（≤0.167 s），所以 1.3 s 足够，又不会把下一次放刀吃进来。空放按触发条目自己的结束时刻判断，长判定窗口的攻击不会被误记成空放。
- **窗口余量** = m_e=0.02 s，m_l=0.03 s；W1_eff = min(W1, T_armor − 0.05) : 早侧：有约 1 帧的量化误差，帧开头读到的剩余帧也略有滞后。晚侧：窗口终点本身不确定，而且尾段霸体结束后挨打就是完整受击。
- **机关扫描（rc 测试模式，默认关）** = X 先跑粗网格 {0.24,0.28,0.32,0.36,0.40,0.50,0.60,0.70,0.80,0.90,1.00}，乱序各 1 次；再在成功/失败交界的两侧细化，步长 0.02，每条边界最多 6 个点；最后交界点各重复 1 次。D_c 初值 1.13 s，前 2 个有效周期只学习不放刀，之后取最近 5 次的中位数。有效样本满 24 个即完成，上限 36 个或 10 分钟；每个 X 最多尝试 3 次。 : 网格覆盖了：已知的失败区 0.27~0.30、窗口起点区 0.31~0.36、已证实的 0.654，以及 NPC 先验给出的约 0.9。X 超过约 1.05 s 时，需要在 cSmallAttack 开始之前就放刀，而出招周期本身有 ±0.07 s 抖动，无法精确锚定，所以上限取 1.0。按这个网格，边界精度约 ±0.02~0.03 s。
- **样本目标与结束条件** = A1 段空挥 3 次。扫描有效样本 ≥24。B 段：放刀 ≥45 次且有接触 ≥20 次，DANGER 回合 ≥60 个；或打满 15 分钟。 : 按约一半空放估算，45 次放刀能得到 20 次以上接触。窗口边界要达到 ±0.03 s。L* 的留一交叉验证至少需要 15 个有接触的回合。
- **定参与判定门槛** = 见 decision_rule 的 C8 和 C9。判定：一致性不符次数 ≤max(2,10%)，P_CV ≥0.75，F ≤0.25，关键错误为 0，fps 下降 ≤5%。闸门：要有机制解释，去掉 ≥4 次空放或失败，损失 ≤1 次接住，最多 2 个。 : 每项只设一档门槛，并且提前写死，避免看了数据再改规则。空放门槛按「4 次自动放刀里最多 1 次放空」的手感来定；达不到就把数字交给用户，选择退路。
- **错误分级与自停** = 核心（MSG、ACT、CT、DMG、PH/PS、PT、JSON，以及 rc 的帧逻辑）：10 s 内出错 ≥3 次 → 标红，要求停止。可选模块：第一次出错 → 停用该模块、标黄、测量继续。rc 帧逻辑连续 30 帧出错 → rc 自停并标红。 : 预告条目相关的接口在训练机关上一次都不会执行，第一次运行是在真怪段。不能因为一个可选字段读取出错，就让整轮测量作废。
- **性能与日志预算** = 探针每帧 Lua 耗时平均 ≤0.3 ms。activateAttack 连续 3 个统计周期 >3000 次/秒 → 钩子第一行直接 return。日志平均 ≤5 行/秒。JSON 只在空闲帧写，两次间隔 ≥60 s。 : 钩子的分发开销用 os.clock 量不出来，所以改用调用次数 + fps 来判断。测量本身不能造成卡帧，否则剩余帧的倒数和接触时刻会一起漂移。
- **联机闸门（v1.5）** = 发送者怪物 _Context:get_IsMaster()==false（即副本）时，它的条目不放刀。第 1 轮核实接口可用后启用；否则只在 README 里写明。 : 非主机端的怪物是副本，预告可能要等网络包，速度也会被同步调整。本轮全程单人，不测联机。
- **探针自停** = 加载 90 分钟后自动停止记录，可在菜单里重新开启。第 2 轮之后移出 autorun（需征得同意）。 : 避免探针在日常游玩时长期运行、持续钩函数、持续写文件。

# MEASUREMENT PLAN
- 【准备（我来做，不占用户轮次）】
- 编写以下文件（具体见 implementation_outline）：
  - rc：src/reframework/autorun/AutoParryGS.lua
  - v1.4.1 的角度补丁
  - 探针：probes/AutoParryCalib.lua
  - mock：tools/mock/
  - 分析脚本：tools/apcal_analyze.py
- 依次通过以下检查：
  - tools/check.sh；
  - mock 全部场景，不出现 ERR 或 FMT_ERR；
  - 分析脚本在 mock 输出上能算出每一个指标；
  - 用 MCP 只读 get_type 核对 probe_spec 里的全部名字。
- 部署前再确认一次：游戏 autorun 里没有 AutoParryPredictProbe.lua。
- 【部署（征得同意后）】
- 把 HitboxViewer.lua 和 HitboxViewer/ 暂时移到 reframework/autorun_disabled。
- 运行 tools/deploy.sh，部署 AutoParryGS.lua（rc）和 AutoGuardGS.lua v1.4.1。
- 手动把 probes/AutoParryCalib.lua 复制进游戏的 reframework/autorun。
- 【第 1 轮 · 开始（约 1 分钟）】
1. 在游戏里按 Insert，打开 REF 菜单 → ScriptRunner → Reset Scripts。
   - 这一步也会卸掉仍驻留的 AGPCall 实验探针，所以在这之前不要测试抵消。
2. 确认屏幕角落出现两行字：「APCal 自检 OK 错误 0」和「自动放刀 rc L=..」。
   - 第一行是红色或没出现：先停下，把截图或日志发给我。
3. 「大剑自动防御」的配置保持不动：
   - 「启用」保持关闭（现在就是关的）；
   - 无限蓄力保持开启；
   - 防御角度不用动，v1.4.1 在抵消动作里已经不改角度。
- 【第 1 轮 · A1 空挥 3 次（训练场，约 1 分钟）】
1. 站到离机关 10 米以上的地方。
2. 按住抵消蓄力约 1 秒后松开；之后 5 秒内什么键都不按，等角色自己停住。
3. 重复 3 次，屏幕显示「空挥 3/3」即完成。

目的：拿到没有怪、没有顿帧时 (2,23) 的完整时间线，以及霸体结束时刻 T_armor。
- 【第 1 轮 · A2 机关扫描（约 6~10 分钟）】
1. 站到机关正前方一步。
2. 打开 REF 菜单 →「自动放刀 rc」→ 勾选「机关扫描」→ 关闭菜单。
3. 按住抵消蓄力不松手：
   - 前 3 次机关出招时 mod 不放刀，用来认出机关、学节奏，这几下会被打到，由蓄力霸体硬吃；
   - 之后 mod 会在设定的时刻自己放刀。
4. 每次上捞斩出来以后，先松开键；等屏幕提示「重新按住」再按住。
5. 屏幕出现「扫描完成」就结束：有效样本满 24 个即完成，最多 10 分钟自动结束。

其他说明：
- 机关被麻痹、或你中途离开，都没关系，那一轮会自动作废并重新排队。
- 不用换武器。
- 这一段唯一的变量是 X，即「放刀 → 机关接触」的时间。
- 【第 1 轮 · B 真怪（不超过 15 分钟）】
1. 接一个单人任务，最好打 v1.3 实测时那只怪（日志里是 EmID 20）。
   - 不叫 NPC 支援猎人，不发救援信号，确认没有其他玩家加入；随从照常带。
   - 带够回复药。
2. 面向怪物按住抵消蓄力，让 mod 自己放刀：
   - 每次上捞斩出来以后，先松开，再重新按住；
   - 看到攻击来了，不要自己提前松手；
   - 要换位置时，先松手，再走或翻滚。
3. 屏幕第一次出现「自检2 x/y」时：红色就停下来告诉我；黄色就继续打。
4. 结束条件：屏幕显示「B 完成」（放刀 ≥45 次且有接触 ≥20 次），或者打满 15 分钟。怪物快死时可以先撤到别的区域。
5. 第一行的错误数一旦变红，立刻停下。
- 【第 1 轮 · 收尾】
1. 打开 REF 菜单 →「APCal」→ 点「写出数据」，再在「自动放刀 rc」里点一次「写出数据」。
2. 不要重启游戏，直接告诉我「好了」。
   - 如果游戏崩溃了：重启前先把 re2_framework_log.txt 复制到桌面，再告诉我。

我会读取：
- 日志里的 [AutoParryGS] 和 [APCal] 行；
- reframework/data 下的 APCal_*.json 和 AutoParryGS_*.json。
- 【离线 1：窗口与时序常数】
- 用扫描样本按 C1 求 W0、W1：可分时用中点法；重叠时用 logistic 拟合加 bootstrap；上方没有失败样本时按右删失处理。
- 用真怪的 CATCH 标签核对窗口。
- 从空挥数据得到 T_armor，算出 W1_eff。
- 求以下常数的中位数：
  - δ = t_start − t_req；
  - d̄ = L − R0；
  - β = 刀上接触 − 身体接触，只作描述。
- 用 PH 与首个刀上接触的帧差，加上当帧怪物的 DelayFrame，裁决 W0 的两种解释。
- 判断窗口跟随哪种时钟：对照 raw、chara、动画 Frame 三种计时，并按有无 EMHIT 分组。
- 【离线 2：残差、估计量与参数】
- 按 C2 计算有接触真放刀的 r_i；检查 r 与 R0 的相关性。
- 按 C3 求 L* 和留一招式交叉验证的 P_CV。
- 按 C4 求 L_min*，按 C5 求 W_long*。
- 按 C6 比较 V0、V1 和 α 的取值。
- 报告每个 L 档的实测接住率（附 Wilson 80% 区间），以及有效样本数（回合数、不同招式数）。
- 【离线 3：空放、漏报归因与闸门】
- 每个 DANGER 回合的结局分为 9 类：
  - 刀上抵消；
  - 身体命中；
  - 收尾挨打；
  - AI 转招（预测归零前 KeepActionID 已变）；
  - 被打断（进入受击类动作）；
  - 激活但没打中（有 ATK+、无接触）；
  - 激活未观测（无 ATK+）；
  - 目标不是我；
  - 弹体。
- 漏报分为 6 类：
  - 没收到消息；
  - 只有 CAUTION；
  - DANGER 首次出现时已低于 L_min；
  - 跨动作；
  - 被长窗口规则否决；
  - 被弹体或效果攻击规则排除。
- 按 C7 计算空放率 F；按 C8 评估闸门 g1~g7。
- 【离线 4：判定与退路】
- 按 C9 逐项判定。全部通过，就做 v1.5 终版（默认开启）。
- 不通过时，把数字和 A、B、C 三条退路交给用户选择。
- 补测只在命中 C10 的条件时进行。
- 【离线 5：简化项与文档】
- holder 对照：如果所有打我的回合在 holder 中的出现率都 ≥95%，终版改读 holder，删掉消息钩子和 add_ref。
- FB 兜底计数为 0，就删掉兜底。
- 核对以下几项：
  - ATK+ 的 args[4] 和 args[5] 哪个等于 RequestSetID；
  - EMPARRY 的参数对象与条目的 AttackParam 是否是同一个对象；
  - get_IsMaster 是否可用。
- 更正 docs/NOTES.md 中已证伪的结论，写入窗口实测值、T_armor 和 L 的依据。
- 【补测条件（预先写死）】
触发补测的情况：
- 关键错误数不为 0；
- 有接触的放刀少于 15 次；
- DANGER 回合少于 30 个；
- 日志和 JSON 都丢失。

补测只补 B 段（真怪约 10 分钟），不重做扫描。其他情况一律不追加测量轮。
- 【第 2 轮：验收】
1. 部署 v1.5 终版：参数冻结，不轮换，没有扫描；探针保留只记录的部分。
2. 用户按自己平时的配置（enabled 按长期使用的值）打两只出招风格不同的怪，各约 10 分钟：
   - 其中一只是新怪；
   - 至少一只关掉无限蓄力。
3. 按同一套结局分类验收：
   - 有接触的放刀接住率 ≥75%；
   - 空放 ≤25%；
   - 帧率与 v1.4 相同；
   - 用户确认伤害、火花、顿帧、弹开都是原生的。
4. 按怪分别报告覆盖率。
5. 滑块的每次改动都写进日志；验收只用第一次改动之前的数据。
- 【第 2 轮之后】
- 征得同意后：把探针移到 autorun_disabled，把 HitboxViewer 移回。
- 更新 README 的功能表，写明联机没有测过。
- 列出拟提交的内容，等用户在当轮明确同意后才做本地提交；push 和 PR 每一次都单独申请。

# PROBE SPEC
- **P01 加载自检与表头 HDR【核心】** | api: sdk.find_type_definition(name)、td:get_method(签名)、td:get_field(name):get_data(nil)【实测】；枚举名表沿用 AGPCall 写法：遍历 td:get_fields() 中 is_static() 的字段，取 get_data(nil)【实测】；json.load_file('AutoGuardGS.json') 和 json.load_file('AutoParryGS.json')【实测】；PlayerManager 的 get_field('_CurrentNetworkPosition')【MCP 实读过，Lua 待核实】；PlayerManager:get_Catalog():getWeaponActionParam(0) 下的 _GuardDegree、_AimGuardDegree、_ChargeParam_Parry._OverheatTime【v1.4 实测】；mcEnemyAttackAreaDetector 的静态字段 PLAYER_RADIUS、PLAYER_HEIGHT、DETECT_DISTANCE_SQ（get_data(nil)，读不到写 ?）【待核实】 | how: 加载时逐项核对本清单用到的类型、方法签名和字段：缺核心项 → 标红；缺可选项 → 关闭对应模块并标黄。

写一行 HDR，内容包括：
- 探针版本；
- 会话号 os.time()；
- 两个 mod 的全部配置；
- 当前防御角度和抵消蓄力的过热时间；
- NETWORK_POSITION；
- 关键枚举的数值，覆盖 RESULT_TYPE、PARRY_STATE、CollisionFilter.LAYER、Hit.RESULT、TARGET_ACCESS_KEY.CATEGORY、HitDef.DAMAGE_TYPE、STATUS_FLAG。
- **P02 帧时钟、时间健康度与 PERF【核心】** | api: re.on_pre_application_entry('UpdateBehavior', fn)、os.clock()【实测】；可选 via.Application 的 get_DeltaTime：单位按单样本推断为 1/60 帧，调用写法 sdk.call_native_func(sdk.get_native_singleton('via.Application'), sdk.find_type_definition('via.Application'), 'get_DeltaTime')【待核实】 | how: 每帧执行 f+=1，并算 dt=now−prev：
- dt>0.035 s 记一行 HITCH；
- dt>0.1 s 记一行 GAP。

每 5 s 写一行 PERF，内容：
- fps 和最大 dt；
- 各钩子每秒调用次数（含 activateAttack）；
- 每帧 Lua 耗时的均值和最大值（os.clock 只能作参考）；
- 跟踪对象数；
- 红、黄错误数。

fps 基线取加载后前 10 s 的中位数；之后下降超过 10% 时，在 HUD 上提示。
- **P03 错误分级与安全格式化【核心】** | api: pcall、string.format（Lua 5.4） | how: 每个模块各自用 pcall 包住。

错误分级：
- 核心模块 10 s 内出错 ≥3 次 → 标红，并提示「停下发日志」；
- 可选模块第一次出错 → 停用该模块，标黄。

前 20 条错误写成 ERR 行，限频每秒 1 行。

所有输出都走 safe_fmt：pcall(string.format) 失败时输出 'FMT_ERR '..fmt。浮点数一律用 %.1f 或 %.3f；凡是可能为 float 的值，都不许用 %d。
- **P04 预告消息 MSG 与对象跟踪【核心】** | api: sdk.hook(sdk.find_type_definition('app.cMasterPlayerControllerEntity'):get_method('receiveGameMessage(ace.cGameMessage)'), pre)，钩子里 msg=sdk.to_managed_object(args[3])，用 msg:get_type_definition():get_full_name()=='app.game_message.cMsgEmAttackAreaResult' 判断类型。对 r=msg:call('get_AttackAreaResult') 读取：get_TargetCharacter():get_address()、get_EmID、get_EmSystemIndex、get_KeepActionID():get_field('_Category'/'_Index')、get_ResultType、get_IsAttackFinished、get_DetectedDataList():call('get_Count')、get_MergedAreaData():get_field('AttackStartFrame'/'AttackEndFrame')、getClosestDetectedData；生命周期用 r:add_ref()/r:release()。以上【均实测】。msg:call('get_SendGameObject')【TDB 有，是否为怪物本体待核实】。同一个钩子里，cMsgParrySuccess 的 msg:call('get_State')【实测】。 | how: 每条消息到达时（包括同一对象的重发）立刻读一遍，写一行 MSG，字段：
- t、对象地址、target_me；
- 发送者名和地址；
- EmID#EmSystemIndex、KeepActionID；
- 整体类型、条目数、Merged 起止帧；
- closest 条目地址、fin。

对打我的结果：
- 新对象：add_ref 后登记，上限 32 条，满了就丢最旧的并 release；
- 已登记的对象：n_msg+1，t_msg=now。

释放条件与 rc 相同：
- IsAttackFinished；
- 全部条目 he<−30 且距 t_msg ≥1 s；
- 距 t_msg ≥8 s；
- 主角为 nil 或主角地址变化；
- 脚本重置。
- **P05 条目时间序列 SERIES/TYP【核心】** | api: list=r:call('get_DetectedDataList')、list:call('get_Item', i)【List`1.get_Item(Int32) 在 TDB 里有，Lua 待核实；失败时退回只读 closest 并标黄】；d:get_address()、d:call('get_ResultType')、d:call('get_HitStartRemainFrame')、d:call('get_HitEndRemainFrame')【返回 System.Single，已经通过 closest 实测】 | how: 对每个打我的、未结束的结果，每帧逐条读 (type, hs, he)。

采样密度：
- 本结果的最小 hs ≤90 时，每帧存一格；否则每 4 帧存一格；
- 遇到类型变化、hs 比上一格回跳超过 2 帧、条目增减，立即存一格，并写一行 TYP。

每格内容为 (t, f, 结果地址, 条目地址, type, hs, he, 主角是否在 (2,21)/(2,22))，只写进 JSON。离线据此重算任意 L、V0~V3、α 和各闸门的影子穿越。
- **P06 条目静态属性 ENT 与首次 DANGER 实物自检【可选】** | api: d:call('get_RequestSetID') 和 d:call('get_ShellIndex') 返回 Nullable，读 :get_field('_HasValue') 和 :get_field('_Value')（字段在 TDB 里有，Lua 返回形态待核实；备选 d:get_field('RequestSetID')）。ap=d:call('get_AttackParam')（类型 app.cAttackParamEm）上读 get_field('_GuardType'/'_DamageType'/'_DamageLevel'/'_AttackFilterType'/'_VersusGuardPower'/'_IsParryBreak'/'_IsParryFix'/'_IsParryStockOnly'/'_IsTechGuardBreak'/'_IsBlockEnable')（字段在 TDB 里有，语义待核实）。d:call('get_Obb'):call('get_Position') / ('get_Extent')（值类型调用待核实，失败就不记）。ap:get_field('_UserData'):call('get_Name')【待核实】 | how: 条目第一次出现时读一次，写一行 ENT，字段：结果地址:条目地址、序号、是否 closest，以及上面列出的各字段。

第一次出现 DANGER 时，对这个活对象逐项试读：get_Item、Nullable、AttackParam、Obb、getTarget、findEnemy_SystemIndex。结果以「自检2 x/y」显示在 HUD 上。
- **P07 主角动作、计时与霸体 ACT/ARM【核心】** | api: hunter:call('get_BaseActionController')；ctrl:call('get_CurrentActionID'):get_field('_Category'/'_Index')；ctrl:call('get_CurrentAction'):get_type_definition():get_full_name()【以上实测】；act:get_field('_RawTotalElapsedSecond')（偏移 0x50，MCP 实读值与日志一致；Lua 读法待核实，备选 act:call('get_RawTotalElapsedSecond')）；act:call('get_CharaElapsedSecond')（只有 getter、没有对应字段，语义待核实）；hunter:call('get_HunterStatus'):get_field('_HunterStatusFlag'):call('check(System.UInt32)', flag)【实测】 | how: 每帧读当前动作，有变化就写一行 ACT，字段：t、f、旧动作→新动作（ID 和类名）、离开旧动作时的 raw/chara、新动作首帧的 raw/chara。

在 (2,21)~(2,29) 期间及离开后 1.5 s 内，每帧读 SUPER_ARMOR、HYPER_ARMOR、NO_DAMAGE 三个标志，变化时写一行 ARM（附 raw），由此得到 T_armor 和尾段霸体情况。

本帧的 raw/chara 缓存起来，供钩子取用。
- **P08 放刀尝试 PT（含扫描样本）【核心；在线分类只供 HUD 显示，正式分类在离线做】** | api: 同 P07；按 os.clock 时间与 rc 的 FIRE/FIRE_END/SCAN 记录关联 | how: 每次进入 (2,23)/(2,24) 开一条 PT。

开头记录：
- t_obs、raw0，t_start=t_obs−raw0；
- 来源动作、按住时长、蓄力等级；
- 此刻所有打我的条目快照。

起因判定：
- 前一帧仍在 (2,21)/(2,22)，且距 rc 最后一次请求 ≤0.05 s → auto；
- 有对应的 SCAN 行 → scan；
- 否则 → manual。

之后一直汇总，直到离开 (2,23)~(2,29)，最长 4 s：
- 敌方接触、HP 损失、PH/PS、EMHIT；
- 进入 (2,25..27) 或 cRecoil 的时刻与档位；
- 霸体变化。

按 decision_rule 的 B 节做互斥分类，写一行 PT。空挥样本（10 m 内没有敌人接触，且松手后超过 3 s 无输入）单独计数。
- **P09 接触 CT【核心】** | api: sdk.hook(HunterCharacter:get_method('evHit_DamagePreProcess(app.HitInfo)'), pre, post)【实测】；info:call('get_AttackOwner') / ('get_DamageObj') / ('get_CollisionLayer') / ('get_AttackData')【实测】；层名用 enum_map('app.CollisionFilter.LAYER')【实测】；post 里 sdk.to_int64(retval) & 0xFFFFFFFF 映射到 app.Hit.RESULT【AGPCall 实测】；hunter:call('get_WeaponHandling'):call('get_ParryState')【实测】；攻击者 owner:call('getComponent(System.Type)', sdk.typeof('app.EnemyCharacter'))【实测】；另钩 HunterCharacter 的 evHit_ShellDamagePreProcess(app.HitInfo)，用 info:call('getActualAttackOwner') 取攻击者【TDB 有，语义待核实】；info:call('get_Position')【待核实，可选】 | how: 主玩家每次被敌方打中都写一行 CT，字段：
- t、f、本帧第几次；
- 攻击者名和地址、EnemyCharacter 地址；
- DamageObj 名、碰撞层；
- 前置 ParryState、后置 RESULT；
- 主角动作、raw/chara、霸体标志；
- 是否走弹体路径、命中点。

分类：
- BLADE：DamageObj 是武器 it0000_0002_0，且层为 ATTACK_PARRY_GET；
- BODY：层为 ATTACK_GET。
- **P10 HP 损失 DMG【核心】** | api: sdk.hook(HunterCharacter:get_method('evHit_Damage(app.HitInfo)'))：pre 记下 sdk.to_managed_object(args[2])；post 读 hunter:call('get_DamageInfo'):get_field('_TotalDamage') 和 get_field('_GuardReaction')【AGParry 实测】 | how: 每次伤害结算写一行 DMG，字段：t、总伤害、反应。

离线按攻击者和时间把 DMG 归到对应的 PT/EP，用来统计 CLEAN 和「接住但掉血」。机关扫描中的接住样本作为原生基线。
- **P11 抵消事件 PH/PS/PMSG/EMPARRY【PH/PS 核心，其余可选】** | api: Handling=sdk.find_type_definition('app.cHunterWeaponHandlingBase')，钩 onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3) 和 onParrySuccess(app.HunterDef.PARRY_STATE)：用 hunter:call('get_WeaponHandling'):get_address() 过滤出主角，状态取 sdk.to_int64(args[3]) & 0xFFFFFFFF【AGPState 实测】；cMsgParrySuccess:get_State【实测】；EnemyCharacter 的 evHit_AttackParry(app.HitInfo, app.cAttackParamEm)【AGPCall 实测】；怪物侧 enemy:get_field('_Context'):get_field('_Em'):get_field('Hit'):get_field('DelayParryInfo'):get_field('DelayFrame')【AGPCall 实测读过】 | how: 写以下几类行：
- PH：t、状态、目标、raw/chara、当帧怪物的 DelayFrame；
- PS：状态；
- PMSG；
- EMPARRY：cAttackParamEm 的地址。

离线用来回答：
- PH 与首个刀上接触是否同帧，用来裁决 W0 的两种解释；
- RECOIL 和 HIT 的出现频率；
- EMPARRY 的参数对象与条目的 AttackParam 是否是同一个对象。
- **P12 上捞斩砍中怪物 EMHIT【核心】** | api: sdk.hook(sdk.find_type_definition('app.EnemyCharacter'):get_method('evHit_DamagePreProcess(app.HitInfo)'))，只处理 info:call('get_AttackOwner'):get_address() == hunter:call('get_GameObject'):get_address() 的调用【AGPCall 实测】 | how: 只在 (2,23)~(2,29) 期间记录：t、raw/chara、dmgObj、层、怪物地址。

离线用途：
- 按「先砍中」和「先激活」分组，比较残差和窗口；
- EMHIT 之后 chara 与 raw 的差值，反映主角的顿帧时长。
- **P13 怪物状态 EMSTATE（动作、目标、速度、主从、位置）【可选，优先级高】** | api: 取怪物对象：优先每帧用 sdk.get_managed_singleton('app.EnemyManager'):call('findEnemy_SystemIndex(System.Int32)', idx)，再调 info:call('get_CharacterValid') / ('get_Character') / ('get_Pos')【TDB 本次核实，Lua 待核实】。不行再退回：从 P04 的发送者或 P09 的攻击者 GameObject 调 getComponent(app.EnemyCharacter)，并用 add_ref 缓存（AGPCall 实测写法），主角变化或换场景时 release。

当前动作：enemy:call('getCurrentAction()'):get_type_definition():get_full_name()【AGPCall 实测】。

目标：enemy:get_field('_Context'):get_field('_Em'):get_field('Target'):call('getTarget(System.Boolean, app.cEmModuleTarget.TARGET_ORDER)', false, 0)，返回 TARGET_ACCESS_KEY{Category, UniqueIndex}。_Context._Em 这段路径已实测；Target 字段和这个方法 TDB 本次核实，Lua 待核实。主角的键在正常抵消时实测为 PLAYER/0。

主从：enemy:get_field('_Context'):call('get_IsMaster')【TDB 本次核实，待核实】。

速度：enemy:call('calcMotionSpeedTotal(System.Boolean)', true 和 false 各读一次)、get_MotionSpeed_Action 等分量、enemy:call('get_GameObject'):call('get_TimeScale')【TDB 有，语义待核实】 | how: 对有未结束回合的怪物，每帧读一次动作类名，变化时写一行 EMSTATE。

在以下时刻各记一次目标键、速度、IsMaster 和位置：
- 回合第一次出现 DANGER 时；
- 每次 FIRE 时；
- 每次接触时。

离线用来：
- 区分「AI 转招」「被打断」「目标不是我」三类空放；
- 检验剩余帧的倒数速率是否跟随怪物速度。
- **P14 攻击判定激活 ATK【可选】** | api: sdk.hook(sdk.find_type_definition('app.ColliderSwitcher'):get_method('activateAttack(System.Boolean, System.UInt32, System.UInt32, System.Nullable`1<System.Boolean>, app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, System.Nullable`1<System.Single>)'))。第一行判断 (sdk.to_int64(args[3]) & 1)==0 就立即 return；拥有者取 sdk.to_managed_object(args[2]):get_field('_HitController'):call('get_Owner')【AGWarn/AGParry 实测】 | how: 只记敌方的调用：t、怪物、sdk.to_int64(args[4]) & 0xFFFFFFFF、sdk.to_int64(args[5]) & 0xFFFFFFFF。

离线用来：
- 判断哪个参数等于 RequestSetID；
- 判断回合内有没有 ATK+。没有 ATK+ 时记为「激活未观测」，不直接判定为「没出招」；
- 计算 ATK+ 与 hs 归零时刻的差。

每个回合记录这个模块是否全程开启；调用频率超过阈值时，钩子第一行直接 return。
- **P15 窗口候选信号 SIG 与动画时钟【可选】** | api: hunter:get_field('_HunterMotionSupporter'):get_field('_BaseBasicMotionSeq') 上读 get_field('_ParryImmdiate'/'_ActionFlag1'/'_ActionFlag2'/'_ActionFlag3'/'_WpUniqueFlag1'/'_SuperArmor'/'_HyperArmor'/'_NoHit')【字段 TDB 有，MCP 读到过实例】；hunter:call('checkHunterContinueFlag(app.HunterDef.CONTINUE_FLAG)', v)，v 取 PARRY_IMMDIATE、PARRY_COMBO、WP_ATTACK_COLLISION_ON【TDB 有，语义待核实】；hunter:call('get_Weapon'):get_field('_IsAttackColliderOn')【TDB 有】；动画时钟 via.motion.TreeLayer:get_Frame() / get_Speed() / get_MotionID()（TDB 本次核实），层对象的取法 hunter:call('get_GameObject'):call('getComponent(System.Type)', sdk.typeof('via.motion.Motion')):call('getLayer(System.UInt32)', 0)【待核实】 | how: 只在 (2,21)~(2,29) 期间及离开后 0.5 s 内每帧读取：
- 布尔量有变化时写一行 SIG，附 raw/chara/Frame；
- Frame 和 Speed 只写进 JSON。

离线判断：
- 是否有某个信号在 W0、W1 前后 1 帧内翻转；
- 窗口在 raw、chara、动画帧哪种时钟下最整齐。
- **P16 预告持有者对照 HOLD【可选】** | api: hunter:call('get_AttackAreaResult') 取得 mcHunterAttackAreaResultHolder；holder:get_field('_AttackAreaResultList'):call('get_Count') / ('get_Item', i)【TDB 有，待核实】 | how: 每 5 帧读一次列表长度和元素地址集合，有变化才写进 JSON。

EP 中写入本回合的对象在 holder 里出现的时间比例。只有全部打我的回合都 ≥95% 时，终版才改为读 holder。
- **P17 位姿与来向 POSE【可选】** | api: hunter:call('get_GameObject'):call('get_Transform'):call('get_Position') / ('get_AxisZ')【TDB 有，待核实】；怪物位置用 P13 的 get_Pos() 或怪物的 Transform；角度用 math.atan(y, x)（Lua 5.4 的两参数写法） | how: 在三个时刻记录：FIRE、PT 首帧、每次接触。内容：
- 主角位置和 AxisZ 的水平分量；
- 怪物根位置；
- 接触点；
- 水平夹角 θ = atan(f.x·v.z − f.z·v.x, f.x·v.x + f.z·v.z)，以及距离。

离线先用接触点 θ 的分布核实正负号，并确认 AxisZ 是否就是正前方。
- **P18 回合 EP【核心】** | api: 同 P04~P07 | how: 回合 =（结果对象, epoch）。

epoch+1 的条件：
- KeepActionID 变化；
- 同一对象收到新消息，且本 epoch 的最小 hs 已 ≤0；
- 任一条目的 hs 回跳超过 10 帧。

回合结束的条件：
- IsAttackFinished；
- 全部条目 he<−30；
- 距最后一条消息超过 8 s。

结算时写一行 EP（key=value），字段：
- id、em、发送者、keep；
- 开新 epoch 的原因、n_msg；
- 首次读数、类型变化序列；
- 倒数速率（−Δhs/Δt 的中位数、最小值、最大值，统计窗口 ≥0.1 s）；
- stall 帧数、max dt；
- 是否全程在蓄力中、ATK 模块是否全程开启；
- 关联的 FIRE。

接触的归属在离线按预注册规则做。
- **P19 rc 放刀日志 FIRE/FIRE_END/VETO/RES【核心，写在 AutoParryGS rc 里】** | api: log.info【实测】；json.dump_file('AutoParryGS_<会话>_<序号>.json', tbl)【实测】 | how: 日志行：
- FIRE：t_req、L（本次轮换值）、R0、he、条目地址、结果地址、em#idx、keep、src（V0 或 FB）、来源动作；
- FIRE_END：t、R1、请求帧数 n、是否进入 (2,23)；
- VETO：每个 streak 一行，记长窗口条目的 hs/he；
- RES：1.3 s 内进入 (2,25..27) 的档位和 dt，或 NOCATCH。

浮点一律用 %.1f 或 %.3f。同样的记录也写进 rc 自己的 JSON，写入规则和 P21 相同；这样日志被覆盖后，仍能区分自动放刀和手动放刀。
- **P20 rc 机关扫描 SCAN【rc 测试模式，默认关】** | api: rc 自己钩 HunterCharacter.evHit_DamagePreProcess（只在扫描模式下工作）：拿到第一个敌方攻击者的 GameObject，调 getComponent(app.EnemyCharacter) 并 add_ref【实测写法】。每帧读 enemy:call('getCurrentAction()'):get_type_definition():get_full_name()【实测】，类名用后缀 '%.cSmallAttack$' 匹配（完整名 app.Em0165_00Action.cSmallAttack 已在日志中出现）。放刀调用 hunter:call('changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)', 0, ACTION_ID(2,23), false)【实测】 | how: 1. 认机关：开扫描后，第一次敌方接触的攻击者就是机关。
2. 学习：前 2 个有效周期不放刀，记录 D_c = 首次接触时刻 − cSmallAttack 首帧时刻。
3. 调度：t_req = t0 + D_c − X − δ。δ 用自身实测的中位数，初值 0.012。到点且主角在 (2,21)/(2,22) 时就请求放刀，0.05 s 内每帧重试；主角不在蓄力中时，把这个 X 放回队列。
4. 作废，满足任一条即作废：
   - t0 到接触之间，机关出现了 cSmallAttack/cToSmallAttack 以外的动作；
   - 接触前主角换了动作；
   - 1.6 s 内没有接触；
   - [t_req, 接触] 区间内有一帧 dt>0.035 s。
5. 每个样本写一行 SCAN：X 目标值、t0、D_c、t_req、作废原因。
6. 完成后自动关闭扫描。

HUD 依次提示：等待机关出招 / 按住 / 重新按住 / 完成。
- **P21 持久化 JSON【核心】** | api: json.dump_file('APCal_<会话>_<序号>.json', tbl)【v1.4 保存配置已实测，写到 reframework/data】 | how: 只在三种时机写：
- 空闲帧（没有未结束的回合，且不在 (2,21)~(2,29)），并且距上次写入 ≥60 s；
- 点「写出数据」；
- re.on_script_reset。

每次只写新增的记录，只用基本类型：坐标拆成 x/y/z；地址存成十六进制字符串；NaN 和 inf 改成 null。写完检查返回值，失败计入核心错误。序号上限 300。
- **P22 HUD 与菜单【HUD 可选，菜单核心】** | api: re.on_frame 里 draw.text(text, x, y, color)【REF 自带 API，本项目没用过，待核实】；备选 re.on_frame 里 imgui.begin_window / end_window【HitboxViewer 实测用法，窗口 flags 待核实】；re.on_draw_ui 配合 imgui.tree_node / text / button / checkbox【实测】 | how: 屏幕角显示一行：当前阶段（自检 / 空挥 n/3 / 扫描 n/24 / B 段：放刀 n/45、接触 k/20、DANGER m）和红黄错误数。第一次 DANGER 出现时显示「自检2 x/y」。

菜单内容：错误详情、进度、「写出数据」按钮、「停止记录」开关。加载 90 分钟后自动停止记录。
- **P23 离线分析 tools/apcal_analyze.py【核心，部署前完成】** | api: Python 3.12（本机已装）。输入：re2_framework_log.txt 中的 [AutoParryGS] 和 [APCal] 行；reframework/data 下的 APCal_*.json 和 AutoParryGS_*.json | how: 实现 decision_rule 的 B 节结局分类、C1~C10 和 D 节，以及预注册的匹配规则：
- 攻击者相同；
- 接触时刻落在 [t_hs0−0.35 s, t_he0+0.30 s] 内；
- 有多个候选时取 |t−t_hs0| 最小的；
- 报告未匹配和有歧义的条数。

部署前先在 mock 输出上跑通。输出内容：
- 参数表；
- 每个 L 的覆盖曲线；
- 留一交叉验证结果；
- 空放和漏报归因表；
- 闸门评估（附评估过的候选数）；
- 可行性结论；
- 是否需要补测。

# IMPLEMENTATION
一、先问用户，一次列清
- 具体问题见 open_questions 第 1、2 条。
- 获得同意之前，不碰游戏目录，也不做 git 提交。

二、代码与工具（都在仓库里改，当前分支 feat/auto-offset-predict）

1. src/reframework/autorun/AutoGuardGS.lua 升到 v1.4.1，只改一处：
   - 受击钩子里，把 apply_angle() 改成 `local cat, idx = current_action(hunter); if not (cat == 2 and idx >= 21 and idx <= 29) then apply_angle() end`。
   - 头注释写明原因：刀上的抵消碰撞（ATTACK_PARRY_GET）会在同一帧、抵消结算之前进入这个钩子。改写角度既会混入测量，也可能让「全向抵消」成为 mod 造成的假象。
   - VERSION 改为 'v1.4.1'。
   - README 的防御角度说明补一句。

2. 新建 src/reframework/autorun/AutoParryGS.lua（rc，约 250 行；日志标签 [AutoParryGS]；配置文件 AutoParryGS.json）。
   - 常量：
     - PARRY_CHARGE={[21]=true,[22]=true}
     - SLASH_ID=make_action_id(2,23)
     - PARRY_HIT={[25]=true,[26]=true,[27]=true}
     - LEAD_MIN=18、LONG_WINDOW=60、VETO_HORIZON=90、CREDIT=1.3、TRACK_MAX=32、TRACK_STALE=8.0
     - RT_DANGER 和 DAMAGE_TYPE 中的 EAR/WIND/QUAKE 从枚举读取。
   - 配置：auto_parry=true、parry_lead=28、lead_rotation=true（只在 rc 中）、scan=false、debug_log=true。load_config 做类型校验，并把 parry_lead 夹到 20–45。
   - 预告跟踪：
     - 消息钩子用 pcall 包住，类型名不对就立即 return；需要的对象 add_ref。
     - cleanup(now) 每帧都调用，按 P04 的条件释放。
   - earliest(me)：遍历打我的、未结束的结果，用 get_Count/get_Item 逐条判断，返回最小 Q、对应条目和结果、veto 标志。逐条读取出错时，如果整体是 DANGER，就改用 closest，并计数 fb。
   - update(me)：
     - 独立 pcall；连续 30 帧出错就自停并标红；错误日志限频。
     - 不在 PARRY_CHARGE 时，结束 streak 并返回。
     - L 取 config.parry_lead；rc 轮换时取 ROT[i]。
     - 条件成立就调 changeActionRequest。用 streak 合并连续请求，记录 R0、R1、n。
     - 进入 (2,23) 后轮换前进一档；1.3 s 内进入 PARRY_HIT 时记 RES。
   - 扫描模式见 P20。
   - 菜单：开关、滑块（轮换期间只显示不可调）、轮换开关、扫描开关、统计（放刀/接住/否决/兜底）、调试日志、清零、写出数据。
   - HUD 一行。
   - re.on_script_reset、关掉开关、主角变化时，全部 release。
   - 中文注释写明三件事并附数据来源（会话记录行号或日志时间）：为什么逐条取最小 Q；为什么要有 L_min 和长窗口否决；为什么不用粘住。

3. 新建 probes/AutoParryCalib.lua（约 550 行，日志标签 [APCal]）。
   - 按 probe_spec 的 P01~P18、P21、P22 分模块。
   - 纯计算部分写成不依赖 sdk 的函数：epoch 切分、在线结局分类、θ。
   - 头注释写明「只记录，不修改游戏」。

4. probes/AutoParryPredictProbe.lua：头注释标明「作废：第 119 行用 %d 格式化 float」，以后不再部署。

5. 新建 tools/mock/：
   - mock_ref.lua：sdk、re、imgui、log、json、draw、ValueType 的桩。要能做到：返回 19.33 这样的 float、nil、无值的 Nullable、空 List；按设定抛异常；对象带地址；json 桩拒绝 NaN 和 userdata。
   - scenarios.lua，覆盖以下场景：
     - 两条条目 hs 不同；
     - 中途降级；
     - 长窗口否决；
     - remain=0；
     - 多个结果；
     - 机关空预告周期加扫描调度；
     - 手动放刀；
     - 空放；
     - 接住那一帧同时有身体接触；
     - 弹体条目；
     - 读取异常导致兜底。
   - run.lua：逐帧驱动 rc 和探针，并断言：
     - 不出现 ERR 或 FMT_ERR；
     - 只在 [L_min, L] 区间的第一帧放刀；
     - 否决生效；
     - 结局互斥；
     - JSON 能解析；
     - add_ref 和 release 成对。

6. 新建 tools/apcal_analyze.py（见 P23），先在 mock 输出上跑通。

7. 检查：
   - tools/check.sh，新文件也要通过；
   - mock 全部场景；
   - 用 MCP 只读 get_type 核对 probe_spec 中所有类型和方法名。

8. 部署（获同意后）：
   - 确认游戏 autorun 里没有 AutoParryPredictProbe.lua；
   - 把 HitboxViewer.lua 和 HitboxViewer/ 移到 autorun_disabled；
   - 运行 tools/deploy.sh；
   - 手动把 probes/AutoParryCalib.lua 复制到游戏 autorun。

三、第 1 轮实测
- 步骤见 measurement_plan。

四、离线分析
- 产出参数表和可行性结论。
- 更新 docs/NOTES.md：
  - 作废以下结论：误差小于 0.1 s；holder 未激活（改为待验证）；剩余帧就是距命中的时间；0.30–0.39 s 刀才有效；DANGER 只标给会打中的招；v1.3 的对手是 em27；(2,22) 未验证。
  - 补上调用顺序的第一步：evHit_DamagePreProcess 先于 evHit_AttackParry。
  - 写入窗口实测值、T_armor、空放归因，以及 L 取值的依据。

五、v1.5 终版（AutoParryGS.lua，约 150 行）
- 删掉轮换和扫描。
- 写入 L*、L_min*、W_long*，以及通过门槛的闸门（最多 2 个）。
- fb 计数为 0 就删掉兜底。
- holder 对照通过，就改读 holder，删掉消息钩子和 add_ref。
- IsMaster 核实通过，就加上联机闸门。
- 菜单标注「实验」，验收通过前默认关闭。
- 跑 check、mock 回归，然后部署。

六、第 2 轮验收通过后
- 更新 README 功能表：加上自动放刀一行，并写明联机未测试。
- 征得同意后：探针移到 autorun_disabled，HitboxViewer 移回。
- 按 AG 规范列出拟提交的内容，例如：
  - fix(autoguard): skip guard angle override during parry actions
  - feat(autoparry): add predictive offset slash release
- 等用户在当轮明确同意后才做本地提交；push 和 PR 每一次都单独申请。

# RISKS
- 有些接口只在真怪段才会第一次真正运行：逐条 get_Item、Nullable、AttackParam、OBB、getTarget、findEnemy_SystemIndex。只要其中一个出错，整轮测量可能作废。 => rc 逐条读取失败时，退回 closest，并计数。探针里可选模块第一次出错就自行停用、标黄；只有核心模块出错才标红。第一次出现 DANGER 时，对活对象做一次自检，结果显示在屏幕上。mock 覆盖 Lua 层面的错误。如果第 1 轮前用户恰好在打真怪，可以先用 MCP 只读核对 Nullable 和 OBB 的内存布局。
- 空放率高：预告标了 DANGER，攻击却没来（AI 转招、没出手、在打随从）。 => 规则本身宁漏勿放：逐条取实时 DANGER，读数要落在 [L_min, L]，并否决长窗口。第 1 轮按 9 类结局做归因；闸门按预注册门槛加，最多 2 个；空放率超过 25% 时，按预先写好的三条退路交给用户选。
- 攻击早到，c_first < W0（多段攻击的前段、提前量偏小、怪物加速）。结果是身体先挨打（有霸体），没有抵消，蓄力也丢了。 => L 对准窗口中部，而不是下沿。L_min 由残差的下四分位数推出。α 和速度缩放先作为影子候选，有数据支持再用。
- 攻击晚到，或空放后角色进入没有霸体的收尾段（实测会停到玩家有输入为止，约 3.4~3.8 s）。 => 测 T_armor，取 W1_eff = min(W1, T_armor−0.05)。长窗口的 DANGER 即将到来时否决放刀。「收尾挨打」单独统计。菜单和说明里提醒：没撞上就松开再按。
- 抵消窗口受几何位置或顿帧影响，单一 L 对一部分招式偏早或偏晚。 => 对照 raw、chara、动画帧三种时钟，并按「是否先砍中」和来向分组。差异超出门槛时接受成功率上限，走退路 A 或 B，不按招式单独建模。
- 上捞斩约 0.32 s 时会先砍中怪物，造成冻结或打断，从而改变攻击到达的时刻。 => L 只用真放刀的残差来定，r 对 R0 做线性校正。INTERRUPTED 单独成类，结果按「计入」和「不计入」两版报告。
- 刀接触后得到 RECOIL 或 HIT（抵消力不够），或者怪物没有被弹开（弹开是累积型状态）。 => RECOIL 单独分类，不算作时机误差。事先告诉用户：接住不保证每次都弹开怪物。
- 弹体、咆哮、风压、震动类攻击触发了放刀。 => 这类条目默认跳过；读取失败时放行（fail-open）并计数。探针另钩 evHit_ShellDamagePreProcess，用 getActualAttackOwner 判断攻击者。
- 机关扫描大量作废（麻痹、cDamageParry、用户来不及重新按住）。 => 自动作废并重新排队；每个 X 最多尝试 3 次；扫描总时长封顶 10 分钟。如果大 X 的样本全部作废，W1 改用真怪样本给出下界。
- 测量本身弄脏时序：钩子分发的开销、写 JSON 造成卡帧。 => 只钩低频函数。activateAttack 的调用量超过阈值时，钩子第一行直接 return。JSON 只在空闲帧写，两次间隔 ≥60 s。dt>0.035 s 的样本做标记，分析时剔除。征得同意后，测量期间停用 HitboxViewer。
- 数据丢失：重启游戏会覆盖 re2_framework_log.txt。 => rc 和探针都另写一份 JSON。收尾时提醒用户先别重启游戏；如果游戏崩溃，重启前先复制日志。
- 跨帧持有对象，引发访问冲突或崩溃。 => 预告结果对象 add_ref 持有，按规则 release；主角为 nil、主角地址变化或换场景时全部 release。怪物对象优先每帧用 findEnemy_SystemIndex 重新取。只有低频钩子做写操作；有副作用的调用只有 changeActionRequest 一个。
- 与 v1.4 互相干扰：角度改写，以及 enabled 开关的语义。 => v1.4.1 在抵消动作族里不改写角度。HDR 记录两个 mod 的配置；每一轮用什么配置，写死在测量协议里。
- 联机，或怪物是副本：预告要等网络包，速度被同步调整。 => 测量全程单人。v1.5 加 _Context.get_IsMaster() 闸门，第 1 轮核实后启用。README 写明联机未测试。
- 选参过拟合，或看完数据才定匹配规则。 => 规则在部署前写死，并用 mock 数据跑通。用留一招式交叉验证。闸门最多 2 个，且要过绝对计数门槛。报告一共评估了多少种候选组合。
- AGPCall 实验探针仍驻留，会伪造抵消。 => 第 1 轮第一步就点 Reset Scripts；Reset 之前不测抵消。
- 用户负担过重或误操作。 => 屏幕上用一行字提示下一步该做什么。不要求换武器。B 段有明确的结束条件。C 段移到第 2 轮。
- 通用性不足：有的怪或招式没有预告数据，或屏蔽了玩家，或 DANGER 来得太晚。 => 没有预告时 mod 不动作，效果等于没装。第 2 轮按怪物报告覆盖率。把「通用」表述为「对有预告数据的招式通用」。

# OPEN QUESTIONS
- 【需要你决定】下面三项改动，同意吗？
① 测量期间把游戏 autorun 里的 HitboxViewer.lua 和 HitboxViewer/ 暂时移到 autorun_disabled，第 2 轮后移回。原因：它也钩了 activateAttack，还在缓存对象上触发过一次访问冲突。
② 用 tools/deploy.sh 部署两样东西：新文件 AutoParryGS.lua（rc），以及 AutoGuardGS.lua v1.4.1（只改一处：抵消动作里不改写防御角度）。
③ 把 probes/AutoParryCalib.lua 复制进游戏 autorun，第 2 轮后移走。
- 【需要你决定】要不要先把工作区里未提交的 v1.4（README、NOTES、AutoGuardGS.lua）本地提交，作为基线？做法：切到 main，提交 feat(autoguard): ...；再切回 feat/auto-offset-predict，快进合并 main。不推送。
- 【可以等数据出来再定】如果第 1 轮达不到门槛（接住 < 75% 或空放 > 25%），你更倾向哪条退路？
- A 保守模式：只对单段、短窗口、DANGER 持续够久的招放刀，放得少但更准；
- B 提示模式：不自动放刀，只在屏幕上提示松手时机，由你自己放；
- C 留作默认关闭的实验开关。
- 第 1 轮数据要回答的问题（你不需要额外操作）：
- W0、W1、T_armor 各是多少；
- W0 的两种解释哪个成立：窗口约 0.355 s 才打开，还是刀约 0.31 s 就有效、只是怪物端延迟确认；
- 残差 r 的分布，以及它与 R 的关系；
- 空放来源的比例，以及各闸门的真实收益；
- ATK+ 的哪个 UInt32 等于 RequestSetID；
- Nullable、OBB、AttackParam、getTarget、findEnemy_SystemIndex 在 Lua 里的调用方式；
- holder 列表是否持有同一批活对象；
- 倒数是否跟随怪物速度和顿帧变化；
- RECOIL 和 HitS/M/L 的出现规律；
- get_CharaElapsedSecond 的语义；
- 从 (2,22) 放刀的占比。
- 第 2 轮才能回答：换一只出招风格不同的怪，参数是否依然成立；按怪统计的覆盖率，即预告缺失、屏蔽玩家、DANGER 来得太晚各占多少。
- 本计划不回答、留待以后：联机或副本怪物时的表现；怪物大招能否打穿 (2,23) 的 SUPER_ARMOR；小怪的 DANGER 是否需要单独关掉（目前按通用处理，并按怪物类别分别报告）。

# DROPPED
- 墙钟「粘住」外推：v1.3 在 DANGER 降级后，按 last_s − Δt×60 继续倒数并触发放刀 : 唯一能核对的样本是 (0,72)，攻击早到 0.13~0.20 s，但这个偏差来自实时读数本身，不是外推造成的。没有一次成功是靠它触发的。它还会把降级（可能正说明这一招不会打中）变成一次放刀。保留为影子估计 V3，只记录不触发。
- 只看 getClosestDetectedData : 有多个检测体时，closest 与时间最早的那条对不上。但「closest 取错段导致早到」并未证实，所以不宣称改掉它就能修复早到。V1 作影子对照，同时用作读取失败时的兜底。
- 用 ATK+（ColliderSwitcher.activateAttack）触发放刀 : 从判定激活到接触只有 0.05~0.17 s，比窗口起点约 0.30 s 还短，物理上来不及。
- 钩 onParryHitPreProcess : 抵消蓄力时它每秒被调用 6~18 万次，实测帧率掉到 22 fps。
- 受击时强行抵消、重放保存的 HitInfo、自己请求命中特效 : 强行抵消没有上捞斩本身的伤害、火花和顿帧，用户判定太假；重放 HitInfo 会崩溃；自己请求的特效画面上不出现。
- 按怪物或按招式建立时机表 : 违背「通用」和「简单」两条要求。
- 把 NPC 时机表里的 Startup=45 直接当作 L : 这 45 帧包含 NPC 点按蓄力的时间和 AI 延迟；我们的场景是已经按住、只差松手。
- 用实测的倒数速率换算剩余时间（原 U4） : 倒数是名义计时：(0,72) 的倒数并没有变快，攻击却提前到了。改为影子候选 g6，即按怪物总速度缩放。
- 600 行的三模式探针，外加必做的被动挨打段和手动抵消段 : 工作量和出错面太大。被动挨打的样本在真怪段里会自然出现；要求手动松手反而会造成选择偏差。
- 在探针里在线计算各候选 L 的影子穿越 : 改为离线从 SERIES 重算任意 L。探针只记原始量，代码更简单，也更不容易出错。
- 每积累 10 条记录就自动写一次 JSON : 会在测量途中卡帧，污染时序。改为空闲帧写入（间隔 ≥60 s），加上手动按钮和 reset 时写入。
- 运行时记「同一招只放一次」的状态 : Q 单调递减，只会穿过触发区间一次，不需要额外状态。
- 用 0.95·max U 选 L，并以「回放与真放刀相差 ≤25pp」检验模型 : 前者在 max U ≤ 0 时没有定义；后者的检验功效只有约一半。改为取最大覆盖平台，配合留一招式交叉验证，再逐次检查一致性。
- L 只按 24/30/36 三档轮换 : 改为 {20,24,28,32,36} 五档、每组内乱序。20 是唯一有 2/2 实测成功的值，必须保留作对照；五档覆盖更宽，乱序也能避免与怪物连招节奏同相。
- 把扫描的 X 扩到 1.2~1.4 s : 那需要在 cSmallAttack 开始之前就放刀，而出招周期有 ±0.07 s 的抖动，无法精确锚定。W1 ≥ 1.0 s 时按右删失处理已经够用。
- 第 1 轮加第二只怪（C 段），并要求换一把没有异常属性的大剑 : 用户负担过重。第二只怪放到验收轮；麻痹导致的周期由程序自动作废。
- A 段补 5 次短按样本 : EMHIT 时刻在 LV1~3 下一致，上捞斩动画与蓄力等级无关；第 2 轮关掉无限蓄力后，自然会有短按样本。
- 以「干净接住」（不掉血）作为主指标 : 原生手动抵消成功的那一帧里，也会同时出现身体接触（16:12:47.045）。主指标改为接住；CLEAN 单独报告，并与机关上的原生基线对比。
- 缓存怪物请求集碰撞体的层统计，用来判断这一招能否被抵消 : 相关接口未核实，开销也大。先用攻击参数标志和结局数据来判断。
- 把 rc 写进 AutoGuardGS.lua，共用同一个帧回调和钩子 pcall : 一旦出错，会连带取消自动肩撞，自动防御也会悄悄失效。改为独立脚本，回滚时只需删一个文件。
- 把机关扫描放在探针里 : 违反项目「探针只记录」的约定。改放到 rc 的测试模式里。
- 终版直接改读 holder 列表 : holder 的语义还没验证；要等第 1 轮对照通过才换。
- 运行时用 CAUTION 条目，或降级后锁存的条目触发放刀 : 未经验证，会增加空放。只做影子 V2 记录和 CAUTION 记录。
- rc 默认打开 120° 背后闸门 : AxisZ 的正负号还没核实，一旦弄反，会在测量轮挡掉所有正面攻击。第 1 轮核实后，作为 v1.5 的候选闸门 g2。
- 把提示模式当主方案 : 用户要的是自动放刀；提示模式只作为退路之一。
- 以「怪物被弹开」作为成败标准 : 怪物弹开是累积型状态（CONDITION.PARRY），不是每次接住都会弹开。成败按是否进入 (2,25..27) 统计。

# CRITIQUE RESOLUTION
- 【机制-1 机关窗口不能代表真怪】部分采纳。扫描窗口仍用来定参，但必须先通过真怪核对：真怪有接触的放刀按 CATCH 标注，若与扫描窗口 ±0.03 s 的一致率 < 80%，改用真怪标签，并与扫描窗口取交集。P20 改为扫描时自己轮询机关动作，不再依赖回合。残差只用真放刀算，「先砍中」「先激活」的影响已包含在内，另对 R 做线性校正。轮换中保留 L=20 作对照。没有把扫描降为「仅作先验」：真怪的 c_first 分布本身取决于 L，单靠真怪标签定不准边界。
- 【机制-2 ±0.07 s 被夸大，r 很宽】采纳。降级为「em20 一招，n=2」。r 改用真放刀的经验分布，允许为负。删除「L=30 两侧各留 0.15 s」的论证。可行性第②条若不通过，按 C9 预先写好的 A/B/C 退路处理。
- 【机制-3 倒数是名义计时】部分采纳。可选模块在消息、放刀、接触三个时刻记录 calcMotionSpeedTotal(true/false)、各速度分量和 TimeScale。速度缩放改为闸门候选 g6，只有残差 IQR 缩小 ≥20% 才采用。rc 不实现。
- 【机制-4 新规则没覆盖空放主因】采纳。主张改写为「只排除长窗口和 remain≈0 两类」。空放归因列为第 1 轮的主产出，分 9 类。「没有 ATK+」改记为「激活未观测」。闸门候选加入：目标是我、7 m、DANGER 持续帧数、KeepActionID 一致性。样本目标提到放刀 ≥45 次、有接触 ≥20 次。空放率超过 25% 时的退路预先写死。
- 【机制-5 TargetCharacter 就是接收者】采纳。删除无法实现的「目标是别人」归因。改为读怪物 _Context._Em.Target.getTarget(false, FIRST)，与 PLAYER/0 比较；正常抵消时主角的键已实测为 PLAYER/0（本次在日志 16:12:47.046 复核）。作为闸门候选 g1。
- 【机制-6 结局不只成功与失败】采纳。结局分类加入 RECOIL，来源为 onParrySuccess 的状态、cMsgParrySuccess、cRecoil 动作。CATCH 按进入 (2,25..27) 统计，并记录 HitS/M/L 档位。验收说明里写明：怪物是否弹开取决于累积值，不保证每次都弹开。
- 【机制-7 弹体与效果攻击】采纳。rc 和 v1.5 默认跳过 ShellIndex 有值的条目，以及 EAR/WIND/QUAKE 类；读取失败时放行（fail-open）并计数。探针另钩 evHit_ShellDamagePreProcess，并用 getActualAttackOwner 认攻击者。只有数据里出现「弹体 + 刀上接触 + 成功」才放开。
- 【机制-8 朝向与 OBB 中心】部分采纳。放刀帧记录 AxisZ、怪物根位置、接触点，OBB 能读时再记最近角点。120° 闸门作为 v1.5 候选 g2：先用接触点角度分布核实正负号，再按门槛决定是否采用。不放进 rc，因为正负号一旦弄反，会在测量轮挡掉所有正面攻击。
- 【机制-9 最小 hs 与 closest】采纳。不再宣称 V0 能修复早到。记录 RequestSetID 并与 ATK+ 匹配；V0 与 V1 用留一招式的残差 IQR 来定（C6）。
- 【机制-10 (2,22) 已验证】采纳。本次在会话记录中复核到 14:57:01.594 有一条「request #1 accepted=true | (2,22) cParryCharge」，计划中「未验证」的说法已删除。
- 【机制-11 联机】部分采纳。HDR 记录 NETWORK_POSITION，EP 记录怪物 _Context.get_IsMaster()（TDB 本次核实存在）。v1.5 在核实后加上「副本怪不放刀」闸门，核实不了就在 README 中写明。本轮不测联机。
- 【机制-12 空放代价与 CREDIT】采纳。A1 空挥测 T_armor，W1_eff 取 min(W1, T_armor−0.05)。CREDIT 放宽到 1.3 s。窗口按 PH 和 c_first 分析，不按进入 Hit 动作的时刻。
- 【机制-13 W_long 的依据有误】采纳。依据已更正，W_long 重新定位为安全阀，只许往保守方向调。
- 【机制-14 通用性】采纳。表述改为「对有预告数据、且对玩家开放的招通用」。第 2 轮按怪报告覆盖率。真怪在场时可以用 MCP 只读统计 AttackAreaParam，不占用户轮次。
- 【机制-15 放刀路径成立】确认，保持不变。
- 【机制-16 只有刀上碰撞才触发抵消；另建议统计 ATTACK_PARRY_PUT】前半确认。统计碰撞体层的建议暂缓：怪物请求集碰撞体的接口没核实，开销也大，本轮先用攻击参数标志加结局数据。
- 【机制-17 零点等于判定开始】确认语义，但不把它当作「零点很准」。
- 【机制-18 用 PH 裁决 W0 的两种解释】采纳。PT 记录 PH 相对首个刀上接触的时刻，以及当帧怪物 DelayParryInfo.DelayFrame。机关被抵消后下一帧就进 HitL，没有这层延迟，可作对照。
- 【测量-1 验收链会给自己打分】采纳。具体措施：
- 结局互斥，接住优先；
- 补钩弹体路径；
- 第 2 轮保留只记录的探针，参数冻结，滑块改动写进日志，只用改动前的数据；
- 用留一招式交叉验证代替同批自评；
- L_min* 和 W_long* 只许往保守方向调；
- L* 改为最大覆盖平台的中点，任何情况下都有定义；
- 每项只设一个门槛。
没有采用前后半拆分：样本太少，留一招式更省样本。
- 【测量-2 v1.3 的空放照样会出现；(0,72) 早到是实时读数本身的偏差】采纳。更正了归因；r 允许为负。空放门槛不达标时给用户的取舍已预先写好（C9）。空放归因列为主产出。
- 【测量-3 影子回放的反事实未经检验】采纳。具体措施：
- 回放只用全程在蓄力中的回合；
- L* 只由真放刀的残差决定；
- 影子数据只用来估空放率和评估闸门，只看有没有接触，不看接触时刻；
- 报告有效样本数，包括回合数和不同招式数；
- 「接触区间与窗口是否重叠」作为一致性检查的辅助诊断。
- 【测量-4 25pp 检验的功效只有一半】采纳。改为逐次一致性检验，不一致数 ≤ max(2,10%)，预先写死。L 改为 {20,24,28,32,36} 五档，每 5 次一组、组内乱序。日志同时记档位 L 和实际 R0、R1，分析以 R0 为自变量。
- 【测量-5 扫描设计】大部分采纳：
- 以 c_first 为横轴，按可分/重叠两种情况估计；重叠时写死用 logistic + bootstrap；
- 右删失照实报告；
- 两条边界都有细化预算；
- 麻痹和 cDamageParry 的周期自动作废。
驳回两点：
- 不把 X 扩到 1.2~1.4 s：超过约 1.05 s 就要在 cSmallAttack 开始之前放刀，周期抖动 ±0.07 s，无法锚定；而 L≤45 时 c 约 ≤0.8 s，W1 右删失在 1.0 s 已经够用；
- 机关上做不出「上捞斩没砍中」的对照：改用真怪样本和动画时钟来回答这个问题。
- 【测量-6 机关周期数字】采纳。改为不抵消 4.6 s、抵消后 7.0 s，时长按 6~10 分钟告知。
- 【测量-7 计时基准】采纳。本次 MCP 复核：_RawTotalElapsedSecond 是真字段（0x50）；get_CharaElapsedSecond 是没有字段的计算 getter，语义未知。加记动画层 Frame/Speed（TreeLayer.get_Frame/get_Speed 在 TDB 中存在，取层对象的写法待核实）。卡顿阈值改为 dt>0.035 s。另检验 hs 下降斜率与怪物速度是否一致。
- 【测量-8 混杂因素】大部分采纳：
- v1.4.1 在抵消动作族里不改写角度；
- HDR 记录两个 mod 的全部配置和当前角度；
- B 段要求不要手动提前松手；
- 回放只用全程在蓄力中的回合；
- PT 记录按住时长和蓄力等级。
驳回「A 段补 5 次短按」：EMHIT 时刻在 LV1~3 下一致，上捞斩动画与等级无关；第 2 轮关掉无限蓄力后自然会有短按样本，不值得增加负担。
- 【测量-9 停表规则自相矛盾】采纳。改为两级：核心模块出错标红、要求停止；可选模块第一次出错就自停该模块、标黄、继续。
- 【测量-10 闸门的多重比较】采纳。闸门必须同时满足：有机制解释、去掉 ≥4 次、损失 ≤1 次；最多 2 个。报告评估过的候选总数；置信区间按招式分组做 bootstrap。INTERRUPTED 预先定义，并给出计入与不计入两版。
- 【测量-11 匹配规则要预注册】采纳，部署前写进 apcal_analyze.py。规则：
- 攻击者相同（发送者或攻击者的 EnemyCharacter 地址，退一步用 EmSystemIndex）；
- 接触落在 [t_hs0−0.35 s, t_he0+0.30 s] 内；
- 多个候选时取 |t−t_hs0| 最小的；
- 报告未匹配数和有歧义数；
- RequestSetID 只作附加证据。
- 【测量-12 (2,22) 已验证】采纳，同机制-10。
- 【测量-13 PT 与 FIRE 的关联】采纳。FIRE 记首次请求的 R0 和时刻；FIRE_END 记被接受那一帧的 R1、请求帧数 n 和时刻。关联条件改为「前一帧仍在 (2,21)/(2,22)，且距最后一次请求 ≤0.05 s」，不再用固定 30 ms。rc 同时写 JSON，日志被覆盖后仍能区分自动和手动放刀。
- 【测量-14 空放的定义】采纳。改为「到 he 归零 + 0.3 s 都没有接触」；晚于这个时刻的接触归入 FAIL_LATE。
- 【测量-15 JSON 写入与 ATK 钩子】部分采纳。写入时机改为「空闲帧、间隔 ≥60 s」，外加按钮和 reset 时写；没有采用「下一条预告剩余 >90 帧时写」，因为效果相近而规则更复杂。每个回合记录 ATK 模块是否全程开启；没有全程开启时，「没出招」和「没打中」一律记为未知。
- 【测量-16 放刀路径成立】确认。
- 【测量-17 旧探针】已不需要处理。本次核实：游戏 autorun 里从 18:25 起已没有 AutoParryPredictProbe.lua，autorun_disabled 里也没有；部署前再确认一次。仓库里的副本在头注释标为作废。
- 【测量-18 ATK+ 来不及】确认。
- 【安全-1 v1.4 改写角度】采纳。v1.4.1 在 (2,21)~(2,29) 中不调用 apply_angle()；HDR 和 PT 记录 _GuardDegree。这样也保证了「真实」：抵消的方向判定不会被 360° 放大。
- 【安全-2 空放代价被低估】大部分采纳：
- 本次复核：(2,23) 从 f4469 停到 f4794（约 3.4~3.8 s），之后挨打被转成精确防御，说明尾段没有霸体；
- 测 T_armor；
- 「收尾挨打」单独统计，一直统计到离开 (2,23)，上限 4 s；
- 长窗口 DANGER 在 1.5 s 内到来或正在进行时否决放刀；
- 空放 ≤25% 设为硬门槛。
没有采用「凡会落进无霸体段就否决」：只有空放才会进入尾段，而空放事先无法预测。
- 【安全-3 干净接住】部分采纳。记录每次的 HP 损失（evHit_Damage 后置读 _TotalDamage，AGParry 实测可用），单独报告 CLEAN，并与机关上原生接住的基线比较。主指标仍用 CATCH：手动抵消成功的那一帧本来就会有身体接触（16:12:47.045），以 CLEAN 为主会把原生行为也判成失败。
- 【安全-4 1+1 轮过于乐观】采纳：
- 错误分两级；
- rc 逐条读取失败时退回 closest；
- 第一次 DANGER 时做实物自检并显示在屏幕上；
- 补测条件预先写死，只补真怪段约 10 分钟；
- 不向用户承诺一定 1+1。
- 【安全-5 扫描按规格实现会不工作】采纳：
- 扫描放进 rc，独立轮询机关动作，不依赖回合；
- 先认机关，再学 2 个周期；
- 每个 X 最多尝试 3 次；
- 上限 36 个样本或 10 分钟；
- 麻痹周期自动作废；
- mock 里的机关只发 fin=true 的空预告；
- 时长按 6~10 分钟告知用户。
- 【安全-6 rc 塞进 v1.4 的 pcall】采纳。rc 改为独立脚本 AutoParryGS.lua，有自己的配置、钩子和 pcall；连续出错就自停并标红，日志限频。v1.4 只改角度那一处。回滚时删这一个文件即可。
- 【安全-7 PERF 守卫】采纳。守卫改为「调用次数 + fps 下降」，不用钩子体耗时。第一条 PERF 报告 activateAttack 每秒调用次数。征得同意后测量期间停用 HitboxViewer。SIG 这类连续量只写 JSON。
- 【安全-8 崩溃风险】大部分采纳：
- 主角为 nil、主角地址变化或换场景时，全部 release；
- 怪物对象优先每帧用 EnemyManager.findEnemy_SystemIndex 重新取（TDB 本次核实，Lua 待核实），不行再退回 AGPCall 实测过的 add_ref 缓存。
预告结果对象仍然 add_ref 跨帧持有：这是机制本身需要的，v1.3 和 AGWarn 已实测长时间稳定。
- 【安全-9 (2,22) 已验证】采纳，同机制-10。
- 【安全-10 DeltaTime 的单位】采纳为工作假设：单位是 1/60 帧（单样本）。继续记录核对，不再列为标定目标。
- 【安全-11 默认值与开关】采纳：
- 每轮的配置写死在协议里；
- 自动放刀有独立开关；
- v1.5 的滑块范围用 [L_min*, 45]；
- 验收通过前 v1.5 默认关闭，并标「实验」；
- rc 在测量时打开。
- 【安全-12 JSON 细节】采纳：只写基本类型；NaN 和 inf 替换掉；检查返回值；写入间隔 ≥60 s；文件数设上限；游戏崩溃时先复制日志。
- 【安全-13 第 2 轮的探针去留与扫描放在哪】采纳。第 2 轮之后把探针移到 autorun_disabled（征得同意）；探针加载 90 分钟后自停。扫描直接放进 rc 的测试模式，符合项目「探针只记录」的约定，不再单独问用户。
- 【安全-14 用户负担】采纳：
- 屏幕显示一行提示；
- 不要求换武器；
- B 段设明确的结束条件；
- C 段移到第 2 轮；
- 不要求用户一直开着菜单。
- 【安全-15 放刀路径、低频钩子、引用安全】确认。
- 【安全-16 旧探针与 AGPCall】采纳。第 1 轮第一步先点 Reset Scripts，卸掉仍驻留的 AGPCall；Reset 之前不测抵消。旧探针已不在 autorun（同测量-17）。

# SCORES
[
 {
  "name": "minimal",
  "authenticity": 5,
  "robustness": 4,
  "simplicity": 5,
  "testability": 4,
  "safety": 4,
  "notes": "选作主干。真实性 5：只在帧开头用 changeActionRequest 放 (2,23)。稳健性 4：触发规则是「逐条取 DANGER 中最小的剩余帧，落在 [L_min, L] 区间才放，跳过判定窗口很长的条目」，同时修掉了 v1.3 的三个误触发来源：closest 取错段、墙钟粘住外推、remain=0 时立即放刀。规则不依赖墙钟和帧率，空放少、宁可漏放。扣分点在窗口测量：要靠用户在机关前手动早松、晚松，W1 只能粗略框住。简单性 5：运行时代码约 70–90 行，没有跨帧状态；之后要不要加功能，每一级都有数据门槛。可测性 4：测试版用的就是正式代码，再加 L 轮换，所以第 1 轮直接验证要发布的代码；探针只记原始事件、匹配放到离线做，避开了旧探针的匹配 bug。但 W1 测不准，有可能还要第 3 轮。安全性 4：只钩低频函数。两个隐患：fs.write 没核实过，出错时会悄悄丢掉存档；终版直接换成 holder 列表读取，这条路也没验证。"
 },
 {
  "name": "window-model",
  "authenticity": 5,
  "robustness": 3,
  "simplicity": 3,
  "testability": 4,
  "safety": 4,
  "notes": "真实性 5。参数推导是三个方案里最好的：显式窗口模型给出 L=60·(δ+(Pon+Poff)/2−a) 和 S_lo=60·(δ+Pon−a)，第 1 轮的实测值可以直接代进去。窗口测量也最好：在机关前按时间自动放刀扫描，只改 X 一个变量，几分钟就能拿到 W0/W1。稳健性只给 3，因为运行时默认打开了几项没验证过的东西：降级后继续锁存、跳过弹体和效果攻击、第 2 轮起的角度门限；epoch 和锁存又让规则带上了状态，出 bug 的面变大。简单性 3：参数和开关最多，有 L、S_lo、span_max、Θ 和三个开关。可测性 4：扫描很高效，但真怪只按固定的 L=28 放刀，其他 L 只有影子数据，端到端验证不够。安全性 4：探针会请求动作，用的是和 v1.3 相同的 API；钩子都是低频的，跟踪对象有 32 条上限。"
 },
 {
  "name": "experiment-first",
  "authenticity": 5,
  "robustness": 4,
  "simplicity": 2,
  "testability": 5,
  "safety": 3,
  "notes": "真实性 5。数据最全，判定标准最清楚。它测机关扫描、被动挨打、手动放刀和 A/B，离线回放 6 种变体，用效用函数和 Wilson 区间定参数，并给出明确的可行/不可行阈值。另外用 t_start=t_obs−elapsed 消掉了 1 帧误差，还有 mock 预检、自检和模块自动停用。这些都值得嫁接进来。简单性 2：探针约 600 行、三种模式，再加 mock 框架和 Python 回放，工作量和出错面都最大；运行时「同一招只放一次」这个状态其实用不上。可测性 5：一轮就能拿到几乎所有的量，mock 预检也降低了整轮白跑的概率。代价是第 1 轮要用户操作约 20 分钟、分四段（光被动挨打就要 15 次以上），负担最重。安全性 3：钩子和每帧读取最多；虽然有自动停用和 PERF 守卫，但每积累 10 条记录就自动 json.dump_file 一次，可能在测量途中卡帧，把时序数据弄脏。"
 }
]

# CRITIQUE SUMMARIES
[
 {
  "key": "mechanics",
  "summary": "反方（游戏机制怀疑者）结论：方案的执行路径可以保留。放刀在帧开头用 changeActionRequest 请求 (2,23)，抵消靠刀上 ATTACK_PARRY_GET 的真实碰撞完成，这两点都有实测支撑。但支撑参数和验收线的几条机制假设证据不足，有的与已有日志矛盾。\n\n主要问题：\n1. 抵消窗口不只由时间决定。抵消碰撞体挂在扫动的大剑上；机关只有一种固定高度的小招，而且每个扫描样本都先砍中机关、带着猎人顿帧。怪物端还有两层影响：延迟确认（requestDelayParry，MaxDelayFrame=10），以及从类型名推断的受击冻结（_ShockAbsorberFreezeRequests）。机关上量出的窗口不能直接套到真怪。\n2. 「HitStartRemainFrame 零点 = 判定开始」这一语义成立，但「误差 ±0.07 s 已验证」只来自 em20 同一招 2 次。全部已核对样本：ATK+ 相对零点 −0.20～+0.09 s，接触相对零点 −0.24～+0.16 s；em27 (0,126) 的接触落在判定窗口末尾，比开始晚约 0.3 s。所以「L=30 两侧各留约 0.15 s 余量」不成立，可行性第②条很可能不过。\n3. 怪物动作速度由 Random、CoreState、ScaleAdjusted、Replica、WaitPacket 等分量合成（类型实读）。(0,72) 的倒数没有加快，攻击却早到 11–16%（弱证据，n=1）。推断倒数是名义计时；U4 用「实测倒数速率」测不出这类误差，应改为按 calcMotionSpeedTotal 缩放。\n4. 新规则只排除了长窗口和 remain≈0 两类，空放的主因没覆盖到。v1.3 的 3 次空放里只有 (0,9) 会被排除；em27 的 (0,7)、(0,87) 根本没出招，(0,125) 在判定开始前就转招了。用已有 16 个 DANGER 回合粗算，空放约一半，「空放 ≤20%」大概率达不到，需要事先定好出口。\n5. TargetCharacter 其实就是接收者：≥36 条全为 true；发送目标是 PLAYER、OTOMO、PORTER 三类（枚举实读）。主角收不到「打别人」的预告，所以「换了目标」这一类无法归因。应改读怪物 cEmModuleTarget.getTarget。\n6. 抵消结局不止成功和失败。PARRY_STATE 和 ParryResultCheck 都有 HIT、SUCCESS、RECOIL 三种；游戏里存在 cRecoil 和抵消力上限；怪物被弹开是累积型 CONDITION.PARRY。现有分类会把 RECOIL 当作时机误差甚至空放。\n7. 投射物：类型名显示远程攻击的抵消是个别怪专门打开的（Em0009 ENABLE_PARRY_LONG_RANGE_ATTACK），应默认跳过带 ShellIndex 的条目。\n8. 朝向：蓄力中可以用集中模式转身（cChargeBase 的 AimTurn 系列字段），而条目的 OBB 可能是合并后的扫掠框，所以 U2 用 OBB 中心算方位不可靠。\n\n另外：\n- 从 (2,22) 放刀已有 1 次实测被接受，计划说「没验证过」，不对。\n- 联机下非主机端的怪物是 replica，有等包和同步变速。用户当前就在在线集会（NETWORK_POSITION=LOBBY，本次实读），应记录这些信息，并在联机时默认关闭自动放刀。\n- W_long 的依据引用了几处错误样本。\n- (2,23) 0.654 s 以后的霸体没验证，放晚了可能比不装 mod 更糟。\n\n成立的部分：放刀路径、只有刀上碰撞才触发抵消、零点语义、W0 的两种解释都需要靠 PH 时刻裁决。\n\n资料与方法：\n- 会话记录 C:/Users/Administrator/.claude/projects/C--Users-Administrator/90a8713d-bb90-4a39-8099-7d734a12da62.jsonl（第 2311、2553、2658、2779、2789、2850 行），以及 scratchpad 里已抽出的片段。\n- 游戏日志 C:/Program Files (x86)/Steam/steamapps/common/MonsterHunterWilds/re2_framework_log.txt。\n- v1.3 源码（git show 485f1ba）、docs/NOTES.md、probes/AutoGuardWarnProbe.lua。\n- reframework MCP 已连上，只用了 get_tdb、help、get_type、search_types、get_singleton、summary。\n- 枚举常量用 scratchpad 里的 enumdump.ps1 只读解析 C:/Program Files (x86)/Steam/steamapps/common/MonsterHunterWilds/reframework/plugins/managed/generated/REFramework.NET.application.dll。\n- ida-pro-mcp 连接失败，方法体都没有反编译。\n- 没有改任何文件，没有部署，没有动 git 状态，也没有启停任何进程。",
  "refuted": [
   "只看 TargetCharacter==我 的预告就够；P04 把「不打我的」预告写进 JSON，离线就能归因「换了目标」",
   "从 (2,22) 发起放刀请求没验证过"
  ]
 },
 {
  "key": "measurement",
  "summary": "结论：这份方案的测量设计比旧探针好很多，包括逐接触记录、PT/CT 分类、时间健康度检查和影子穿越。但几条关键的统计主张站不住，照现在的写法会变成自己给自己打分。\n\n**最严重：验收链本身会作弊（critical）。**\n- 第 2 轮允许边打边拖 L，而且只用 mod 自带的计数器。\n- 这套计数器会把一次成功的抵消同时记成「没接住」。日志里已经实测到这种情况：16:12:47.045 f1056，抵消成功的同一帧里还有一次身体 ATTACK_GET 接触。\n- 第 1 轮的门槛是在同一批数据上选完参数后再拿同一批数据自评。\n\n**其他问题：**\n1. 新规则消除不了 v1.3 实际出现过的空放。(0,47) 那次在新规则下会原样再放一刀。方案把一次实时读数的 −0.19 s 偏差归到了「墙钟粘住」头上，这个归因是错的。\n2. 「影子回放效率高一个数量级」不成立。它用的反事实模型（接触时刻固定、点接触、身体接触加 β）没有检验过。\n3. 「每档 10 次就能发现 25 个百分点的偏差」：这道检验的功效只有大约一半。\n4. 机关扫描用的中点法，遇到多帧接触、成功失败重叠或右删失时没有定义；样本预算只够细化一条边界；扫描内部也没有「上捞斩没砍中机关」的对照组。\n5. `CharaElapsedSecond` 没有对应字段，语义不明。要判断窗口是不是跟着动画时间走，应该直接读动作层的 Frame。\n6. 混杂因素：\n   - v1.4 在 `enabled=false` 时，仍会在每次被敌方打中时（包括抵消那一帧）把共用的防御角改成 360；\n   - 配置在两次实测之间被切换过，却没写进表头；\n   - 武器带麻痹，会让机关周期作废。\n7. 「错误数不为 0 就立即停」这条规则有冲突：预告相关的读取在机关上一次都不会执行，要到真怪段才第一次运行，任何一个可选字段出错都会让整轮白跑。\n\n**事实更正：**\n- 机关周期实测是没被抵消约 4.6 s、被抵消后约 7.0 s，不是方案写的 2.4 s / 5.2 s。\n- 从 (2,22) 发起放刀请求，v1.3 已经成功过 1 次。\n\n**成立的主张：**\n- 放刀请求 5 次都是第一次就被接受，下一帧进入 (2,23)。\n- 旧探针在 autorun 里、还没被加载过，第 119 行用 %d 格式化浮点数会报错。\n- 用 ATK+ 触发放刀在物理上来不及。\n\n**核查范围与操作（全程只读）：**\n- 读过的资料：\n  - 仓库里的 v1.4 源码、探针、NOTES；\n  - git show 出的 v1.3 源码；\n  - 游戏 autorun 目录和 AutoGuardGS.json；\n  - re2_framework_log.txt；\n  - 会话转录 jsonl 第 2311、2779、2789、2850 行。\n- reframework MCP：连接正常，只用了 get_type 和 search_types。\n- 临时文件：只往 scratchpad 写了几个分析用的临时文件。另有一个误写到 %TEMP% 的临时文件，已经删除。\n- 没有改动仓库、游戏目录和 git 状态。",
  "refuted": [
   "验收与定参的整条链：第 1 轮在 L* 处用可行性第③④条判定（有接触的放刀接住≥80%、空放≤20%、真放刀与回放差≤25pp）；第 2 轮部署不带探针的 v1.5，按菜单统计验收，并且「放得偏早或偏晚，直接拖 L 滑块，同一局里再试」；rc 版统计规则：1.0 s 内进 (2,25..27) 算接住，1.2 s 内主角在 (2,23) 被 ATTACK_GET 打中算没接住",
   "「逐条取 DANGER 中最小的 hs + 只在 [L_min,L] 区间放 + 跳过长窗口」三条合起来，一次修掉 v1.3 的三个误触发来源；「墙钟粘住外推：唯一能核对的样本里，攻击比外推早到 0.13~0.20 s」；r 可能在 0~0.2 s 之间",
   "真放刀三档（24/30/36）每档 ≥10 次，足以发现回放与实测相差 25 个百分点以上的系统偏差；第⑤条「两者相差不超过 25 个百分点就认为模型可信」",
   "机关没被抵消时约 2.4 s 出一次招，被抵消后 cDamageParry 约 5.2 s，攒 30 个样本约需 3~4 分钟",
   "从 (2,22) 发起放刀请求还没验证过（所以只在 (2,21) 中判定更稳妥，如果 (2,22) 不被接受，终版只在 (2,21) 中生效）"
  ]
 },
 {
  "key": "safety-ux",
  "summary": "从安全、性能、体验三个角度逐条核查后的结论如下。\n\n**站得住的主干**\n- 放刀只在帧开头调用 changeActionRequest。v1.3 放过 5 次（其中 1 次从 (2,22) 出发），每次都是第一次请求就被接受。\n- 新增钩子都是低频的。实测 PERF/PROF：消息钩子每秒 80–94 次；受击和抵消相关钩子每秒 0–3 次；帧回调每秒 4–13 ms。\n- add_ref/release 有 REF 兜底。多余的 release 只打一行警告；方法调用里出现的访问冲突会被截住，转成 Lua 错误。\n\n**6 个重要问题**\n1. v1.4 的防御角度改写对刀上的抵消碰撞同样生效，而且发生在同一帧的抵消结算之前。用户当前把角度设成 360，测量会被它混淆。\n2. 空放的代价被低估了。实测 (2,23) 没撞上时会停留约 3.5 秒，收尾段没有霸体，挨打后被 v1.4 转成了精确防御。现在的规则对长窗口攻击和其它 DANGER 条目只做「排除」，不会阻止放刀；统计也只看放刀后 1.2 秒。\n3. 成功判据没有排除「抵消成功，但同时掉血」。手动抵消成功的那一帧里就出现过 MasterPlayer/ATTACK_GET 的接触。\n4. 「1 轮标定 + 1 轮验收」过于乐观：\n   - 14 个接口从没在 Lua 里调用过；\n   - 训练机关的预告恒为空，所以 DetectedData 相关路径在 A 段根本执行不到，要到真怪的 B 段才第一次运行；\n   - 规则又规定「出现任何错误，整轮作废」。\n5. 机关扫描照规格实现会不工作：P18 只读还有未结束回合的怪物，而机关的回合一登记就结束。另外 X 没有重试上限，所需时长也被低估了。\n6. rc 版准备把代码插进 v1.4 现有的 pcall 里。新代码一出错，会取消自动肩撞、让自动防御失效，日志还会刷屏。\n\n**次要问题**\n- os.clock 量不到钩子分发的开销；activateAttack 的调用频率从没测过。\n- HitboxViewer 仍在运行：它钩了同一个函数，还在缓存的 cEnemyBrowser 上触发过访问冲突。\n- 「从 (2,22) 发起的请求没验证过」这一说法不对，已经验证过。\n- via.Application.get_DeltaTime 的单位已经可以推断出来，是 1/60 秒。\n- 各轮的配置、开关语义、滑块范围都需要写死。\n- JSON 落盘，以及崩溃后如何保住日志，需要补流程。\n- 第 2 轮前没有把探针移出 autorun 的步骤。\n- 要求用户边按住蓄力边盯 REF 菜单，负担过重。\n\n**另外两件事**\n- 带 %d bug 的旧探针确实需要移走。\n- 强行抵消的实验探针 AGPCall 仍驻留在当前 Lua 状态里，必须先点 Reset Scripts 才能开始测。\n\n**本次用到的资料（全部只读）**\n- MCP 只用了 get_type 和 search_types。\n- 读了仓库文件，游戏目录下的 autorun 脚本、配置、HitboxViewer，re2_framework_log.txt，以及会话记录 jsonl。\n- 没有修改任何文件。",
  "refuted": [
   "v1.4 与自动放刀和测量互不干扰：抵消蓄力和上捞斩前段都有霸体，v1.4 只会 skip: armor。方案以 v1.4 为基线，测量轮不改它的受击逻辑。",
   "机关扫描：「用 P18 读机关的动作类名」，前 2 个周期学习 D_c，约 3–4 分钟攒满 30 个有效样本后自动退出；作废的 X 放回队列；类名待核实。",
   "「从 (2,22) cParryCharge 发起放刀请求没验证过」（参数表和失败模式里都这样写）。"
  ]
 }
]

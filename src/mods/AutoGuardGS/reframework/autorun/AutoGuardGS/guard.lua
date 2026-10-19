-- AutoGuardGS/guard：自动防御（原 AutoGuardGS v1.4.2，逻辑不变；每一条都在探针里验证过）
--
-- 被怪物打中、伤害结算之前（HunterCharacter.evHit_DamagePreProcess），打开角色状态标志里的防御标志：TECHNICAL_GUARD →
--   精确防御，GUARD → 普通防御。方向、体力、削伤、防御反应全部由游戏按自己的规则处理；结算完（evHit_Damage 之后）关掉。
--   为什么不预判举剑：同一时刻「会打中」和「打不中」的判定框距离曲线一模一样（实测），误触发无法消除；
--   受击时判定只在真的打中时才触发，对任何怪、任何招式都通用。
-- 能不能举剑：已拔刀 + 问游戏行为表能否到达防御动作 + 动作属性黑名单（翻滚、倒地等）。霸体中不防御，交给霸体硬吃。
-- 自动肩撞：蓄力中挨打（蓄力霸体照常硬吃），下一帧起向动作控制器请求切成肩撞，游戏原生出肩撞，之后能接下一级蓄力。
--   经验（实测）：「改状态」可以在受击结算中途做；「改动作」必须在帧开头请求，不能中途硬切。
-- 防御角度：Wp00ActionParam 的 _GuardDegree / _AimGuardDegree（全角，70 = 正前方左右各 35 度），所有大剑共用（包括 NPC
--   支援猎人），所以只在主玩家这一下的结算期间临时改写，结算完立刻还原；抵消动作族 (2,21)~(2,29) 里不改写。
--   还原有三处兜底：结算后、每帧开头、Reset。
-- 【测试】无限蓄力：7 种蓄力参数的 _OverheatTime 改成极大值（同样所有大剑共用）；关开关、换武器、主角消失、Reset 都还原。
-- 【测试】锁血：游戏扣血分两步，受击时 cHunterHealth.requestDamage 登记、之后 update 里结算。锁血时对主玩家在登记这一步
--   跳过原函数，另外每帧把血补满兜底（覆盖不走 requestDamage 的扣血）。被打的反应动作照常。
--
-- 对外（new 的返回值）：ready（初始化成功）、tick、restore_hit_state、restore_overheat、draw、draw_tests
local LIB = "AutoGuardGS.lib."
local ref = require(LIB .. "ref")
local patch = require(LIB .. "patch")
local Player = require(LIB .. "wilds.player")
local Action = require(LIB .. "wilds.action")
local Weapon = require(LIB .. "wilds.weapon")
local Hunter = require(LIB .. "wilds.hunter")
local Enemy = require(LIB .. "wilds.enemy")
local K = require("AutoGuardGS.const")

local WEAPON = Weapon.TYPE.LONG_SWORD   -- 游戏内部名 LONG_SWORD = 大剑（太刀是 TACHI）
local GUARD_TYPES = { "精确防御", "普通防御" }
local GUARD_FLAG_NAMES = { "TECHNICAL_GUARD", "GUARD" }
local ANGLE_FIELDS = { "_GuardDegree", "_AimGuardDegree" }
-- 【测试】无限蓄力改的 7 种蓄力参数（Wp00ActionParam.cCharge）
local CHARGE_PARAM_FIELDS = { "_ChargeParam", "_ChargeParam_Strong", "_ChargeParam_Spirit", "_ChargeParam_Parry",
                              "_ChargeParam_Fly", "_ChargeParam_Sliding", "_ChargeParam_BattleRide" }
local INFINITE_OVERHEAT = 99999.0
-- 肩撞 ID 跟蓄力等级走（实测）：开始蓄力 / 一段蓄力 → (2,15)，强蓄力 / 真蓄力 → (2,17)
local CHARGE_TO_TACKLE = { [5] = 15, [6] = 15, [7] = 17, [11] = 17 }   -- 分类 2 内：蓄力动作编号 -> 肩撞编号
local TACKLE_ACTIONS = { [15] = true, [17] = true }
local TACKLE_TIMEOUT = 0.3

local M = {}

-- ctx：config、stats（菜单统计）、L（lib/log）、prof（lib/prof）
function M.new(ctx)
    local config, stats, L, prof = ctx.config, ctx.stats, ctx.L, ctx.prof
    local G = { ready = false }
    local ready = false         -- init 成功才为 true；失败时防御整块不工作，放刀照常（MERGE 1.5）
    local init_err = nil
    local HunterCharacter, HunterHealth, T_CharacterBase = nil, nil, nil
    local GUARD_FLAGS, EXISTING_GUARD_FLAGS, ARMOR_FLAGS = nil, nil, nil
    local CANCEL_INDEX_INVALID, GUARD_ACTION_ID = nil, nil
    local BLOCKED_ATTRS = {}

    local forced = nil          -- { flags = 标志组, list = 我们打开的标志 }
    local angle_defaults = nil  -- 游戏原值 { _GuardDegree = 70, _AimGuardDegree = 70 }
    local angle = patch.new()   -- 受击结算期间对防御角度的改写
    local overheat = patch.new()   -- 无限蓄力对 _OverheatTime 的改写；active = 生效中
    local tackle = nil          -- 进行中的肩撞请求 { id, deadline, tries }
    local master_health_addr = nil   -- 锁血：主玩家 cHunterHealth 的地址，每帧开头更新；钩子里拿 this 的地址和它比，只拦主玩家

    local function gs_action_param() return Weapon.action_param(WEAPON) end

    local function ensure_angle_defaults()
        if angle_defaults then return true end
        local param = gs_action_param()
        if not param then return false end
        angle_defaults = {}
        for _, f in ipairs(ANGLE_FIELDS) do angle_defaults[f] = param:get_field(f) end
        L.info(string.format("game guard angle: %.1f (aim %.1f)", angle_defaults._GuardDegree, angle_defaults._AimGuardDegree))
        return true
    end

    local function current_angle()
        return config.guard_angle or (angle_defaults and angle_defaults._GuardDegree)
    end

    local function apply_angle()
        -- 已经改过还没还原（同一帧连续挨打）：别再保存一次，否则会把改过的值当成原值
        if angle:active() or not ensure_angle_defaults() then return end
        local deg = current_angle()
        local param = gs_action_param()
        if not deg or not param then return end
        angle:begin()
        for _, f in ipairs(ANGLE_FIELDS) do angle:set(param, f, deg) end
    end

    -- 【测试】无限蓄力。_OverheatTime：蓄满后再按住这么久就「过热」自动放出（实测原值：普通 / 强 / 真蓄力 3 秒，抵消蓄力
    -- 2.5 秒）。生效条件：开关打开且主玩家拿着大剑，否则还原。
    -- 不只在「蓄力动作中」才改：游戏可能在进入蓄力时就读走这个值，等进了蓄力再改会晚一帧。
    -- 代价：这份参数所有大剑共用，生效期间 NPC 支援猎人的大剑也会无限蓄力（测试开关，可接受）。
    local function apply_infinite_charge()
        if overheat:active() then return end
        local param = gs_action_param()
        if not param then return end
        overheat:begin()
        for _, name in ipairs(CHARGE_PARAM_FIELDS) do
            local c = param:get_field(name)
            if c then overheat:set(c, "_OverheatTime", INFINITE_OVERHEAT) end
        end
        L.debug(string.format("infinite charge ON (%d params)", overheat:count()))
    end

    function G.restore_overheat()
        if not overheat:active() then return end
        overheat:restore_each()
        L.debug("infinite charge OFF (restored)")
    end

    -- 自动肩撞。走过的弯路（都实测过）：受击结算中途 changeActionImmediate 切成肩撞，进入流程被跳过，动画和超级霸体都
    --   没跟上；虚拟按住防御键，按了 28 帧游戏都没反应（蓄力中出肩撞不走这个键）。
    -- 现在的做法：每帧开头请求，由动作控制器在当帧按正常流程处理，和游戏自己出招是同一条路。挨打后的顿帧期间请求可能被拒，
    --   所以每帧重试，直到进了肩撞或超时（实测都是第一次就成功）。和自动放刀互不干扰：肩撞只从 (2,5)/(2,6)/(2,7)/(2,11)
    --   出，放刀只从 (2,21)/(2,22) 出，两段读的是同一个快照，同一帧最多一个动作请求
    local function charge_index(hunter)   -- 钩子里用：现读动作
        local cat, idx = Player.current_action(hunter)
        if cat == 2 and CHARGE_TO_TACKLE[idx] then return idx end
        return nil
    end

    local function request_tackle(hunter, charge_idx)
        if tackle then return end
        local idx = CHARGE_TO_TACKLE[charge_idx]
        tackle = { id = Action.id(2, idx), deadline = os.clock() + TACKLE_TIMEOUT, tries = 0 }
        L.debug(string.format("tackle requested -> (2,%d) | %s", idx, Player.action_text(hunter)))
    end

    -- 每帧开头推进（用帧开头的动作快照）：直到进了肩撞 / 超时 / 已不在蓄力
    local function update_tackle(hunter, cat, idx)
        if not tackle then return end
        if cat == nil or idx == nil then   -- 动作 ID 读不到：清掉请求（v1.4.2 在这里抛错进 pcall 再清掉，结果一样）
            tackle = nil
            return
        end
        if cat == 2 and TACKLE_ACTIONS[idx] then
            stats.tackled = stats.tackled + 1
            L.debug(string.format("tackle OK after %d requests | %s", tackle.tries, Player.action_text(hunter)))
            tackle = nil
            return
        end
        if os.clock() > tackle.deadline then
            L.debug(string.format("tackle TIMEOUT after %d requests | %s", tackle.tries, Player.action_text(hunter)))
            tackle = nil
            return
        end
        -- 已经不在蓄力了（比如被打倒、自己放了斩击）：不再强行肩撞
        if not (cat == 2 and CHARGE_TO_TACKLE[idx]) then
            L.debug("tackle CANCELLED, no longer charging | " .. Player.action_text(hunter))
            tackle = nil
            return
        end
        local accepted = Action.request(hunter, tackle.id)
        tackle.tries = tackle.tries + 1
        if tackle.tries == 1 or accepted then
            L.debug(string.format("tackle request #%d accepted=%s | %s", tackle.tries, tostring(accepted),
                Player.action_text(hunter)))
        end
    end

    -- 还原受击钩子里改的东西（标志和角度都不许跨帧）。只还原状态，和 REF 的 release（扣引用）无关
    function G.restore_hit_state()
        angle:restore()
        if forced then
            for _, f in ipairs(forced.list) do Hunter.flag_off(forced.flags, f) end
            forced = nil
        end
    end

    -- 受击：结算前打开防御标志
    local function on_damage_pre(args)
        if not ready then return end
        local ok, err = pcall(function()
            local hunter = sdk.to_managed_object(args[2])
            if not hunter:call("get_IsMaster") then return end
            if hunter:call("get_WeaponType") ~= WEAPON then return end
            if not Enemy.is_enemy(sdk.to_managed_object(args[3]):call("get_AttackOwner"), T_CharacterBase) then return end

            -- 角度对手动防御同样生效，所以先于开关判断。例外：抵消动作族 (2,21)~(2,29) 里不改（v1.4.1）。刀上的抵消碰撞
            -- （ATTACK_PARRY_GET）也会走进这个钩子，而且在同一帧的抵消结算之前（日志 16:12:47.045 实测）；这时改写共用的
            -- 防御角度，会混进自动放刀的结果，也可能造成 mod 导致的「全向抵消」假象
            local cat, idx = Player.current_action(hunter)
            if not (cat == 2 and idx >= 21 and idx <= 29) then apply_angle() end

            if not config.enabled then return end

            -- 蓄力中：不防御（蓄力霸体会硬吃），改为挨打后自动肩撞
            local charge_idx = charge_index(hunter)
            if config.auto_tackle and charge_idx then
                request_tackle(hunter, charge_idx)
                return
            end

            local flags = Hunter.status_flags(hunter)
            if Hunter.any_flag(flags, EXISTING_GUARD_FLAGS) then
                stats.already_guarding = stats.already_guarding + 1
                return
            end
            if config.respect_armor and Hunter.any_flag(flags, ARMOR_FLAGS) then
                stats.skipped_armor = stats.skipped_armor + 1
                L.debug("skip: armor | " .. Player.action_text(hunter))
                return
            end

            local reason = Hunter.why_cannot_guard(hunter, Player.master(), GUARD_ACTION_ID, CANCEL_INDEX_INVALID,
                BLOCKED_ATTRS)
            if reason then
                stats.skipped_state = stats.skipped_state + 1
                L.debug("skip: " .. reason .. " | " .. Player.action_text(hunter))
                return
            end

            local f = GUARD_FLAGS[config.guard_type]
            Hunter.flag_on(flags, f)
            forced = { flags = flags, list = { f } }
            stats.guarded = stats.guarded + 1
            L.debug("guard forced: " .. GUARD_FLAG_NAMES[config.guard_type] .. " | " .. Player.action_text(hunter))
        end)
        if not ok then
            L.warn_err("pre", err)
            local ok2, err2 = pcall(G.restore_hit_state)
            if not ok2 then L.warn_err("pre", err2) end
        end
    end

    -- 结算完关掉我们打开的标志、还原角度
    local function on_damage_post(retval)
        if ready then
            local ok, err = pcall(G.restore_hit_state)
            if not ok then L.warn_err("post", err) end
        end
        return retval
    end

    -- 【测试】锁血：登记伤害（受击扣血）和红血伤害时，对主玩家跳过原函数
    local function block_master_damage(args)
        if not ready or not config.lock_health or not master_health_addr then return nil end
        local ok, hit = pcall(function() return sdk.to_int64(args[2]) == master_health_addr end)
        if ok and hit then
            stats.damage_blocked = stats.damage_blocked + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        return nil
    end

    -- 每帧兜底：血不满就补满（覆盖不走 requestDamage 的扣血）
    local function update_lock_health(hunter)
        if not config.lock_health then
            master_health_addr = nil
            return
        end
        local health = hunter:call("get_HunterHealth")
        master_health_addr = health and health:get_address() or nil
        local mgr = health and health:call("get_HealthMgr")
        if not mgr then return end
        local hp, max = mgr:call("get_Health"), mgr:call("get_MaxHealth")
        if hp and max and hp < max then mgr:call("set_Health(System.Single)", max) end
    end

    -- 帧开头（快照之后）：锁血兜底、无限蓄力开关、推进自动肩撞。
    -- 快照读到一半抛错（rok 为 false）时照 v1.4.2 自己再读一遍，只读这一帧用得到的、顺序同 v1.4.2：主角；武器只在无限蓄力
    -- 开着时读；动作只在有肩撞请求时读。为什么不直接跳过这一帧：快照比 v1.4.2 多读武器、动作控制器，这几项出错时 v1.4.2
    -- 照常补血、照常还原 _OverheatTime，跳过的话关开关后的还原要拖到故障结束（审查修订；mock 场景 guard_read_fault、
    -- guard_tackle_read_fault）。
    -- 自己读也抛错时由 tick 清掉肩撞请求，同 v1.4.2 的「帧出错」
    local function guard_frame(rok, hunter, gs, cat, idx)
        if not rok then hunter = Player.hunter() end
        if not hunter then
            tackle = nil
            master_health_addr = nil
            G.restore_overheat()
            return
        end
        update_lock_health(hunter)
        if not rok then gs = config.infinite_charge and hunter:call("get_WeaponType") == WEAPON end
        if config.infinite_charge and gs then apply_infinite_charge() else G.restore_overheat() end
        if not rok and tackle then cat, idx = Player.current_action(hunter) end
        update_tackle(hunter, cat, idx)
    end

    function G.tick(rok, hunter, gs, cat, idx)
        local ok, err = pcall(guard_frame, rok, hunter, gs, cat, idx)
        if not ok then
            L.warn_err("frame", err)
            tackle = nil
        end
    end

    -- 查类型、读枚举、注册 4 个钩子（顺序同 v1.4.2）。整个包在 pcall 里：失败只停防御（ready = false），放刀照常；
    -- 已经注册上的钩子第一句先看 ready
    local function init()
        HunterCharacter = ref.type("app.HunterCharacter")
        local STATUS_FLAG = ref.type("app.HunterDef.STATUS_FLAG")
        local ACTION_ATTR = ref.type("app.HunterDef.ACTION_ATTR")
        T_CharacterBase = ref.need(sdk.typeof("app.CharacterBase"), "typeof app.CharacterBase")
        local function flag(name) return Hunter.status_flag(STATUS_FLAG, name) end
        GUARD_FLAGS = { flag("TECHNICAL_GUARD"), flag("GUARD") }
        -- 已经在防御（手动防御、肩撞的判定点防御等）就不用我们插手
        EXISTING_GUARD_FLAGS = { flag("GUARD"), flag("TECHNICAL_GUARD"), flag("GUARD_POINT"), flag("POWER_GUARD") }
        ARMOR_FLAGS = { flag("SUPER_ARMOR"), flag("HYPER_ARMOR") }
        local cancel = ref.type("app.ACTION_CANCEL_INDEX")
        CANCEL_INDEX_INVALID = ref.need(cancel:get_field("Invalid"), "ACTION_CANCEL_INDEX.Invalid"):get_data(nil)
        GUARD_ACTION_ID = Action.id(1, 141)   -- app.Wp00Action.cGuard
        BLOCKED_ATTRS = Hunter.action_attrs(ACTION_ATTR, Hunter.GUARD_BLOCKED_ATTRS, function(n)
            L.warn("ACTION_ATTR." .. n .. " not found, skipped")
        end)
        ref.hook(HunterCharacter, "evHit_DamagePreProcess(app.HitInfo)", prof.timed("dmg_pre", on_damage_pre), nil)
        ref.hook(HunterCharacter, "evHit_Damage(app.HitInfo)", nil, prof.timed("dmg", on_damage_post))
        HunterHealth = ref.type("app.cHunterHealth")
        local function health_pre() return ref.safe_pre(block_master_damage, function(e) L.warn_err("health", e) end) end
        ref.hook(HunterHealth, "requestDamage(app.HunterCharacter, System.Single, System.Single, System.Boolean, System.Boolean, "
            .. "System.Boolean, System.Boolean, System.Boolean, System.Boolean)", health_pre(), nil)
        ref.hook(HunterHealth, "requestRedDamage(System.Single)", health_pre(), nil)
    end

    local ok, err = pcall(init)
    ready = ok
    G.ready = ok
    if not ok then
        init_err = tostring(err)
        L.warn_err("init", init_err)
    end

    function G.draw()
        if not ready then
            imgui.text("自动防御初始化失败：" .. tostring(init_err) .. "；自动放刀不受影响")
            return
        end
        local changed, v
        changed, v = imgui.checkbox("启用自动防御（含自动肩撞）##enabled", config.enabled)
        if changed then config.enabled = v end
        changed, v = imgui.combo("防御类型##guard_type", config.guard_type, GUARD_TYPES)
        if changed then config.guard_type = v end
        changed, v = imgui.checkbox("霸体时不防御（保护真蓄力斩等霸体攻击）##respect_armor", config.respect_armor)
        if changed then config.respect_armor = v end
        changed, v = imgui.checkbox("蓄力中挨打后自动肩撞##auto_tackle", config.auto_tackle)
        if changed then config.auto_tackle = v end
        imgui.separator()
        if ensure_angle_defaults() then
            changed, v = imgui.slider_float("防御角度##guard_angle", current_angle(), K.ANGLE_MIN, K.ANGLE_MAX, "%.0f 度")
            if changed then config.guard_angle = v end
            imgui.same_line()
            if imgui.button("恢复默认##angle_default") then config.guard_angle = nil end
            imgui.text(string.format("游戏默认 %.0f 度（正前方左右各 %.0f 度），当前左右各 %.0f 度。手动防御同样生效。",
                angle_defaults._GuardDegree, angle_defaults._GuardDegree / 2, current_angle() / 2))
        else
            imgui.text("防御角度：等待读取角色数据……")
        end
    end

    function G.draw_tests()
        if not ready then return end
        local changed, v = imgui.checkbox("【测试】无限蓄力（蓄满后不会自动放出）##infinite_charge", config.infinite_charge)
        if changed then config.infinite_charge = v end
        if config.infinite_charge then
            imgui.text(overheat:active() and "状态：生效中（同场 NPC 支援猎人的大剑也会受影响）" or "状态：等待（拿起大剑后生效）")
        end
        changed, v = imgui.checkbox("【测试】锁血（不掉血、不会倒下，被打的动作照常）##lock_health", config.lock_health)
        if changed then config.lock_health = v end
        if config.lock_health then
            imgui.text(string.format("状态：%s，已拦下扣血 %d 次", master_health_addr and "生效中" or "等待（进入任务后生效）",
                stats.damage_blocked))
        end
    end

    return G
end

return M

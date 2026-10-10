-- AutoGuardGS v0.2：大剑自动防御（原型）
--
-- 原理（每一条都在探针里验证过）：
--   检测：app.ColliderSwitcher.activateAttack 被怪物调用 = 攻击判定刚激活。
--         激活那一帧读到的形状位置是旧的，所以登记成「威胁」，从下一帧起每帧追踪
--         判定框（包围盒）到玩家身体的距离和接近速度。
--   预测：距离 - 接近速度 × lead_sec ≤ margin，就认为它会打中
--         （实测：打中的招式这样能提前约 0.09 秒；停在 2.6m 外的招式不会触发）
--   执行：在游戏合并完输入后，把 _MergedVirtualInput 里的 ATTACK_SP（大剑防御键）
--         设成按住，举剑、保持、防住后的反应、收剑全部由游戏原生处理
--   判断：能不能举剑交给游戏自己的输入规则；我们只额外限制「拿大剑、已拔刀、
--         默认不在攻击动作中」

local TAG = "[AutoGuardGS] "
local CONFIG_PATH = "AutoGuardGS.json"

local config = {
    enabled = true,
    lead_sec = 0.08,          -- 预测多远的未来（秒）：越大越早举剑，也越容易误触发
    margin = 0.3,             -- 预测距离小于这个值（米）就举剑
    hold_sec = 0.4,           -- 每次触发虚拟按住防御键多久
    allow_in_attack = false,  -- 攻击动作中也触发（蓄力中会变成肩撞）
    prefilter_dist = 20.0,    -- 怪物中心离玩家超过这个距离（米）的攻击直接忽略，省性能
}

local loaded = json.load_file(CONFIG_PATH)
if loaded then
    for k, v in pairs(loaded) do
        if config[k] ~= nil then config[k] = v end
    end
end

local THREAT_WINDOW = 0.5   -- 每个威胁最多追踪多久（秒）
local BODY_HEIGHT = 1.8     -- 玩家近似成脚底到头顶的竖直线段

local ColliderSwitcher = sdk.find_type_definition("app.ColliderSwitcher")
local CommandController = sdk.find_type_definition("app.cPlayerCommandController")
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local PAD = sdk.find_type_definition("app.PlayerKey.PAD")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local KEY_ATTACK_SP = PAD:get_field("ATTACK_SP"):get_data(nil)
local WEAPON_GREAT_SWORD = 0
local CATEGORY_WP_ATTACK = 2   -- 大剑动作分类 2 是攻击类（蓄力、斩击、肩撞……）

local threats = {}
local hold_until = 0
local need_trigger = false
local stats = { threats = 0, triggered = 0, skipped_state = 0, hits_guarded = 0, hits_unguarded = 0 }
local recent = {}

local function note(text)
    table.insert(recent, 1, text)
    if #recent > 12 then table.remove(recent) end
    log.info(TAG .. text)
end

local function get_master()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    return pm and pm:call("getMasterPlayer")
end

local function get_master_hunter()
    local player = get_master()
    return player and player:call("get_Character")
end

local function action_short_name(hunter)
    local act = hunter:call("get_BaseActionController"):call("get_CurrentAction")
    local name = act and act:get_type_definition():get_full_name() or "?"
    return (name:gsub("app%.Wp%d%dAction%.", ""))
end

-- 当前能不能自动防御
local function hunter_ready(hunter)
    if hunter:call("get_WeaponType") ~= WEAPON_GREAT_SWORD then return false end
    if not hunter:call("get_IsWeaponOn") then return false end
    if not config.allow_in_attack then
        local id = hunter:call("get_BaseActionController"):call("get_CurrentActionID")
        if id:get_field("_Category") == CATEGORY_WP_ATTACK then return false end
    end
    return true
end

local function enemy_of(game_object)
    if not game_object then return nil end
    local chara = game_object:call("getComponent(System.Type)", T_CharacterBase)
    if chara and chara:get_type_definition():is_a("app.EnemyCharacter") then return chara end
    return nil
end

-- 包围盒到竖直线段（玩家脚底 p 到 p+BODY_HEIGHT）的距离
local function aabb_to_body(minp, maxp, p)
    local dx = math.max(minp.x - p.x, 0, p.x - maxp.x)
    local dz = math.max(minp.z - p.z, 0, p.z - maxp.z)
    local dy = math.max(minp.y - (p.y + BODY_HEIGHT), 0, p.y - maxp.y)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- 该威胁所有碰撞体里离玩家最近的距离
local function threat_distance(th, player_pos)
    local best = nil
    local n = th.rsc:call("getNumCollidables(System.UInt32, System.UInt32)", th.res, th.req)
    for i = 0, n - 1 do
        local col = th.rsc:call("getCollidable(System.UInt32, System.UInt32, System.UInt32)", th.res, th.req, i)
        local shape = col and col:call("get_TransformedShape")
        if shape then
            local aabb = shape:call("get_BoundingAabb")
            local d = aabb_to_body(aabb:get_field("minpos"), aabb:get_field("maxpos"), player_pos)
            if not best or d < best then best = d end
        end
    end
    return best
end

local function trigger_guard(reason)
    local now = os.clock()
    if now >= hold_until then need_trigger = true end  -- 新的一次按下才给「刚按下」
    hold_until = math.max(hold_until, now + config.hold_sec)
    stats.triggered = stats.triggered + 1
    note(reason)
end

-- 检测：怪物攻击判定激活 → 登记威胁（这一帧的形状位置是旧的，不在这里判断）
-- 实测怪物只用这个重载；args[3] 是「激活/关闭」，关闭会每帧被调用，必须过滤掉
sdk.hook(ColliderSwitcher:get_method("activateAttack(System.Boolean, System.UInt32, System.UInt32, System.Nullable`1<System.Boolean>, app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, System.Nullable`1<System.Single>)"),
    function(args)
        if not config.enabled then return end
        if (sdk.to_int64(args[3]) & 1) == 0 then return end

        local ok, err = pcall(function()
            local switcher = sdk.to_managed_object(args[2])
            local enemy = enemy_of(switcher:get_field("_HitController"):call("get_Owner"))
            if not enemy then return end
            local hunter = get_master_hunter()
            if not hunter then return end
            if (enemy:call("get_Pos") - hunter:call("get_Pos")):length() > config.prefilter_dist then return end

            table.insert(threats, {
                t = os.clock(),
                rsc = switcher:call("get_RequestSetCollider"),
                res = sdk.to_int64(args[4]) & 0xFFFFFFFF,
                req = sdk.to_int64(args[5]) & 0xFFFFFFFF,
            })
            stats.threats = stats.threats + 1
        end)
        if not ok then log.warn(TAG .. "detect err: " .. tostring(err)) end
    end, nil)

-- 预测：每帧在游戏更新之前，追踪所有威胁
re.on_pre_application_entry("UpdateBehavior", function()
    if #threats == 0 then return end
    local ok, err = pcall(function()
        local hunter = get_master_hunter()
        if not hunter then threats = {}; return end
        local pos = hunter:call("get_Pos")
        local now = os.clock()

        for i = #threats, 1, -1 do
            local th = threats[i]
            local age = now - th.t
            local d = threat_distance(th, pos)
            local done = age >= THREAT_WINDOW or not d

            if d and th.prev_d and now > th.prev_t then
                local v = math.max((th.prev_d - d) / (now - th.prev_t), 0)  -- 接近速度，远离算 0
                local predicted = d - v * config.lead_sec
                if predicted <= config.margin then
                    if hunter_ready(hunter) then
                        trigger_guard(string.format("trigger req=%d age=%.2f d=%.2f v=%.1f pred=%.2f",
                            th.req, age, d, v, predicted))
                    else
                        stats.skipped_state = stats.skipped_state + 1
                    end
                    done = true
                end
            end
            th.prev_d, th.prev_t = d, now

            if done then table.remove(threats, i) end
        end
    end)
    if not ok then
        log.warn(TAG .. "update err: " .. tostring(err))
        threats = {}
    end
end)

-- 执行：合并输入之后，虚拟按住防御键
local cur_ctrl = nil
sdk.hook(CommandController:get_method("mergeAndUpdateInput"),
    function(args)
        cur_ctrl = sdk.to_managed_object(args[2])
    end,
    function(retval)
        local ctrl = cur_ctrl
        cur_ctrl = nil
        if not ctrl or os.clock() >= hold_until then return retval end

        local ok, err = pcall(function()
            -- 只改主玩家（比较地址：同一个对象取两次可能是不同的 Lua 包装）
            local player = get_master()
            local master_ctrl = player and player:call("get_Controller"):call("get_ControllerEntity"):call("get_CommandController")
            if not master_ctrl or ctrl:get_address() ~= master_ctrl:get_address() then return end

            local key = ctrl:get_field("_MergedVirtualInput"):call("getKey(System.Int32)", KEY_ATTACK_SP)
            key:call("set_On", true)
            if need_trigger then
                key:call("set_OnTrigger", true)
                need_trigger = false
            end
        end)
        if not ok then log.warn(TAG .. "inject err: " .. tostring(err)) end
        return retval
    end)

-- 效果统计：被怪物打中时，是不是已经在防御
sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    local ok, err = pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        if not enemy_of(sdk.to_managed_object(args[3]):call("get_AttackOwner")) then return end
        local action = action_short_name(hunter)
        if action:find("Guard") then
            stats.hits_guarded = stats.hits_guarded + 1
        else
            stats.hits_unguarded = stats.hits_unguarded + 1
        end
        note("HIT action=" .. action)
    end)
    if not ok then log.warn(TAG .. "hit err: " .. tostring(err)) end
end, nil)

re.on_config_save(function()
    json.dump_file(CONFIG_PATH, config)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardGS v0.2") then return end
    local changed, v
    changed, v = imgui.checkbox("Enabled", config.enabled); if changed then config.enabled = v end
    changed, v = imgui.slider_float("Lead (s)", config.lead_sec, 0.0, 0.2, "%.2f"); if changed then config.lead_sec = v end
    changed, v = imgui.slider_float("Margin (m)", config.margin, 0.0, 2.0, "%.2f"); if changed then config.margin = v end
    changed, v = imgui.slider_float("Hold time (s)", config.hold_sec, 0.1, 2.0, "%.2f"); if changed then config.hold_sec = v end
    changed, v = imgui.checkbox("Allow during attacks (charge -> tackle)", config.allow_in_attack); if changed then config.allow_in_attack = v end
    imgui.separator()
    imgui.text(string.format("Threats: %d  Triggered: %d  Skipped(state): %d", stats.threats, stats.triggered, stats.skipped_state))
    imgui.text(string.format("Hits while guarding: %d  Hits NOT guarding: %d", stats.hits_guarded, stats.hits_unguarded))
    if imgui.button("Reset stats") then
        for k in pairs(stats) do stats[k] = 0 end
        recent = {}
    end
    for _, r in ipairs(recent) do imgui.text(r) end
    imgui.tree_pop()
end)

log.info(TAG .. "v0.2 loaded, ATTACK_SP=" .. tostring(KEY_ATTACK_SP))

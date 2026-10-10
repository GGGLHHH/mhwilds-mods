-- AutoGuardDetect v2：测量「攻击判定框」本身离玩家多远（只记录、不防御）
--
-- v1 的结论：用「怪物中心到玩家的距离」判断太粗——7.5m 外的攻击根本打不到，
-- 却也在阈值内触发了防御。
--
-- v2 要回答：
--   1. 判定激活那一刻，判定框的位置已经是新的了吗？（看 t=0 那一格的距离）
--   2. 打中的攻击和打不中的攻击，判定框离玩家的最近距离差多少？→ 定阈值
--   3. 判定框什么时候进入阈值？离打中还剩多少时间？→ 看提前量还够不够
--
-- 做法：ATK+ 时登记一个「威胁」，之后 0.5 秒内每帧计算该判定所有碰撞体的
-- 包围盒（get_BoundingAabb，任何形状都有）到玩家身体（脚底到头顶的竖直线段）的距离。
-- 结束时把整条距离曲线写一行日志。

local TAG = "[AGDetect] "
local WINDOW = 0.5          -- 每个威胁追踪多久（秒）
local BODY_HEIGHT = 1.8     -- 把玩家近似成一根竖直线段

local ColliderSwitcher = sdk.find_type_definition("app.ColliderSwitcher")
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local t0 = os.clock()
local function now() return os.clock() - t0 end

local threats = {}   -- 进行中的威胁
local events = {}    -- 菜单里显示的最近记录
local next_id = 1

local function push(text)
    table.insert(events, 1, text)
    if #events > 25 then table.remove(events) end
    log.info(TAG .. text)
end

local function get_master_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local player = pm and pm:call("getMasterPlayer")
    return player and player:call("get_Character")
end

local function as_enemy(game_object)
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

-- 某个威胁当前所有碰撞体里，离玩家最近的距离（拿不到形状返回 nil）
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
    return best, n
end

local function finish(th)
    local series = {}
    for _, s in ipairs(th.series) do
        table.insert(series, string.format("%.2f:%s", s[1], s[2] and string.format("%.2f", s[2]) or "nil"))
    end
    push(string.format("#%d %s req=%d cols=%d center=%.1f hit=%s | %s",
        th.id, th.name, th.req, th.cols or -1, th.center_dist,
        th.hit_at and string.format("%.2f", th.hit_at) or "no",
        table.concat(series, " ")))
end

sdk.hook(ColliderSwitcher:get_method("activateAttack(System.Boolean, System.UInt32, System.UInt32, System.Nullable`1<System.Boolean>, app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, System.Nullable`1<System.Single>)"),
    function(args)
        if (sdk.to_int64(args[3]) & 1) == 0 then return end
        local ok, err = pcall(function()
            local switcher = sdk.to_managed_object(args[2])
            local owner = switcher:get_field("_HitController"):call("get_Owner")
            local enemy = as_enemy(owner)
            if not enemy then return end
            local hunter = get_master_hunter()
            if not hunter then return end
            local th = {
                id = next_id, t = now(), name = owner:call("get_Name"),
                rsc = switcher:call("get_RequestSetCollider"),
                res = sdk.to_int64(args[4]) & 0xFFFFFFFF,
                req = sdk.to_int64(args[5]) & 0xFFFFFFFF,
                center_dist = (enemy:call("get_Pos") - hunter:call("get_Pos")):length(),
                series = {},
            }
            -- 激活这一刻就量一次，看位置是不是已经更新
            local d, n = threat_distance(th, hunter:call("get_Pos"))
            th.cols = n
            table.insert(th.series, { 0.0, d })
            next_id = next_id + 1
            table.insert(threats, th)
        end)
        if not ok then log.warn(TAG .. "detect err: " .. tostring(err)) end
    end, nil)

-- 每帧更新所有进行中的威胁
re.on_pre_application_entry("UpdateBehavior", function()
    if #threats == 0 then return end
    local ok, err = pcall(function()
        local hunter = get_master_hunter()
        local pos = hunter and hunter:call("get_Pos")
        local t = now()
        for i = #threats, 1, -1 do
            local th = threats[i]
            if pos then
                local d = threat_distance(th, pos)
                table.insert(th.series, { t - th.t, d })
            end
            if t - th.t >= WINDOW then
                finish(th)
                table.remove(threats, i)
            end
        end
    end)
    if not ok then
        log.warn(TAG .. "update err: " .. tostring(err))
        threats = {}
    end
end)

-- 玩家被打中：记到最近登记的、同一只怪的威胁上
sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    local ok, err = pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        local attacker = sdk.to_managed_object(args[3]):call("get_AttackOwner")
        if not as_enemy(attacker) then return end
        local name = attacker:call("get_Name")
        local t = now()
        for i = #threats, 1, -1 do
            if threats[i].name == name and not threats[i].hit_at then
                threats[i].hit_at = t - threats[i].t
                break
            end
        end
        log.info(string.format("%sHIT %s at %.2f", TAG, name, t))
    end)
    if not ok then log.warn(TAG .. "hit err: " .. tostring(err)) end
end, nil)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardDetect v2") then return end
    if imgui.button("Clear") then events = {} end
    imgui.text("Active threats: " .. #threats)
    for _, e in ipairs(events) do imgui.text(e:sub(1, 120)) end
    imgui.tree_pop()
end)

log.info(TAG .. "v2 loaded")

-- WeaponTypeProbe：只读探针，核对 app.WeaponDef.TYPE 的「名字 = 值」（2026-10-19）。
-- 为什么：MCP 的类型库只给枚举名不给值；_CatLib 的编号表（大剑 0、太刀 3……）是二手的，lib/wilds/weapon 只认实测过的编号。
-- 做什么：加载时把枚举全表写进日志；之后每帧读主角的 get_WeaponType()，变了才写一行（换武器时）。不改任何东西。
-- 日志标签 [WeaponTypeProbe]。用完从 autorun 挪走。
local TAG = "[WeaponTypeProbe] "

local names = {}
local ok, err = pcall(function()
    local td = sdk.find_type_definition("app.WeaponDef.TYPE")
    local parts = {}
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
            local v = f:get_data(nil)
            names[v] = names[v] and (names[v] .. "/" .. f:get_name()) or f:get_name()
            parts[#parts + 1] = { v = v, n = f:get_name() }
        end
    end
    table.sort(parts, function(a, b) return (tonumber(a.v) or 0) < (tonumber(b.v) or 0) end)
    local s = {}
    for _, p in ipairs(parts) do s[#s + 1] = p.n .. "=" .. tostring(p.v) end
    log.info(TAG .. "ENUM " .. table.concat(s, " "))
end)
if not ok then log.warn(TAG .. "enum err: " .. tostring(err)) end

local last = nil
re.on_pre_application_entry("UpdateBehavior", function()
    local ok2, err2 = pcall(function()
        local pm = sdk.get_managed_singleton("app.PlayerManager")
        local p = pm and pm:call("getMasterPlayer")
        local h = p and p:call("get_Character")
        if not h then return end
        local wt = h:call("get_WeaponType")
        if wt ~= last then
            last = wt
            log.info(TAG .. "WEAPON " .. tostring(wt) .. " = " .. tostring(names[wt]))
        end
    end)
    if not ok2 and last ~= "err" then
        last = "err"
        log.warn(TAG .. "frame err: " .. tostring(err2))
    end
end)

-- Reset Scripts 会不会给一个全新的 Lua 状态（package.loaded 清空）：加载时看上次留的标记还在不在，再留一个新的。
-- 标记在 = Reset 保留了模块缓存（改了库代码 Reset 也不生效，要重启游戏）；不在 = 全新状态
local SENTINEL = "WeaponTypeProbe.reset_sentinel"
local prev = package.loaded[SENTINEL]
package.loaded[SENTINEL] = os.time()
log.info(TAG .. "RESET_SENTINEL " .. (prev and ("still_there_from=" .. tostring(prev)) or "absent"))

log.info(TAG .. "loaded")

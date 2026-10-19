-- lib/ref：REFramework sdk 的小工具：查类型、读枚举、注册钩子。
--
-- 初始化时类型、方法拿不到要报清楚是哪个（need），别让后面的 nil 索引报一句看不懂的错。
local M = {}

function M.need(v, what)
    if v == nil then error(what .. " not found", 0) end
    return v
end

function M.type(name) return M.need(sdk.find_type_definition(name), name) end

-- 钩子：方法拿不到时报「类型.签名 not found」
function M.hook(td, sig, pre, post)
    sdk.hook(M.need(td:get_method(sig), td:get_full_name() .. "." .. sig), pre, post)
end

-- 前置钩子外层的保护：fn 出错时调 on_error(err)、返回 nil（照常调用原函数），不让错误漏进游戏
function M.safe_pre(fn, on_error)
    return function(args)
        local ok, r = pcall(fn, args)
        if ok then return r end
        on_error(r)
        return nil
    end
end

-- 枚举值：遍历静态字段取 get_data(nil)，表里没有再按名字直接取（实测写法，沿用 AGPCall）。拿不到抛错
function M.enum_value(type_name, name)
    local td = sdk.find_type_definition(type_name)
    if not td then error("type not found: " .. type_name) end
    for _, f in ipairs(td:get_fields()) do
        local v = f:is_static() and f:get_name() == name and f:get_data(nil)
        if type(v) == "number" then return v end
    end
    local f = td:get_field(name)
    local v = f and f:get_data(nil)
    if type(v) ~= "number" then error("enum value not found: " .. type_name .. "." .. name) end
    return v
end

-- 一组枚举名逐个读、互不连累：读到的进 into[值] = 名字，读不到的名字追加进 miss，返回第一个错误（都读到时为 nil）
function M.enum_into(type_name, names, into, miss)
    local first = nil
    for _, n in ipairs(names) do
        local ok, v = pcall(M.enum_value, type_name, n)
        if ok then into[v] = n else miss[#miss + 1], first = n, first or v end
    end
    return first
end

-- 枚举的双向表：值 → 名字、名字 → 值（静态字段里的数值）。调试时把数字翻成游戏自己的名字用；类型拿不到抛错。
-- 每次调用都遍历一遍字段，别放进每帧的热路径（要反复用就在初始化时取一次存起来）
function M.enum_map(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then error("type not found: " .. type_name) end
    local by_value, by_name = {}, {}
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
            local v = f:get_data(nil)
            if type(v) == "number" then
                local n = f:get_name()
                if by_value[v] == nil then by_value[v] = n end   -- 同值多名（别名、MAX）时留第一个
                by_name[n] = v
            end
        end
    end
    return by_value, by_name
end

-- 对象地址；对象为 nil 或取地址抛错时返回 nil
function M.addr_of(obj)
    if not obj then return nil end
    local ok, a = pcall(obj.get_address, obj)
    return ok and a or nil
end

return M

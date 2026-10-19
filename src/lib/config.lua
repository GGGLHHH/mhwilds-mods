-- lib/config：reframework/data/ 下 JSON 配置的读写，只接受认识的键和合法的值（文件被手改坏也不至于出怪事）。
--
-- 读：data 里已有的键（默认值不是 nil），读到的值类型相同就收；有 validators[键] 的键交给它判断，它返回 nil 就不收。
--     默认值是 nil 的键（例如「nil = 用游戏原值」）必须写 validator，否则永远读不进来。不认识的键忽略。
-- 读的时候抛错（文件被占用等）：C.unreadable = true，这次加载一律不写配置——内存里是默认值，写了就把多半完好的原文件
--     盖掉。读出来不是表（文件不存在、内容坏了，REF 返回 nil）分不清是哪种，照常可以写。
--
-- 用法：
--   local config = { enabled = true, angle = nil }
--   local C = cfg.new({ path = "MyMod.json", data = config, on_error = function(err) ... end,
--                       validators = { angle = function(v) return type(v) == "number" and v or nil end } })
--   C.load()                                          -- 加载时调一次，返回读到的原始表（或 nil）
--   re.on_config_save(function() C.save() end)        -- 什么时候落盘由 REF 触发
local M = {}

-- opts.path：相对 reframework/data/ 的文件名；opts.data：配置表（原地改）；opts.validators；opts.on_error(err)
function M.new(opts)
    local path, data, validators, on_error = opts.path, opts.data, opts.validators or {}, opts.on_error
    local C = { unreadable = false, data = data }

    function C.load()
        local ok, loaded = pcall(json.load_file, path)
        if not ok then
            C.unreadable = true
            on_error(loaded)
            return nil
        end
        if type(loaded) ~= "table" then return nil end
        for k, v in pairs(loaded) do
            local check = validators[k]
            if check then
                local nv = check(v)
                if nv ~= nil then data[k] = nv end
            elseif data[k] ~= nil and type(v) == type(data[k]) then
                data[k] = v
            end
        end
        return loaded
    end

    function C.save()
        if C.unreadable then return end
        local ok, ret = pcall(json.dump_file, path, data)
        if not ok or ret == false then on_error(ok and "config dump_file returned false" or ret) end
    end
    return C
end

-- 读别的配置文件（迁移旧版配置用）：返回 ok, 表或错误。只读，不改不删
function M.read(path)
    return pcall(json.load_file, path)
end

return M

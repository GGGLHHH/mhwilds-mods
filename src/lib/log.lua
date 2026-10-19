-- lib/log：带标签的日志。调试行受开关控制；按类别限量的警告，出错时不至于每帧刷一行。
--
-- 用法：
--   local L = require(LIB .. "log").new({ tag = "[MyMod] ", debug_on = function() return config.debug_log end })
--   L.info("loaded")  L.debug("只在开关打开时写")  L.warn_err("frame", err)  -- 每类最多 warn_max 行
local M = {}

-- opts.tag：每行的前缀（含结尾空格）；opts.debug_on：返回调试日志开没开；opts.warn_max：warn_err 每类每次加载最多写几行
function M.new(opts)
    local tag = opts.tag
    local debug_on = opts.debug_on
    local warn_max = opts.warn_max or 20
    local warn_n = {}
    local L = {}
    function L.info(text) log.info(tag .. text) end
    function L.warn(text) log.warn(tag .. text) end
    function L.debug(text)
        if debug_on() then log.info(tag .. text) end
    end
    -- 部件出错：写 "<tag><kind> err: <err>"，同一类超过 warn_max 行后只计数不写
    function L.warn_err(kind, err)
        local n = (warn_n[kind] or 0) + 1
        warn_n[kind] = n
        if n <= warn_max then log.warn(tag .. kind .. " err: " .. tostring(err)) end
    end
    return L
end

return M

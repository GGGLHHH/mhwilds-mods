-- lib/health：错误分级，不许静默吞错（AutoParryGS 的 CONTRACT 2.1 抽出来的通用版）。
--
--   核心模块（core 里列的名字）：red_window 秒内出错 red_count 次标红（H.red），只在第一次进红状态时发一行 RED。
--   可选模块：第一次出错就标黄（H.off[名字] = true，H.yellow 计有几个模块报过黄）；停不停用那项读取由调用方看 H.off 决定。
--   每次出错发一行 ERR（每次加载前 log_max 条，之后只计不写）。H.stopped 留给调用方表示「已自停」。
--   ERR / RED 行怎么写由 emit(kind, vals) 决定（通常是 record 的 R.emit）：ERR = { 模块, "red"|"yellow", 文本 }，
--   RED = { 时刻, 模块, 原因 }。
--
-- 用法：
--   local H = health.new({ core = { frame = true }, emit = R.emit })
--   H.note("frame", err)                  -- 计一次错误
--   H.set_red(os.clock(), "frame", "init") -- 直接标红
local LIB = ((...) or error("lib 模块要用 require 载入")):gsub("[^.]+$", "")
local util = require(LIB .. "util")

local M = {}

-- opts.core：{ 模块名 = true }；opts.emit(kind, vals)；opts.red_window（默认 10 s）、opts.red_count（默认 3）、
-- opts.log_max（默认 20）；opts.clock：取时刻的函数，不给就每次现调 os.clock
function M.new(opts)
    local core, emit = opts.core, opts.emit
    local red_window, red_count, log_max = opts.red_window or 10.0, opts.red_count or 3, opts.log_max or 20
    local clock = opts.clock
    local times = {}
    local H = { red = false, stopped = false, yellow = 0, logged = 0, off = {} }

    -- 只在第一次进红状态时写 RED；why == "self_stop"（自停）另写一行
    function H.set_red(now, mod, why)
        if H.red and why ~= "self_stop" then return end
        H.red = true
        emit("RED", { now, mod, why })
    end

    function H.note(mod, err)
        local now = clock and clock() or os.clock()
        -- 非 ASCII 换成 ?：错误文本里的路径可能是系统代码页，原样写进日志是乱码
        local msg = util.clean_str(err):gsub("[\128-\255]", "?"):sub(1, 200)
        local level, red_now = "yellow", false
        if core[mod] then
            level = "red"
            local ts = times[mod] or {}
            times[mod] = ts
            ts[#ts + 1] = now
            while #ts > 0 and now - ts[1] > red_window do table.remove(ts, 1) end
            red_now = #ts >= red_count
        elseif not H.off[mod] then
            H.off[mod], H.yellow = true, H.yellow + 1
        end
        if H.logged < log_max then
            H.logged = H.logged + 1
            emit("ERR", { mod, level, msg })
        end
        if red_now then H.set_red(now, mod, "3in10s") end
    end
    return H
end

return M

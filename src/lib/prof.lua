-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 GGG <1635656638@qq.com>
-- lib/prof：性能计数（诊断卡顿用）。一直计数（开销很小），每 interval 秒汇总一次交给 on_report。
-- os.clock 在 Windows 上精度约 1 毫秒，单次耗时很小时只看调用次数更可靠。
--
-- 用法：
--   local P = require(LIB .. "prof").new({ keys = { "frame", "hit" }, on_report = function(text) L.debug("PERF " .. text) end })
--   re.on_pre_application_entry("UpdateBehavior", P.timed("frame", on_frame))   -- 包一层计时
--   P.report()   -- 每帧调一次，满 interval 秒才真正汇总；最近一次的汇总文字在 P.text
local M = {}

-- opts.keys：要计的名字（汇总按这个顺序）；opts.interval：汇总间隔秒数，默认 5；opts.on_report(text)
function M.new(opts)
    local keys, interval, on_report = opts.keys, opts.interval or 5.0, opts.on_report
    local acc = {}
    for _, k in ipairs(keys) do acc[k] = { n = 0, t = 0 } end
    local last = os.clock()
    local P = { text = "" }

    -- 返回包了计时的 fn。只记录正常返回的那几次耗时：fn 抛错时照常往外抛（调用方自己 pcall）
    function P.timed(name, fn)
        return function(...)
            local t0 = os.clock()
            local r = fn(...)
            local p = acc[name]
            p.n = p.n + 1
            p.t = p.t + (os.clock() - t0)
            return r
        end
    end

    function P.report()
        local now = os.clock()
        local dt = now - last
        if dt < interval then return end
        local parts = {}
        for _, k in ipairs(keys) do
            local p = acc[k]
            table.insert(parts, string.format("%s %.0f/s %.1fms/s", k, p.n / dt, p.t * 1000 / dt))
            p.n, p.t = 0, 0
        end
        P.text = table.concat(parts, " | ")
        on_report(P.text)
        last = now
    end
    return P
end

return M

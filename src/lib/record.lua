-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 GGG <1635656638@qq.com>
-- lib/record：给离线分析脚本读的结构化日志行 "<TAG> KIND k=v k=v ..."。
--
-- spec 里每种行一串「字段名:格式」，格式：i 整数 / fN 保留 N 位小数 / s 文本 / b 布尔（写 1/0）/ h 地址（十六进制）；
-- 值为 nil、NaN、无穷时写 -。i 字段遇到非整数按 %.1f 写。
--
-- 头行（header_kind，例如 HDR）懒写：本次加载第一次写别的行之前自动补一行。分析脚本按最近的头行划分 session，不补的话
-- 这次的记录会被算进上一次加载。加载期间写的行先攒着（头行要等配置读完、枚举读完才写得准），finish_loading 时再写。
--
-- 用法：
--   local R = record.new({ tag = "[MyRec]", spec = { HDR = "ver:s", HIT = "id:i t:f3" }, fmt = F,
--                          header_kind = "HDR", header = function() return { VERSION } end })
--   R.emit("HIT", { 1, os.clock() })      -- vals 按 spec 的字段顺序，可以含 nil
--   R.finish_loading(config.debug_log)    -- 加载末尾调一次：参数为真、或有攒下的行时先写头行
local LIB = ((...) or error("lib 模块要用 require 载入")):gsub("[^.]+$", "")   -- 本模块所在的包前缀，例如 "MyMod.lib."
local util = require(LIB .. "util")

local M = {}

local FLOAT_FMT = { i = "%.1f", f1 = "%.1f", f2 = "%.2f", f3 = "%.3f", f4 = "%.4f" }

-- opts.tag：行首标签（不含空格）；opts.spec：{ KIND = "名:格式 ..." }；opts.fmt：util.formatter 的结果；
-- opts.header_kind / opts.header：头行的种类和取值函数（写头行那一刻才调用，拿到的是那一刻的值）
function M.new(opts)
    local tag, F, header_kind, header = opts.tag, opts.fmt, opts.header_kind, opts.header
    local SPEC = {}
    for kind, s in pairs(opts.spec) do
        SPEC[kind] = {}
        for name, ft in s:gmatch("([%w_]+):(%w+)") do SPEC[kind][#SPEC[kind] + 1] = { name, ft } end
    end

    local function fmt_value(v, ft)
        if ft == "b" and v ~= nil then v = (v == true or (type(v) == "number" and v ~= 0)) and 1 or 0 end
        if ft == "h" then v = F.hex(v) end
        if v == nil then return "-" end
        if ft == "s" or type(v) ~= "number" then return util.clean_str(v) end
        if not util.finite(v) then return "-" end
        if (ft == "i" or ft == "b") and math.tointeger(v) then return tostring(math.tointeger(v)) end
        return F.fmt(FLOAT_FMT[ft] or "%.3f", v)
    end

    local R = {}
    local hdr_written, pending = false, {}   -- pending 不为 nil = 还在加载

    function R.line(kind, vals)
        local spec, parts = SPEC[kind], { tag, kind }
        for i = 1, #spec do parts[#parts + 1] = spec[i][1] .. "=" .. fmt_value(vals[i], spec[i][2]) end
        return table.concat(parts, " ")
    end

    function R.write_header()
        hdr_written = true
        log.info(R.line(header_kind, header()))
    end

    function R.emit(kind, vals)
        local line = R.line(kind, vals)
        if pending then
            pending[#pending + 1] = line
            return
        end
        if not hdr_written then R.write_header() end
        log.info(line)
    end

    function R.finish_loading(force_header)
        local p = pending
        pending = nil
        if force_header or #p > 0 then R.write_header() end
        for _, line in ipairs(p) do log.info(line) end
    end
    return R
end

return M

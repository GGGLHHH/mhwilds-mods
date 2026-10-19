-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 GGG <1635656638@qq.com>
-- lib/util：数值检查、写日志用的格式化。
--
-- 整个库的约定（docs/ARCHITECTURE.md）：
--   - 模块级不放可变状态。REF 所有脚本共用一个 Lua 状态，模块缓存在 package.loaded 里；有状态的东西一律做成 new() 工厂，
--     每个 mod、每个部件各拿一份，互不牵连。
--   - 库内互相 require 用相对前缀（见 record.lua 开头）：打包时库被复制进每个 mod 的 <Mod>/lib/，挂在哪个名字下都能用。
local M = {}

function M.finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- 值不能含空白：离线分析按空格切字段
function M.clean_str(v) return (tostring(v):gsub("%s", "_")) end

function M.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- 格式化工具组。string.format 抛错（参数类型不对）时不往外抛，返回 "FMT_ERR <格式>"，并调用 on_error(同一段文字) 让调用方计
-- 一次错误。on_error 可以为 nil
function M.formatter(on_error)
    local F = {}
    function F.fmt(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        if ok then return s end
        if on_error then on_error("FMT_ERR " .. fmt) end
        return "FMT_ERR " .. fmt
    end
    -- 整数转文本：不用 %d（Lua 5.4 里 %d 遇到带小数的值会抛错），非整数退回 %.1f
    function F.int(v)
        local iv = math.tointeger(v)
        if iv then return tostring(iv) end
        return type(v) == "number" and F.fmt("%.1f", v) or tostring(v)
    end
    -- 地址转十六进制；不是整数返回 nil
    function F.hex(v) return math.tointeger(v) and F.fmt("%X", math.tointeger(v)) or nil end
    return F
end

return M

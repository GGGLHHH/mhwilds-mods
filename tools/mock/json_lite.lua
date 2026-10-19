-- tools/mock/json_lite.lua：严格的 JSON 编解码（只给模拟测试用，不进游戏）
--
-- 为什么自己写、而且写得比 REF 严：
--   REF 的 json.dump_file 底层是 nlohmann::json，遇到 NaN 会悄悄写成 null、遇到坏 UTF-8 会抛异常，
--   混合键的表怎么转也说不准。离线分析脚本吃的是这些文件，所以模拟里宁可严一点：
--   NaN / inf / userdata / 函数 / 混合键 / 稀疏数组 / 坏 UTF-8 一律拒绝，并说明原因，
--   让问题在部署前暴露，而不是第 1 轮数据拿回来才发现读不了。

local M = {}

-- 由 mock_ref 注入：判断一个 Lua 值是不是「假的游戏对象」（在真 REF 里它们是 userdata）
M.is_userdata = function(_) return false end

-- 解码时 null 的占位（只在 opts.keep_null 时使用）
M.null = setmetatable({}, { __tostring = function() return "null" end })

local ESC = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function enc_string(s)
    if utf8.len(s) == nil then
        error("非法 UTF-8 字符串（可能是中文被截断）: " .. string.format("%q", s:sub(1, 40)), 0)
    end
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESC[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function enc_number(n, path)
    if math.type(n) == "integer" then return string.format("%d", n) end
    if n ~= n then error("NaN 不能写进 JSON（" .. path .. "）", 0) end
    if n == math.huge or n == -math.huge then error("inf 不能写进 JSON（" .. path .. "）", 0) end
    -- 取能精确还原的最短写法
    for _, fmt in ipairs({ "%.15g", "%.16g", "%.17g" }) do
        local s = string.format(fmt, n)
        if tonumber(s) == n then return s end
    end
    return string.format("%.17g", n)
end

local encode_value

local function enc_table(t, path, depth, indent, level)
    if depth > 64 then error("嵌套太深（可能有循环引用）: " .. path, 0) end
    local n_int, n_str, max_i = 0, 0, 0
    for k in pairs(t) do
        if math.type(k) == "integer" and k >= 1 then
            n_int = n_int + 1
            if k > max_i then max_i = k end
        elseif type(k) == "string" then
            n_str = n_str + 1
        else
            error(string.format("表的键类型不能写进 JSON: %s（%s）", type(k), path), 0)
        end
    end
    if n_int > 0 and n_str > 0 then error("表同时有数组键和字符串键（" .. path .. "）", 0) end
    local nl, pad, pad_in = "", "", ""
    if indent then
        nl = "\n"
        pad = string.rep(" ", indent * level)
        pad_in = string.rep(" ", indent * (level + 1))
    end
    if n_int > 0 or n_str == 0 then
        if max_i ~= n_int then error("稀疏数组（有空洞）不能写进 JSON（" .. path .. "）", 0) end
        if n_int == 0 then return "[]" end
        local parts = {}
        for i = 1, n_int do
            parts[i] = pad_in .. encode_value(t[i], path .. "[" .. i .. "]", depth + 1, indent, level + 1)
        end
        return "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "]"
    end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do
        parts[i] = pad_in .. enc_string(k) .. (indent and ": " or ":")
            .. encode_value(t[k], path .. "." .. k, depth + 1, indent, level + 1)
    end
    return "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "}"
end

encode_value = function(v, path, depth, indent, level)
    local tv = type(v)
    if v == M.null then return "null" end
    if tv == "nil" then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then return enc_number(v, path) end
    if tv == "string" then return enc_string(v) end
    if tv == "table" then
        if M.is_userdata(v) then error("游戏对象（userdata）不能写进 JSON（" .. path .. "）", 0) end
        return enc_table(v, path, depth, indent, level)
    end
    error(tv .. " 不能写进 JSON（" .. path .. "）", 0)
end

-- 返回 字符串 或 nil, 原因
function M.encode(v, indent)
    if indent ~= nil and (type(indent) ~= "number" or indent < 0) then indent = nil end
    local ok, res = pcall(encode_value, v, "$", 0, indent, 0)
    if ok then return res end
    return nil, tostring(res)
end

-- ---------- 解码（严格 RFC 8259） ----------

local function decode_error(s, pos, msg)
    local line, col = 1, 1
    for i = 1, pos - 1 do
        if s:sub(i, i) == "\n" then line, col = line + 1, 1 else col = col + 1 end
    end
    error(string.format("JSON 解析错误 第 %d 行第 %d 列: %s", line, col, msg), 0)
end

local function skip_ws(s, pos)
    return (s:find("[^ \t\r\n]", pos)) or (#s + 1)
end

local decode_at

local function decode_string(s, pos)
    -- pos 指向开头的引号
    local buf, i = {}, pos + 1
    while true do
        local c = s:sub(i, i)
        if c == "" then decode_error(s, i, "字符串没有结束") end
        if c == '"' then return table.concat(buf), i + 1 end
        if c == "\\" then
            local e = s:sub(i + 1, i + 1)
            local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
            if map[e] then
                buf[#buf + 1] = map[e]
                i = i + 2
            elseif e == "u" then
                local hex = s:sub(i + 2, i + 5)
                if not hex:match("^%x%x%x%x$") then decode_error(s, i, "\\u 后面不是 4 位十六进制") end
                local cp = tonumber(hex, 16)
                i = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local lo = s:match("^\\u(%x%x%x%x)", i)
                    if not lo then decode_error(s, i, "缺少低位代理项") end
                    local lv = tonumber(lo, 16)
                    if lv < 0xDC00 or lv > 0xDFFF then decode_error(s, i, "低位代理项不合法") end
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lv - 0xDC00)
                    i = i + 6
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    decode_error(s, i, "孤立的低位代理项")
                end
                buf[#buf + 1] = utf8.char(cp)
            else
                decode_error(s, i, "非法转义 \\" .. e)
            end
        else
            if c:byte() < 0x20 then decode_error(s, i, "字符串里有未转义的控制字符") end
            buf[#buf + 1] = c
            i = i + 1
        end
    end
end

local function decode_number(s, pos)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num or num == "" or num == "-" then decode_error(s, pos, "数字格式不对") end
    -- 严格检查：不许前导 0、不许 "1." 这种
    if not (num:match("^-?0$") or num:match("^-?[1-9]%d*$")
        or num:match("^-?0%.%d+$") or num:match("^-?[1-9]%d*%.%d+$")
        or num:match("^-?0[eE][-+]?%d+$") or num:match("^-?[1-9]%d*[eE][-+]?%d+$")
        or num:match("^-?0%.%d+[eE][-+]?%d+$") or num:match("^-?[1-9]%d*%.%d+[eE][-+]?%d+$")) then
        decode_error(s, pos, "数字格式不对: " .. num)
    end
    local v = math.tointeger(tonumber(num)) or tonumber(num)
    if num:find("[%.eE]") then v = tonumber(num) + 0.0 end
    return v, pos + #num
end

decode_at = function(s, pos, opts, depth)
    if depth > 200 then decode_error(s, pos, "嵌套太深") end
    pos = skip_ws(s, pos)
    local c = s:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skip_ws(s, pos)
            if s:sub(pos, pos) ~= '"' then decode_error(s, pos, "对象的键必须是字符串") end
            local k
            k, pos = decode_string(s, pos)
            pos = skip_ws(s, pos)
            if s:sub(pos, pos) ~= ":" then decode_error(s, pos, "缺少冒号") end
            local v
            v, pos = decode_at(s, pos + 1, opts, depth + 1)
            if v ~= nil then obj[k] = v end
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "}" then return obj, pos + 1 end
            if d ~= "," then decode_error(s, pos, "缺少逗号或右花括号") end
            pos = pos + 1
        end
    elseif c == "[" then
        local arr, n = {}, 0
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local v
            v, pos = decode_at(s, pos, opts, depth + 1)
            n = n + 1
            arr[n] = v
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "]" then return arr, pos + 1 end
            if d ~= "," then decode_error(s, pos, "缺少逗号或右方括号") end
            pos = pos + 1
        end
    elseif c == '"' then
        return decode_string(s, pos)
    elseif c == "t" then
        if s:sub(pos, pos + 3) == "true" then return true, pos + 4 end
    elseif c == "f" then
        if s:sub(pos, pos + 4) == "false" then return false, pos + 5 end
    elseif c == "n" then
        if s:sub(pos, pos + 3) == "null" then
            return (opts and opts.keep_null) and M.null or nil, pos + 4
        end
    elseif c == "-" or c:match("%d") then
        return decode_number(s, pos)
    end
    decode_error(s, pos, "无法识别的值（NaN、Infinity、注释、单引号都不合法）")
end

-- 返回 值 或 nil, 原因
function M.decode(s, opts)
    if type(s) ~= "string" then return nil, "不是字符串" end
    -- 不接受 UTF-8 BOM：Python 的 json.loads 遇到 BOM 会报错，离线分析读不了
    if s:sub(1, 3) == "\239\187\191" then return nil, "文件以 UTF-8 BOM 开头（Python json 读不了）" end
    local ok, v, pos = pcall(decode_at, s, 1, opts, 0)
    if not ok then return nil, v end
    pos = skip_ws(s, pos)
    if pos <= #s then return nil, "JSON 结尾有多余内容（位置 " .. pos .. "）" end
    return v
end

return M

-- tools/mock/mock_ref.lua：假的 REFramework Lua API（只给模拟测试用，不进游戏）
--
-- 提供 sdk / re / imgui / draw / log / json / fs / ValueType 和可控的 os.clock，
-- 每个被测脚本用 load(源码, 名字, "t", env) 在各自独立的环境表里运行（模拟「脚本互不可见」）。
--
-- 设计取舍（为什么这样做）：
--   - 假对象的 call(self, "方法(签名)", ...) 按方法名分派；没模拟到的方法记一条 UNMOCKED 并返回 nil，
--     不崩溃——被测脚本是别人并行写的，mock 必须足够通用，缺口要「看得见」而不是「跑不动」。
--   - 类型库里登记过签名的方法会核对签名：签名写错在 REF 里会拿到 nil / 报错，这里记 SIG_MISMATCH。
--   - 钩子参数用不透明的「指针」对象：真 REF 里 args[i] 是 userdata，直接做算术会报错，
--     必须先 sdk.to_int64 / sdk.to_float / sdk.to_managed_object，这里同样强制。
--   - 所有「有副作用」的调用（不是 get/is/check/find/calc 开头的方法、对游戏对象 set_field、
--     钩子里跳过原函数 / 改返回值 / 改参数、sdk.create_instance）都按脚本记账，
--     run.lua 据此断言「rc 只调 changeActionRequest，探针一个都不调」。
--   - REF 的引用记账有两种模型（docs/autoparry/V16.md 第 5.1、8.1 节，见下面「REF 引用记账」一节）：
--       real（默认）= REF 的真实语义：同一地址全状态共用一份计数，脚本拿到的是「句柄」，句柄回收时刻可观测，
--                     游戏放手且没有 Lua 引用时对象销毁，之后再访问记 DEAD_OBJECT；
--       legacy      = 旧的按脚本计数（rc1 归档版和 --smoke 的冒烟脚本按 rc1 口径写、会手动 release）。
--   - json.dump_file 比 REF 更严：拒绝 NaN、inf、userdata、函数、混合键、稀疏数组、坏 UTF-8。

local json_lite = require("json_lite")

local M = {}
M.json = json_lite

local host_clock = os.clock
local unpack = table.unpack
local pack = table.pack

-- ---------- 小工具 ----------

-- 游戏里的 System.Single：按单精度取整，读出来就是 19.329999923706055 这种「带尾巴」的浮点
local function f32(x)
    if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then return x end
    return (string.unpack("<f", string.pack("<f", x)))
end
M.f32 = f32

-- 可复现的伪随机数（splitmix64），模拟和被测脚本里的 math.random 都用它
function M.make_rng(seed)
    local s = math.tointeger(seed) or math.floor(seed or 0)
    local rng = {}
    local function next_u64()
        s = s + 0x9E3779B97F4A7C15
        local z = s
        z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ~ (z >> 27)) * 0x94D049BB133111EB
        return z ~ (z >> 31)
    end
    function rng.seed(x) s = math.tointeger(x) or math.floor(tonumber(x) or 0) end
    function rng.float() return (next_u64() >> 11) * (1.0 / 9007199254740992.0) end
    function rng.random(m, n)
        if m == nil then return rng.float() end
        if n == nil then m, n = 1, m end
        m, n = math.tointeger(m), math.tointeger(n)
        if not m or not n then error("bad argument to 'random' (number has no integer representation)", 2) end
        if m > n then error("bad argument #2 to 'random' (interval is empty)", 2) end
        return m + math.floor(rng.float() * (n - m + 1))
    end
    function rng.range(a, b) return a + (b - a) * rng.float() end
    return rng
end

local sig_cache = {}
-- "name(A, B)" -> "name", "(A,B)"；没有括号时 params = nil
local function parse_sig(sig)
    local c = sig_cache[sig]
    if c then return c[1], c[2] end
    local name, params = sig:match("^%s*([^%(%s]+)%s*(%b())%s*$")
    if name then
        params = params:gsub("%s+", "")
    else
        name = sig:match("^%s*(.-)%s*$")
        params = nil
    end
    sig_cache[sig] = { name, params }
    return name, params
end
M.parse_sig = parse_sig

-- "<Foo>k__BackingField" <-> "Foo"
local function backing_alias(name)
    local inner = name:match("^<(.+)>k__BackingField$")
    if inner then return inner end
    return "<" .. name .. ">k__BackingField"
end

-- 读接口的前缀：其余方法一律当作「有副作用」（宁可多记）
local READ_PREFIX = { "get", "Get", "is", "Is", "check", "find", "calc", "has", "Has", "To",
    "Equals", "equals", "GetHashCode", "op_", "contains", "Contains", "compare", "Compare", "test", "IndexOf" }
local write_cache = {}
local function is_write_method(name)
    local c = write_cache[name]
    if c ~= nil then return c end
    c = true
    for _, p in ipairs(READ_PREFIX) do
        if name:sub(1, #p) == p then c = false break end
    end
    write_cache[name] = c
    return c
end
M.is_write_method = is_write_method

-- ---------- 元表：类型定义 / 字段 / 方法 / 托管对象 / 值类型 / 指针 / 向量 ----------

local TD, FD, MD = {}, {}, {}
local OBJ, VT, PTR, VEC, NATIVE = {}, {}, {}, {}, {}
-- HANDLE = 脚本手里的托管对象（每个脚本、每个地址、每一代一个）；SHARED = REF 的共享 userdata（每个地址当前一代一个，
-- 脚本看不见）。见「REF 引用记账」一节
local HANDLE, SHARED = {}, {}
M.OBJ, M.VT, M.PTR, M.VEC, M.HANDLE, M.SHARED = OBJ, VT, PTR, VEC, HANDLE, SHARED
local WEAK_V = { __mode = "v" }

local function is_mock_ud(v)
    local mt = getmetatable(v)
    return mt == OBJ or mt == HANDLE or mt == VT or mt == PTR or mt == VEC or mt == TD or mt == FD or mt == MD
        or mt == NATIVE
end
M.is_mock_userdata = is_mock_ud
json_lite.is_userdata = is_mock_ud

-- 句柄 → 游戏对象（脚本把对象当参数传回游戏时在入口拆包）；不是句柄原样返回
local function unwrap(v)
    if getmetatable(v) == HANDLE then return rawget(rawget(v, "__s"), "__o") end
    return v
end
M.unwrap = unwrap

local function unwrap_args(...)
    local n = select("#", ...)
    if n == 0 then return end
    if n == 1 then return unwrap((...)) end
    local t = pack(...)
    for i = 1, n do t[i] = unwrap(t[i]) end
    return unpack(t, 1, n)
end

-- 指针：真 REF 里钩子参数是 userdata，不能直接做算术
PTR.__name = "mock_ptr"
PTR.__tostring = function(p) return string.format("userdata: %016X", rawget(p, "v") & 0x7FFFFFFFFFFFFFFF) end
PTR.__eq = function(a, b) return rawget(a, "kind") == rawget(b, "kind") and rawget(a, "v") == rawget(b, "v") end
PTR.__index = function(_, k) error("attempt to index a userdata value (field '" .. tostring(k) .. "')", 2) end
local function ptr_arith() error("attempt to perform arithmetic on a userdata value（钩子参数要先用 sdk.to_int64 / sdk.to_float 转换）", 2) end
for _, mm in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm", "__idiv", "__band", "__bor",
    "__bxor", "__shl", "__shr", "__bnot", "__lt", "__le", "__len" }) do PTR[mm] = ptr_arith end
PTR.__concat = function() error("attempt to concatenate a userdata value", 2) end

local function new_ptr(kind, v, f)
    return setmetatable({ kind = kind, v = v, f = f }, PTR)
end

-- 向量（REF 把 via.vec3 转成 Vector3f：.x .y .z，可做加减乘）
VEC.__name = "Vector3f"
VEC.__tostring = function(v) return string.format("Vector3f(%.3f, %.3f, %.3f)", rawget(v, "x"), rawget(v, "y"), rawget(v, "z")) end
local function vec(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, VEC) end
M.vec = vec
local VEC_METHODS = {}
function VEC_METHODS.length(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
function VEC_METHODS.normalized(v)
    local l = VEC_METHODS.length(v)
    if l == 0 then return vec(0, 0, 0) end
    return vec(v.x / l, v.y / l, v.z / l)
end
function VEC_METHODS.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function VEC_METHODS.cross(a, b) return vec(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
function VEC_METHODS.to_vec3(v) return vec(v.x, v.y, v.z) end
VEC.__index = function(v, k)
    local m = VEC_METHODS[k]
    if m then return m end
    if k == "w" then return 0.0 end
    return nil
end
VEC.__add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
VEC.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
VEC.__mul = function(a, b)
    if type(a) == "number" then return vec(a * b.x, a * b.y, a * b.z) end
    if type(b) == "number" then return vec(a.x * b, a.y * b, a.z * b) end
    return vec(a.x * b.x, a.y * b.y, a.z * b.z)
end
VEC.__unm = function(a) return vec(-a.x, -a.y, -a.z) end

-- ---------- World ----------

local World = {}
World.__index = World
M.World = World

local SKIP_ORIGINAL = 1

function M.new_world(opts)
    opts = opts or {}
    local w = setmetatable({}, World)
    w.opts = opts
    w.out_dir = opts.out_dir or "."
    w.t = 0.0
    w.dt = opts.dt or (1 / 90)
    w.frame = 0
    w.phase = "load"
    -- 帧内各阶段的时钟偏移：钩子里的 os.clock 比帧开头略晚（真实游戏也是这样）
    w.phase_offset = { load = 0.0, pre = 0.0, update = 0.001, post = 0.0015, hit = 0.002, late = 0.0025,
        frame = 0.003, ui = 0.0035, reset = 0.004 }
    w.clock_base = opts.clock_base or 1000.0
    w.wall_base = opts.wall_base or os.time({ year = 2026, month = 10, day = 10, hour = 16, min = 0, sec = 0 })
    w.next_addrs = {}           -- 各地址段的下一个地址（见 alloc_addr）
    w.objects = setmetatable({}, { __mode = "v" })
    w.vts = setmetatable({}, { __mode = "v" })
    w.types = {}
    w.mdefs = {}
    w.fdefs = {}
    w.type_handlers = {}
    w.resolve_cache = {}
    w.method_closures = {}
    w.hooks = {}
    w.hook_regs = {}
    w.cb = {}
    w.cb_order = {}
    w.scripts = {}
    w.script_order = {}
    w.ctx = {}
    w.logs = {}
    w.notes = {}
    w.note_order = {}
    w.violations = {}
    w.effects = {}
    -- 引用记账（见「REF 引用记账」）。refs / ref_objs / ref_totals 只给 legacy 模型（按脚本计数）用
    w.ref_model = opts.ref_model or "real"
    w.refs = {}
    w.ref_objs = {}
    w.ref_totals = {}
    w.ref_events = {}           -- 脚本的 add_ref / release 调用：{ t, s = 脚本, addr, d = +1 / -1 }
    w.ref_counts = {}           -- [脚本] = { ADD_REF, ADD_REF_NOOP, MANUAL_RELEASE, OVER_RELEASE, FORCE_RELEASE, ADD_REF_PERMANENT }
    w.gc_unmanaged = 0          -- 共享 userdata 回收时计数已经是 0（手动 release 之后的正常现象，不算违规）
    w.rstates = {}              -- [地址] = 游戏对象状态（强持有；只为推入过脚本或游戏管理引用的对象建）
    w.shared_cache = setmetatable({}, WEAK_V)   -- [地址] = 当前一代的共享 userdata
    w.hcache = {}               -- [脚本] = 弱值表 [地址] = 句柄
    w.hrecs = {}                -- [地址] = { 句柄记录 }：只记 track_types 里的类型（持有时长、峰值都看它）
    w.track_types = { ["app.AttackAreaResult"] = true }
    w.handle_closures = {}
    w.gc_due = false            -- 本帧新建了 track_types 的句柄：帧末要回收一次（同时持有峰值只可能在这时变大）
    w.menu_seen = {}            -- [脚本] = { [菜单文字] = 第一次出现的时刻 }（菜单每次 UI 阶段重画，中途的状态行靠它查）
    w.json_writes = {}
    w.files = {}
    w.file_order = {}
    w.hud = {}
    w.hud_window = {}
    w.menu = {}
    w.ui_actions = {}
    w.ui_stack = nil
    w.perf = {}
    w.frame_cost = {}
    w.singletons = {}
    w.native_singletons = {}
    w.native_handlers = {}
    w.requests = {}
    w.prints = {}
    w.auto_enum_next = 9001
    w.faults = {}
    w.fault_names = {}
    w.missing = {}
    w.draw_throws = false
    w.allowed_hooks = nil
    w.forbidden_hooks = {}
    for k in pairs(M.FORBIDDEN_HOOK_NAMES) do w.forbidden_hooks[k] = true end
    w.native_types = {}
    w.ctx_ptr = new_ptr("int", 0x7FF600001000)
    for _, f in ipairs(opts.faults or {}) do w:add_fault(f) end
    M.declare_builtin_types(w)
    return w
end

-- ---------- 时间 ----------

function World:clock()
    return self.clock_base + self.t + (self.phase_offset[self.phase] or 0.0)
end

function World:wall_time()
    return self.wall_base + math.floor(self.t)
end

function World:timestamp()
    local wall = self.wall_base + self.t + (self.phase_offset[self.phase] or 0.0)
    local sec = math.floor(wall)
    local ms = math.floor((wall - sec) * 1000)
    return os.date("%Y-%m-%d %H:%M:%S", sec) .. string.format(".%03d", ms)
end

-- ---------- 记录 ----------

function World:cur_script() return self.ctx[#self.ctx] end

-- 不算失败的观察项（UNMOCKED、自动枚举等），按 kind+key 去重计数
function World:note(kind, key, script)
    script = script or self:cur_script() or "game"
    local id = kind .. " " .. key
    local n = self.notes[id]
    if not n then
        n = { kind = kind, key = key, count = 0, scripts = {}, first_t = self.t }
        self.notes[id] = n
        self.note_order[#self.note_order + 1] = id
    end
    n.count = n.count + 1
    n.scripts[script] = true
end

-- 违规：run.lua 会判失败（除非场景声明允许）
function World:violation(kind, msg, script)
    script = script or self:cur_script() or "game"
    local key = kind .. "|" .. script .. "|" .. msg
    for _, v in ipairs(self.violations) do
        if v.key == key then
            v.count = v.count + 1
            return
        end
    end
    self.violations[#self.violations + 1] = { key = key, kind = kind, msg = msg, script = script, t = self.t,
        frame = self.frame, count = 1 }
end

function World:log_raw(level, text)
    self.logs[#self.logs + 1] = { t = self.t, frame = self.frame, phase = self.phase, level = level, text = text,
        script = self:cur_script(), ts = self:timestamp() }
end

-- ---------- 类型库 ----------

function World:declare_type(name, spec)
    local td = self.types[name]
    if not td then
        td = setmetatable({ name = name, w = self, msig = {}, mlist = {}, fields = {}, flist = {}, statics = {},
            slist = {}, generic = false }, TD)
        self.types[name] = td
    end
    spec = spec or {}
    if spec.parent then td.parent = spec.parent end
    if spec.short then td.short = spec.short end
    if spec.vt ~= nil then td.vt = spec.vt end
    if spec.generic then td.generic = true end
    if spec.enum then
        td.enum = true
        td.vt = true
        td.parent = td.parent or "System.Enum"
    end
    for _, s in ipairs(spec.methods or {}) do self:declare_method(td, s) end
    for _, f in ipairs(spec.fields or {}) do
        if not td.fields[f] then
            td.fields[f] = true
            td.flist[#td.flist + 1] = f
        end
    end
    if spec.values then
        local names = {}
        for k in pairs(spec.values) do names[#names + 1] = k end
        table.sort(names, function(a, b)
            local va, vb = spec.values[a], spec.values[b]
            if va == vb then return a < b end
            return va < vb
        end)
        for _, k in ipairs(names) do self:declare_static(td, k, spec.values[k]) end
    end
    return td
end

function World:declare_method(td, s)
    local name, params = parse_sig(s)
    local norm = name .. (params or "()")
    local list = td.msig[name]
    if not list then
        list = {}
        td.msig[name] = list
    end
    for _, x in ipairs(list) do if x == norm then return end end
    list[#list + 1] = norm
    td.mlist[#td.mlist + 1] = norm
end

function World:declare_static(td, name, value)
    if td.statics[name] == nil then td.slist[#td.slist + 1] = name end
    td.statics[name] = value
end

function World:get_type(name)
    return self.types[name]
end

-- 脚本用的 sdk.find_type_definition：没登记的类型给一个通用类型（记 UNMOCKED_TYPE），
-- 故障注入可以让指定类型「不存在」（返回 nil）
function World:find_type(name)
    if type(name) ~= "string" then error("bad argument #1 to 'find_type_definition' (string expected)", 3) end
    if self.missing["type:" .. name] then return nil end
    local td = self.types[name]
    if td then return td end
    self:note("UNMOCKED_TYPE", name)
    return self:declare_type(name, { parent = "System.Object", generic = true })
end

function World:auto_enum(td, name)
    local v = self.auto_enum_next
    self.auto_enum_next = v + 1
    self:declare_static(td, name, v)
    self:note("AUTOENUM", td.name .. "." .. name .. "=" .. v)
    return v
end

-- 游戏模拟器取枚举值用（不存在就自动分配）
function World:enum(type_name, name)
    local td = self.types[type_name] or self:declare_type(type_name, { enum = true })
    local cur = td
    while cur do
        local v = cur.statics[name]
        if v ~= nil then return v end
        cur = cur.parent and self.types[cur.parent]
    end
    return self:auto_enum(td, name)
end

function World:enum_name(type_name, value)
    local td = self.types[type_name]
    if not td then return tostring(value) end
    for _, k in ipairs(td.slist) do
        if td.statics[k] == value then return k end
    end
    return tostring(value)
end

function World:chain(td)
    local list = {}
    local cur = td
    while cur do
        list[#list + 1] = cur
        cur = cur.parent and self.types[cur.parent]
        if #list > 32 then break end
    end
    return list
end

function World:method_def(td, norm, generic)
    local key = td.name .. "." .. norm
    local md = self.mdefs[key]
    if not md then
        local name = norm:match("^([^%(]+)")
        md = setmetatable({ td = td, norm = norm, name = name, key = key, generic = generic or false, w = self }, MD)
        self.mdefs[key] = md
    end
    return md
end

function World:field_def(td, name, static, value)
    local key = td.name .. "." .. name
    local fd = self.fdefs[key]
    if not fd then
        fd = setmetatable({ td = td, name = name, static = static, w = self }, FD)
        self.fdefs[key] = fd
    end
    if value ~= nil then fd.value = value end
    return fd
end

-- 类型定义（脚本可见的 RETypeDefinition）
TD.__name = "sdk::RETypeDefinition"
TD.__tostring = function(td) return "RETypeDefinition(" .. td.name .. ")" end
local TD_METHODS = {}
TD.__index = function(td, k) return TD_METHODS[k] end

function TD_METHODS.get_full_name(td) return td.name end
function TD_METHODS.get_name(td)
    local n = td.name:gsub("%b<>", "")
    return n:match("([^%.]+)$") or td.name
end
function TD_METHODS.get_namespace(td) return td.name:match("^(.*)%.[^%.]+$") or "" end
function TD_METHODS.get_parent_type(td) return td.parent and td.w.types[td.parent] or nil end
function TD_METHODS.is_value_type(td) return td.vt == true end
function TD_METHODS.is_enum(td) return td.enum == true end
function TD_METHODS.get_size(td) return 0x50 end
function TD_METHODS.is_a(td, other)
    local name = other
    if getmetatable(other) == TD then name = other.name end
    if type(name) ~= "string" then error("is_a: 参数必须是类型名或类型定义", 2) end
    for _, t in ipairs(td.w:chain(td)) do
        if t.name == name then return true end
    end
    return false
end
function TD_METHODS.get_method(td, sig)
    local w = td.w
    if type(sig) ~= "string" then error("bad argument #1 to 'get_method' (string expected)", 2) end
    local name, params = parse_sig(sig)
    if w.missing["method:" .. td.name .. "." .. name] then return nil end
    local name_seen = false
    for _, cur in ipairs(w:chain(td)) do
        local list = cur.msig[name]
        if list then
            name_seen = true
            for _, norm in ipairs(list) do
                if params == nil or norm == name .. params then return w:method_def(cur, norm) end
            end
        end
    end
    if name_seen then
        w:violation("SIG_MISMATCH", td.name .. ":get_method(\"" .. sig .. "\") 的参数签名和类型库不一致（REF 会返回 nil）")
        return nil
    end
    w:note("UNMOCKED_METHOD", td.name .. "." .. name .. (params or "()"))
    return w:method_def(td, name .. (params or "()"), true)
end
function TD_METHODS.get_methods(td)
    local out = {}
    for _, norm in ipairs(td.mlist) do out[#out + 1] = td.w:method_def(td, norm) end
    return out
end
function TD_METHODS.get_field(td, name)
    local w = td.w
    if type(name) ~= "string" then error("bad argument #1 to 'get_field' (string expected)", 2) end
    if w.missing["field:" .. td.name .. "." .. name] then return nil end
    for _, cur in ipairs(w:chain(td)) do
        if cur.statics[name] ~= nil then return w:field_def(cur, name, true, cur.statics[name]) end
        if cur.fields[name] then return w:field_def(cur, name, false) end
        local alias = backing_alias(name)
        if cur.fields[alias] then return w:field_def(cur, alias, false) end
    end
    if td.enum or td.generic then
        return w:field_def(td, name, true, w:auto_enum(td, name))
    end
    w:note("UNMOCKED_FIELD", td.name .. "." .. name)
    return nil
end
function TD_METHODS.get_fields(td)
    local w = td.w
    local out = {}
    -- 故障 missing 的 "field:<类型>.<名字>" 对静态字段也生效（模拟游戏更新删了枚举名：遍历和按名字取都拿不到）
    for _, n in ipairs(td.slist) do
        if not w.missing["field:" .. td.name .. "." .. n] then out[#out + 1] = w:field_def(td, n, true, td.statics[n]) end
    end
    if td.enum then out[#out + 1] = w:field_def(td, "value__", false) end
    for _, n in ipairs(td.flist) do out[#out + 1] = w:field_def(td, n, false) end
    return out
end
function TD_METHODS.get_runtime_type(td) return td.w:wrap(td.w:cur_script(), td.w:typeof(td.name)) end
function TD_METHODS.create_instance(td)
    td.w:record_effect_raw("create_instance", td.name)
    return td.w:wrap(td.w:cur_script(), td.w:new_object(td.name, { space = "aux" }))
end

-- 字段定义
FD.__name = "sdk::REField"
FD.__tostring = function(fd) return "REField(" .. fd.td.name .. "." .. fd.name .. ")" end
local FD_METHODS = {}
FD.__index = function(_, k) return FD_METHODS[k] end
function FD_METHODS.get_name(fd) return fd.name end
function FD_METHODS.is_static(fd) return fd.static == true end
function FD_METHODS.get_declaring_type(fd) return fd.td end
function FD_METHODS.get_type(fd)
    if fd.static and fd.td.enum then return fd.td end
    return fd.w.types["System.Object"]
end
function FD_METHODS.get_offset_from_base(_) return 0x10 end
function FD_METHODS.get_offset_from_fieldptr(_) return 0x0 end
function FD_METHODS.get_flags(fd) return fd.static and 0x10 or 0 end
function FD_METHODS.get_data(fd, obj)
    if fd.static then
        if obj ~= nil then fd.w:note("FIELD_STATIC_WITH_OBJ", fd.td.name .. "." .. fd.name) end
        return fd.td.statics[fd.name]
    end
    if obj == nil then
        fd.w:note("FIELD_INSTANCE_NIL_OBJ", fd.td.name .. "." .. fd.name)
        return nil
    end
    return obj:get_field(fd.name)
end

-- 方法定义
MD.__name = "sdk::REMethodDefinition"
MD.__tostring = function(md) return "REMethodDefinition(" .. md.key .. ")" end
local MD_METHODS = {}
MD.__index = function(_, k) return MD_METHODS[k] end
function MD_METHODS.get_name(md) return md.name end
function MD_METHODS.get_declaring_type(md) return md.td end
function MD_METHODS.get_return_type(md) return md.w.types["System.Object"] end
function MD_METHODS.get_num_params(md)
    local p = md.norm:match("%((.*)%)")
    if not p or p == "" then return 0 end
    local n = 1
    local depth = 0
    for c in p:gmatch(".") do
        if c == "<" then depth = depth + 1 elseif c == ">" then depth = depth - 1
        elseif c == "," and depth == 0 then n = n + 1 end
    end
    return n
end
function MD_METHODS.is_static(_) return false end
function MD_METHODS.get_function(_) return 0x140000000 end
function MD_METHODS.call(md, obj, ...)
    if obj == nil then
        md.w:note("UNMOCKED", "static call " .. md.key)
        return nil
    end
    local w = md.w
    return w:wrap_out(w:cur_script(), w:obj_call(unwrap(obj), md.norm, unwrap_args(...)))
end

-- ---------- 对象 ----------

-- 地址分三段（docs/autoparry/MERGE.md 第 6.3 节的逐刀等价测试要逐字比较 FIRE 的 ent / res）：
--   game = 游戏模拟器建的对象（主角、怪物、消息、受击信息……，默认）；
--   atk  = 攻击相关的对象（预告结果、条目、条目列表、攻击参数），只由场景的攻击事件按时间创建；
--   aux  = 值类型、sdk.typeof 的 System.Type、原生单例、脚本自己建的对象、按需生成的列表。
-- 为什么分：被测脚本每读一次动作 ID 就会多一个值类型。合并版比 v1.6 多了防御那一半的读取，地址要是共用一个计数器，
-- 之后建的预告结果、条目地址就整体错开，FIRE 的 ent / res 永远对不上；分开以后结果和条目的地址只取决于场景的攻击时刻
local ADDR_BASE = { game = 0x24A8C10000, atk = 0x3C00000000, aux = 0x5B00000000 }
function World:alloc_addr(size, space)
    space = space or "game"
    self.next_addrs = self.next_addrs or {}
    local a = self.next_addrs[space] or ADDR_BASE[space] or ADDR_BASE.game
    self.next_addrs[space] = a + (size or 0x120)
    return a
end

-- spec = { fields = {}, getters = { name = fn(obj) }, methods = { name = fn(obj, ...) }, data = {},
--          game_refs = 游戏自己的引用（默认 1 = 游戏一直拿着；game_release 放手），
--          is_local = true（局部对象：REF 推入时不加引用，游戏这次调用结束（end_scope）前不算 0 引用），
--          space = "game" | "atk" | "aux"（地址段，见 alloc_addr） }
function World:new_object(type_name, spec)
    spec = spec or {}
    local td = self.types[type_name] or self:declare_type(type_name, { parent = "System.Object" })
    local addr = self:alloc_addr(spec.size, spec.space)
    local o = setmetatable({}, OBJ)
    rawset(o, "__w", self)
    rawset(o, "__t", td)
    rawset(o, "__addr", addr)
    rawset(o, "__f", spec.fields or {})
    rawset(o, "__g", spec.getters or {})
    rawset(o, "__m", spec.methods or {})
    rawset(o, "__d", spec.data or {})
    rawset(o, "__alive", true)
    rawset(o, "__arr", spec.array)
    if spec.game_refs ~= nil then rawset(o, "__grefs", spec.game_refs) end
    if spec.is_local then rawset(o, "__local", true) end
    self.objects[addr] = o
    return o
end

-- 游戏强行销毁（不看引用，旧场景的主角换人这样用）：之后脚本再访问记 DEAD_OBJECT
function World:destroy(o)
    if o and getmetatable(o) == OBJ then
        rawset(o, "__alive", false)
        local st = rawget(o, "__st")
        if st and st.alive then
            st.alive, st.t_destroy, st.forced = false, self.t, true
        end
    end
end

function World:new_vt(type_name, fields, opts)
    local td = self.types[type_name] or self:declare_type(type_name, { parent = "System.ValueType", vt = true })
    local v = setmetatable({}, VT)
    rawset(v, "__w", self)
    rawset(v, "__t", td)
    rawset(v, "__addr", self:alloc_addr(0x20, "aux"))
    rawset(v, "__f", fields or {})
    rawset(v, "__m", opts and opts.methods or {})
    rawset(v, "__script_made", opts and opts.script_made or false)
    self.vts[rawget(v, "__addr")] = v
    return v
end

function World:data(o) return rawget(o, "__d") end

-- 类型级处理函数（同类型的所有对象共用）
function World:handler(type_name, name, fn)
    local h = self.type_handlers[type_name]
    if not h then
        h = {}
        self.type_handlers[type_name] = h
    end
    h[name] = fn
end

function World:find_handler(o, td, name)
    local h = rawget(o, "__m")[name]
    if h then return h end
    for _, cur in ipairs(self:chain(td)) do
        local th = self.type_handlers[cur.name]
        if th and th[name] then return th[name] end
    end
    return nil
end

-- 解析调用签名：返回 声明它的类型、规范化签名；参数签名对不上记 SIG_MISMATCH
function World:resolve_call(td, name, params, sig)
    local ck = td.name .. "|" .. sig
    local c = self.resolve_cache[ck]
    if c then return c[1], c[2] end
    local decl, norm
    local mismatch = false
    for _, cur in ipairs(self:chain(td)) do
        local list = cur.msig[name]
        if list then
            if params == nil then
                decl, norm = cur, list[1]
                break
            end
            for _, n in ipairs(list) do
                if n == name .. params then
                    decl, norm = cur, n
                    break
                end
            end
            if decl then break end
            mismatch = true
        end
    end
    if not decl and mismatch then
        self:violation("SIG_MISMATCH", td.name .. ":call(\"" .. sig .. "\") 的参数签名和类型库不一致")
    end
    self.resolve_cache[ck] = { decl or false, norm }
    return decl or nil, norm
end

-- 故障注入：{ key = "DetectedDataList.get_Item", mode = "throw"|"nil"|"value", value =, from =, to =, scripts = {名字=true}, max = 次数, msg =,
--             where = function(对象, world) → 布尔（只作用于满足条件的对象，例如某只怪的预告结果；不给就作用于这个类型的全部对象） }
--           { key = "type:app.X", mode = "missing" } / { key = "method:app.X.name" } / { key = "field:app.X._f" }
--           REF 自带 API 的故障（不是游戏方法）：key = "imgui.<函数名>"（mode = "throw"）、"json.dump_file"
--             （mode = "throw" | "false"，path = 只作用于匹配这个 Lua 模式的文件名，phase = 只在这个帧阶段，例如 "reset"）
function World:add_fault(f)
    if f.mode == "missing" then
        self.missing[f.key] = true
        return
    end
    if f.key == "draw.text" then
        self.draw_throws = f
        return
    end
    if f.key:match("^imgui%.") or f.key == "json.dump_file" or f.key == "json.load_file" then
        self.api_faults = self.api_faults or {}
        self.api_faults[#self.api_faults + 1] = f
        return
    end
    self.faults[#self.faults + 1] = f
    local name = f.key:match("%.([^%.]+)$")
    if name then self.fault_names[name] = true end
end

-- REF 自带 API 的故障：命中就计数并返回故障项（时间段、脚本、次数、文件名、帧阶段都按 add_fault 的约定过滤）
function World:api_fault(key, path)
    local script = self:cur_script() or self.ui_cur_script
    for _, f in ipairs(self.api_faults or {}) do
        if f.key == key and (not f.from or self.t >= f.from) and (not f.to or self.t < f.to)
            and (not f.scripts or (script and f.scripts[script])) and (not f.max or (f.hits or 0) < f.max)
            and (not f.phase or f.phase == self.phase) and (not f.path or (path and path:find(f.path) ~= nil)) then
            f.hits = (f.hits or 0) + 1
            return f
        end
    end
    return nil
end

function World:match_fault(td, name, o)
    local now = self.t
    local script = self:cur_script()
    for _, f in ipairs(self.faults) do
        if (not f.from or now >= f.from) and (not f.to or now < f.to)
            and (not f.scripts or (script and f.scripts[script]))
            and (not f.max or (f.hits or 0) < f.max)
            and (not f.phase or f.phase == self.phase)
            and (not f.where or (o ~= nil and f.where(o, self) == true)) then
            if f.key == "*." .. name then return f end
            for _, cur in ipairs(self:chain(td)) do
                if f.key == cur.name .. "." .. name or (cur.short and f.key == cur.short .. "." .. name) then
                    return f
                end
            end
        end
    end
    return nil
end

-- 神谕用：不消耗、指定脚本地看某个读取此刻会不会命中故障（max 限次的故障神谕预测不了，这类场景要用时间段）
function World:peek_fault(td, name, o, script)
    if not self.fault_names[name] then return nil end
    local now = self.t
    for _, f in ipairs(self.faults) do
        if (not f.from or now >= f.from) and (not f.to or now < f.to)
            and (not f.scripts or (script and f.scripts[script]))
            and (not f.phase or f.phase == self.phase)
            and (not f.where or (o ~= nil and f.where(o, self) == true)) then
            if f.key == "*." .. name then return f end
            for _, cur in ipairs(self:chain(td)) do
                if f.key == cur.name .. "." .. name or (cur.short and f.key == cur.short .. "." .. name) then
                    return f
                end
            end
        end
    end
    return nil
end

function World:apply_fault(f, what)
    f.hits = (f.hits or 0) + 1
    f.by = f.by or {}
    local s = self:cur_script() or "game"
    f.by[s] = (f.by[s] or 0) + 1
    if f.mode == "throw" then
        error(f.msg or ("Invoke threw an exception (mock: " .. what .. ")"), 0)
    elseif f.mode == "nil" then
        return true, nil
    elseif f.mode == "value" then
        if type(f.value) == "function" then return true, f.value(self) end
        return true, f.value
    end
    return false
end

function World:check_alive(o, what)
    if not rawget(o, "__alive") then
        local msg = string.format("访问已销毁的游戏对象 %s @%X（%s）", rawget(o, "__t").name, rawget(o, "__addr"), what)
        self:violation("DEAD_OBJECT", msg)
        error("mock: " .. msg .. "——真游戏里这可能直接崩溃", 0)
    end
end

local function describe(v)
    v = unwrap(v)
    local mt = getmetatable(v)
    if mt == OBJ then return string.format("%s@%X", rawget(v, "__t").name, rawget(v, "__addr")) end
    if mt == VT then
        local parts = {}
        local f = rawget(v, "__f")
        local keys = {}
        for k in pairs(f) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(f[k]) end
        return rawget(v, "__t").name .. "{" .. table.concat(parts, ",") .. "}"
    end
    if mt == PTR then return tostring(v) end
    if mt == VEC then return tostring(v) end
    return tostring(v)
end
M.describe = describe

-- 副作用记录的上下文：在哪个钩子的哪一段（pre / post）里发生的（合并版的副作用白名单按它判，MERGE 第 6.2 节第 4 条），
-- 以及模拟器给的注记（run.lua 设 effect_annotate：这一刻主角的动作，「钩子里现读动作」那条变异要靠它抓）
function World:effect_ctx(e)
    local hc = self.hook_ctx
    if hc then e.hook, e.stage = hc.key, hc.stage end
    if self.effect_annotate then
        for k, v in pairs(self.effect_annotate() or {}) do e[k] = v end
    end
    return e
end

function World:record_effect(o, td, name, sig, ...)
    local s = self:cur_script()
    if not s then return end
    local args = {}
    for i = 1, select("#", ...) do args[i] = describe((select(i, ...))) end
    self.effects[#self.effects + 1] = self:effect_ctx({ script = s, kind = "call", type = td.name, name = name, sig = sig,
        target = describe(o), args = args, t = self.t, frame = self.frame, phase = self.phase })
end

function World:record_effect_raw(kind, what)
    local s = self:cur_script()
    if not s then return end
    self.effects[#self.effects + 1] = self:effect_ctx({ script = s, kind = kind, type = "-", name = what, sig = what,
        target = "-", args = {}, t = self.t, frame = self.frame, phase = self.phase })
end

function World:obj_call(o, sig, ...)
    if type(sig) ~= "string" then error("bad argument #1 to 'call' (string expected, got " .. type(sig) .. ")", 3) end
    self:check_alive(o, "call " .. sig)
    local name, params = parse_sig(sig)
    local td = rawget(o, "__t")
    local decl, norm = self:resolve_call(td, name, params, sig)
    if self.fault_names[name] then
        local f = self:match_fault(td, name, o)
        if f then
            local handled, ret = self:apply_fault(f, td.name .. "." .. name)
            if handled then return ret end
        end
    end
    local h = self:find_handler(o, td, name)
    if is_write_method(name) then self:record_effect(o, td, name, sig, ...) end
    local key = decl and (decl.name .. "." .. norm) or nil
    local hooks = key and self.hooks[key]
    if hooks and #hooks > 0 then
        return self:invoke_hooked(o, key, h or function() return nil end, pack(...))
    end
    if not h then
        self:note("UNMOCKED", td.name .. "." .. name)
        return nil
    end
    return h(o, ...)
end

function World:field_declared(td, name)
    for _, cur in ipairs(self:chain(td)) do
        if cur.fields[name] then return true end
    end
    return false
end

function World:obj_get_field(o, name)
    if type(name) ~= "string" then error("bad argument #1 to 'get_field' (string expected)", 3) end
    self:check_alive(o, "get_field " .. name)
    local td = rawget(o, "__t")
    if self.fault_names[name] then
        local f = self:match_fault(td, name, o)
        if f then
            local handled, ret = self:apply_fault(f, td.name .. "." .. name)
            if handled then return ret end
        end
    end
    local g = rawget(o, "__g")
    local fv = rawget(o, "__f")
    local getter = g[name]
    if getter then return getter(o) end
    local v = fv[name]
    if v ~= nil then return v end
    local alias = backing_alias(name)
    getter = g[alias]
    if getter then return getter(o) end
    v = fv[alias]
    if v ~= nil then return v end
    if self:field_declared(td, name) or self:field_declared(td, alias) then return nil end
    self:note("UNMOCKED_FIELD", td.name .. "." .. name)
    return nil
end

function World:obj_set_field(o, name, value)
    if type(name) ~= "string" then error("bad argument #1 to 'set_field' (string expected)", 3) end
    self:check_alive(o, "set_field " .. name)
    local td = rawget(o, "__t")
    local s = self:cur_script()
    if s then
        self.effects[#self.effects + 1] = self:effect_ctx({ script = s, kind = "set_field", type = td.name, name = name,
            sig = "set_field " .. name, target = describe(o), args = { describe(value) }, t = self.t,
            frame = self.frame, phase = self.phase })
    end
    local g = rawget(o, "__g")
    if g[name] then
        -- 动态字段被脚本改写：不改模拟状态（记账即可，探针和 rc 都不该写）
        return
    end
    rawget(o, "__f")[name] = value
end

function World:has_method(o, td, k)
    if self:find_handler(o, td, k) then return true end
    for _, cur in ipairs(self:chain(td)) do
        if cur.msig[k] then return true end
    end
    return false
end

-- REF 语法糖：obj:get_Name() / obj._Field（游戏模拟器自己用原始对象走这里；脚本的句柄走 handle_index）
function World:obj_index(o, k)
    if type(k) ~= "string" then return nil end
    local td = rawget(o, "__t")
    if self:has_method(o, td, k) then
        local c = self.method_closures[k]
        if not c then
            c = function(self_obj, ...) return rawget(self_obj, "__w"):obj_call(self_obj, k, ...) end
            self.method_closures[k] = c
        end
        return c
    end
    local fv = rawget(o, "__f")
    if rawget(o, "__g")[k] or fv[k] ~= nil or self:field_declared(td, k) then
        return self:obj_get_field(o, k)
    end
    self:note("UNMOCKED_MEMBER", td.name .. "." .. k)
    return nil
end

-- ---------- REF 引用记账（docs/autoparry/V16.md 第 5.1、8.1 节；REF 源码 src/mods/bindings/Sdk.cpp 核对过） ----------
--
-- real（默认）= REF 的真实语义：
--   · 游戏对象状态（rstates，World 强持有，按地址）：alive、game_refs（游戏自己的引用，game_sim 设置，默认 1 =
--     游戏一直拿着）、lua_count（REF 的共享计数：整个 Lua 状态一份，所有 autorun 脚本共用）、is_local（局部对象：
--     REF 推入时不加引用）、scope（局部对象在游戏这次调用结束前不算 0 引用）。
--   · 共享 userdata（SHARED）：每个地址当前一代一个，放在弱值缓存里，带 __gc（= userdata 回收时 REF 的自动 release）。
--     对象交给脚本（方法 / 字段返回值、sdk.to_managed_object、单例、钩子参数转换）时走「推入」：缓存里有活着的就用它；
--     没有就新建一代，非局部对象 lua_count + 1。
--   · 脚本句柄（HANDLE）：每个脚本、每个地址、每一代一个（脚本各自的弱值缓存），带 __gc（记回收时刻），强引用共享
--     userdata、把所有方法转发过去。出口包装、入口拆包，所以脚本永远拿不到原始对象：既保持「全状态共用一份」的计数
--     语义，又能知道每个脚本什么时候丢掉了引用（V16 第 8.2 节第 3 条的观测方式）。
--   · add_ref：lua_count > 0 时空操作（ADD_REF_NOOP）；否则 lua_count = 1（局部对象才真正加一份）。
--   · release：记 MANUAL_RELEASE（按脚本）；lua_count > 0 时减一，到 0 时把地址从共享缓存删掉（之后再推入就是
--     新的一代）；已经是 0 → 写 REF 的告警行、记 OVER_RELEASE（违规）。
--   · 共享 userdata 回收：lua_count > 0 时减一；已经是 0 → 写同样的告警行，只记 GC_UNMANAGED（手动 release 之后
--     的正常现象）。旧一代被回收时扣的是当前计数 —— 这正是 REF 的跨代隐患，模型照样重现。
--   · 销毁：game_refs + lua_count 归零的那一刻 alive = false（记 t_destroy）。之后任何脚本通过句柄 call /
--     get_field / set_field / add_ref / release → DEAD_OBJECT（按脚本、带时刻和类型）；get_address 不解引用，允许。
--   · force_release、add_ref_permanent 是违规。
-- legacy = 旧的按脚本计数（--smoke 的冒烟脚本和 rc1 归档版按 rc1 口径写、会手动 release，V16 第 8.1 节）：
--   add_ref / release 按脚本、按对象计数，某个脚本 release 多于 add_ref 记 OVER_RELEASE；不按引用销毁对象。
--   句柄照样用：持有时长、同时持有峰值两种模型都按句柄回收时刻观测。

local REF_WARN = "REManagedObject:release attempted to release an object that was not managed by our Lua state"

function World:rstate(o)
    local st = rawget(o, "__st")
    if st then return st end
    local loc = rawget(o, "__local") == true
    st = { addr = rawget(o, "__addr"), tname = rawget(o, "__t").name, game_refs = rawget(o, "__grefs") or 1,
        lua_count = 0, is_local = loc, scope = loc, gen = 0, alive = rawget(o, "__alive") ~= false }
    rawset(o, "__st", st)
    self.rstates[st.addr] = st
    return st
end

function World:ref_counts_of(script)
    local c = self.ref_counts[script]
    if not c then
        c = { ADD_REF = 0, ADD_REF_NOOP = 0, MANUAL_RELEASE = 0, OVER_RELEASE = 0, FORCE_RELEASE = 0,
            ADD_REF_PERMANENT = 0 }
        self.ref_counts[script] = c
    end
    return c
end

-- game_refs + lua_count 归零就销毁（只在 real 模型里；局部对象在 scope 结束前不算）
function World:maybe_destroy(st, o)
    if self.ref_model ~= "real" then return end
    if st.alive and not st.scope and st.game_refs + st.lua_count <= 0 then
        st.alive, st.t_destroy = false, self.t
        if o then
            rawset(o, "__alive", false)
            -- 对象自己持有的子对象（结果对象的条目列表、条目……）随它一起放手：只要还有 Lua 引用把它保活，
            -- 它的子对象也就还活着（游戏放手 ≠ 销毁）
            local f = rawget(o, "__on_destroy")
            if f then f() end
        end
    end
end

-- 游戏放手（结果对象 IsAttackFinished 之后、怪物消失）：game_refs − 1
function World:game_release(o)
    if getmetatable(o) ~= OBJ then return end
    local st = self:rstate(o)
    if st.game_refs > 0 then st.game_refs = st.game_refs - 1 end
    self:maybe_destroy(st, o)
end

-- 局部对象：游戏这次调用结束（之后只剩 REF 的引用能保活）
function World:end_scope(o)
    if getmetatable(o) ~= OBJ then return end
    local st = self:rstate(o)
    if st.scope then
        st.scope = false
        self:maybe_destroy(st, o)
    end
end

-- 推入：把游戏对象交给某个脚本，返回这个脚本的句柄
function World:push(o, script)
    if not rawget(o, "__alive") then
        self:violation("DEAD_OBJECT", string.format("游戏把已销毁的对象 %s@%X 交给了脚本（mock 的模拟器问题）",
            rawget(o, "__t").name, rawget(o, "__addr")), script)
    end
    local st = self:rstate(o)
    local addr = st.addr
    local sh = self.shared_cache[addr]
    if sh == nil then
        st.gen = st.gen + 1
        sh = setmetatable({ __o = o, __w = self, __st = st, __gen = st.gen }, SHARED)
        self.shared_cache[addr] = sh
        if self.ref_model == "real" and not st.is_local then st.lua_count = st.lua_count + 1 end
    end
    local hc = self.hcache[script]
    if not hc then
        hc = setmetatable({}, WEAK_V)
        self.hcache[script] = hc
    end
    local h = hc[addr]
    if h == nil or rawget(h, "__s") ~= sh then
        h = setmetatable({ __s = sh, __sc = script }, HANDLE)
        hc[addr] = h
        if self.track_types[st.tname] then
            local rec = { script = script, addr = addr, tname = st.tname, gen = st.gen, t_create = self.t,
                t_push = self.t, frame = self.frame }
            rawset(h, "__rec", rec)
            local list = self.hrecs[addr]
            if not list then
                list = {}
                self.hrecs[addr] = list
            end
            list[#list + 1] = rec
            self.gc_due = true
        end
    else
        local rec = rawget(h, "__rec")
        if rec then rec.t_push = self.t end
    end
    return h
end

-- 出口包装：脚本拿到的托管对象一律是它自己的句柄（script 为 nil = 游戏模拟器自己在调，原样返回）
function World:wrap(script, v)
    if script and getmetatable(v) == OBJ then return self:push(v, script) end
    return v
end

function World:wrap_out(script, ...)
    local n = select("#", ...)
    if n == 0 then return end
    if n == 1 then return self:wrap(script, (...)) end
    local t = pack(...)
    for i = 1, n do t[i] = self:wrap(script, t[i]) end
    return unpack(t, 1, n)
end

-- legacy：按脚本计数（旧模型，rc1 / 冒烟脚本）
function World:legacy_ref(o, s, d)
    local addr = rawget(o, "__addr")
    local r = self.refs[addr]
    if not r then
        r = {}
        self.refs[addr] = r
        self.ref_objs[addr] = o
    end
    -- 跨脚本同时持有：旧模型按脚本分别计数测不出 REF 的共享记账，这里只另计次数给 run.lua 报（real 模型才真正模拟）
    if d > 0 then
        for other, n in pairs(r) do
            if other ~= s and n > 0 then
                self.ref_shared = (self.ref_shared or 0) + 1
                break
            end
        end
    end
    r[s] = (r[s] or 0) + d
    local tot = self.ref_totals[s]
    if not tot then
        tot = { add = 0, release = 0, peak = 0, live = 0 }
        self.ref_totals[s] = tot
    end
    if d > 0 then tot.add = tot.add + 1 else tot.release = tot.release + 1 end
    tot.live = tot.live + d
    if tot.live > tot.peak then tot.peak = tot.live end
    if r[s] < 0 then
        self:ref_counts_of(s).OVER_RELEASE = self:ref_counts_of(s).OVER_RELEASE + 1
        self:violation("OVER_RELEASE", string.format("release 次数多于 add_ref：%s", describe(o)), s)
        self:log_raw("warning", REF_WARN)
    end
end

-- 脚本对句柄调 add_ref / add_ref_permanent
function World:h_add_ref(h, permanent)
    local sh = rawget(h, "__s")
    local o, st = rawget(sh, "__o"), rawget(sh, "__st")
    local script = rawget(h, "__sc")
    self:check_alive(o, permanent and "add_ref_permanent" or "add_ref")
    local c = self:ref_counts_of(script)
    c.ADD_REF = c.ADD_REF + 1
    self.ref_events[#self.ref_events + 1] = { t = self.t, s = script, addr = st.addr, d = 1 }
    if permanent then
        c.ADD_REF_PERMANENT = c.ADD_REF_PERMANENT + 1
        self:violation("ADD_REF_PERMANENT", string.format("add_ref_permanent 无法配对释放：%s", describe(o)), script)
    end
    if self.ref_model ~= "real" then return self:legacy_ref(o, script, 1) end
    if st.lua_count > 0 then
        c.ADD_REF_NOOP = c.ADD_REF_NOOP + 1
    else
        st.lua_count = 1
    end
end

-- 脚本对句柄调 release / force_release（v1.6 和修过的 APCal 一次都不许调）
function World:h_release(h, force)
    local sh = rawget(h, "__s")
    local o, st = rawget(sh, "__o"), rawget(sh, "__st")
    local script = rawget(h, "__sc")
    self:check_alive(o, force and "force_release" or "release")
    local c = self:ref_counts_of(script)
    c.MANUAL_RELEASE = c.MANUAL_RELEASE + 1
    self.ref_events[#self.ref_events + 1] = { t = self.t, s = script, addr = st.addr, d = -1 }
    if force then
        c.FORCE_RELEASE = c.FORCE_RELEASE + 1
        self:violation("FORCE_RELEASE", "用了 force_release：" .. describe(o), script)
    end
    if self.ref_model ~= "real" then return self:legacy_ref(o, script, -1) end
    if st.lua_count > 0 then
        st.lua_count = st.lua_count - 1
        if st.lua_count == 0 then self.shared_cache[st.addr] = nil end
        self:maybe_destroy(st, o)
    else
        c.OVER_RELEASE = c.OVER_RELEASE + 1
        self:log_raw("warning", REF_WARN)
        self:violation("OVER_RELEASE", "release 时 REF 的共享计数已经是 0：" .. describe(o), script)
    end
end

-- 共享 userdata 被回收（REF 的自动 release）
function World:shared_collected(sh)
    if self.ref_model ~= "real" then return end
    local st = rawget(sh, "__st")
    if st.lua_count > 0 then
        st.lua_count = st.lua_count - 1
        if st.lua_count == 0 and self.shared_cache[st.addr] ~= nil then self.shared_cache[st.addr] = nil end
        self:maybe_destroy(st, rawget(sh, "__o"))
    else
        self.gc_unmanaged = self.gc_unmanaged + 1
        self:log_raw("warning", REF_WARN)
    end
end

SHARED.__name = "mock_shared_userdata"
SHARED.__gc = function(sh)
    local w = rawget(sh, "__w")
    if w then w:shared_collected(sh) end
end

OBJ.__name = "sol.REManagedObject*"
OBJ.__tostring = function(o) return string.format("sol.REManagedObject*: %016X", rawget(o, "__addr")) end
local OBJ_METHODS = {}
OBJ.__index = function(o, k)
    local m = OBJ_METHODS[k]
    if m then return m end
    return rawget(o, "__w"):obj_index(o, k)
end
OBJ.__newindex = function(o, k, v) rawget(o, "__w"):obj_set_field(o, k, v) end
-- 原始对象只在游戏模拟器里用；脚本拿到的都是句柄（HANDLE），引用记账在句柄上
function OBJ_METHODS.call(o, sig, ...) return rawget(o, "__w"):obj_call(o, sig, ...) end
function OBJ_METHODS.get_field(o, name) return rawget(o, "__w"):obj_get_field(o, name) end
function OBJ_METHODS.set_field(o, name, v) return rawget(o, "__w"):obj_set_field(o, name, v) end
function OBJ_METHODS.get_type_definition(o) return rawget(o, "__t") end
function OBJ_METHODS.get_address(o) return rawget(o, "__addr") end
function OBJ_METHODS.add_ref(o) return o end
function OBJ_METHODS.release() end
function OBJ_METHODS.get_reference_count(o)
    local st = rawget(o, "__st")
    return st and (st.game_refs + st.lua_count) or 1
end
function OBJ_METHODS.is_valid(o) return rawget(o, "__alive") end
-- 数组（System.Array）
function OBJ_METHODS.get_size(o)
    local a = rawget(o, "__arr")
    if not a then error("get_size: 不是数组", 2) end
    return #a
end
function OBJ_METHODS.get_element(o, i)
    local a = rawget(o, "__arr")
    if not a then error("get_element: 不是数组", 2) end
    return a[i + 1]
end
function OBJ_METHODS.get_elements(o)
    local a = rawget(o, "__arr")
    if not a then error("get_elements: 不是数组", 2) end
    local out = {}
    for i, v in ipairs(a) do out[i] = v end
    return out
end

-- 脚本的句柄（见「REF 引用记账」）：方法全部转发给游戏对象，返回值包装成这个脚本的句柄，参数拆回游戏对象。
-- 除 get_address / is_valid 外，对已销毁对象的任何访问都记 DEAD_OBJECT（真游戏里是悬空指针，可能直接崩）
HANDLE.__name = "sol.REManagedObject*"
local HM = {}
local function hparts(h)
    local sh = rawget(h, "__s")
    return rawget(sh, "__w"), rawget(sh, "__o"), rawget(h, "__sc"), sh
end
function HM.call(h, sig, ...)
    local w, o, sc = hparts(h)
    return w:wrap_out(sc, w:obj_call(o, sig, unwrap_args(...)))
end
function HM.get_field(h, name)
    local w, o, sc = hparts(h)
    return w:wrap(sc, w:obj_get_field(o, name))
end
function HM.set_field(h, name, v)
    local w, o = hparts(h)
    return w:obj_set_field(o, name, unwrap(v))
end
function HM.get_type_definition(h)
    local w, o = hparts(h)
    w:check_alive(o, "get_type_definition")
    return rawget(o, "__t")
end
function HM.get_address(h) return rawget(rawget(rawget(h, "__s"), "__o"), "__addr") end
function HM.add_ref(h)
    local w = hparts(h)
    w:h_add_ref(h, false)
    return h
end
function HM.add_ref_permanent(h)
    local w = hparts(h)
    w:h_add_ref(h, true)
    return h
end
function HM.release(h)
    local w = hparts(h)
    w:h_release(h, false)
end
function HM.force_release(h)
    local w = hparts(h)
    w:h_release(h, true)
end
function HM.get_reference_count(h)
    local w, o, _, sh = hparts(h)
    w:check_alive(o, "get_reference_count")
    local st = rawget(sh, "__st")
    return st.game_refs + st.lua_count
end
function HM.is_valid(h)
    local _, o = hparts(h)
    return rawget(o, "__alive") == true
end
function HM.get_size(h)
    local w, o = hparts(h)
    w:check_alive(o, "get_size")
    return OBJ_METHODS.get_size(o)
end
function HM.get_element(h, i)
    local w, o, sc = hparts(h)
    w:check_alive(o, "get_element")
    return w:wrap(sc, OBJ_METHODS.get_element(o, i))
end
function HM.get_elements(h)
    local w, o, sc = hparts(h)
    w:check_alive(o, "get_elements")
    local out = OBJ_METHODS.get_elements(o)
    for i, v in ipairs(out) do out[i] = w:wrap(sc, v) end
    return out
end
HANDLE.__index = function(h, k)
    local m = HM[k]
    if m then return m end
    local w, o, sc = hparts(h)
    return w:handle_index(o, sc, k)
end
HANDLE.__newindex = function(h, k, v) HM.set_field(h, k, v) end
HANDLE.__tostring = function(h) return string.format("sol.REManagedObject*: %016X", HM.get_address(h)) end
HANDLE.__eq = function(a, b) return unwrap(a) == unwrap(b) end
HANDLE.__gc = function(h)
    local rec = rawget(h, "__rec")
    if rec and not rec.t_gc then
        local sh = rawget(h, "__s")
        local w = sh and rawget(sh, "__w")
        rec.t_gc = w and w.t or -1
        rec.f_gc = w and w.frame or -1
    end
end

-- 句柄上的 REF 语法糖：h:get_Name() / h._Field
function World:handle_index(o, sc, k)
    if type(k) ~= "string" then return nil end
    local td = rawget(o, "__t")
    if self:has_method(o, td, k) then
        local c = self.handle_closures[k]
        if not c then
            c = function(self_h, ...)
                local oo = unwrap(self_h)
                local ww = rawget(oo, "__w")
                local script = getmetatable(self_h) == HANDLE and rawget(self_h, "__sc") or ww:cur_script()
                return ww:wrap_out(script, ww:obj_call(oo, k, unwrap_args(...)))
            end
            self.handle_closures[k] = c
        end
        return c
    end
    local fv = rawget(o, "__f")
    if rawget(o, "__g")[k] or fv[k] ~= nil or self:field_declared(td, k) then
        return self:wrap(sc, self:obj_get_field(o, k))
    end
    self:note("UNMOCKED_MEMBER", td.name .. "." .. k)
    return nil
end

-- 回收：每次都做两遍 collect（第一遍回收句柄，第二遍回收它们引用的共享 userdata；Lua 5.4 实测一遍就都终结了，
-- 第二遍兜底）。run.lua 在需要观测的帧末调用（见 run.lua 的「持有观测」）
function World:gc_now()
    collectgarbage("collect")
    collectgarbage("collect")
    self.gc_count = (self.gc_count or 0) + 1
    self.gc_due = false
end

-- 模拟 Reset Scripts 之后丢弃脚本环境（回调、钩子、环境表），强制回收：脚本持有的一切都随之释放
function World:drop_scripts()
    self.cb = {}
    self.hooks = {}
    for _, s in pairs(self.scripts) do s.env = nil end
    self.hcache = {}
    self:gc_now()
end

-- 值类型（ValueType）
VT.__name = "sol.ValueType*"
VT.__tostring = function(v) return string.format("ValueType(%s)", rawget(v, "__t").name) end
local VT_METHODS = {}
VT.__index = function(v, k)
    local m = VT_METHODS[k]
    if m then return m end
    local f = rawget(v, "__f")[k]
    if f ~= nil then return f end
    if rawget(v, "__m")[k] then
        return function(self_v, ...) return VT_METHODS.call(self_v, k, ...) end
    end
    return nil
end
VT.__newindex = function(v, k, val) VT_METHODS.set_field(v, k, val) end
function VT_METHODS.get_field(v, name)
    local w = rawget(v, "__w")
    local td = rawget(v, "__t")
    if w.fault_names[name] then
        local f = w:match_fault(td, name, v)
        if f then
            local handled, ret = w:apply_fault(f, td.name .. "." .. name)
            if handled then return ret end
        end
    end
    local val = rawget(v, "__f")[name]
    if val == nil and not w:field_declared(td, name) then
        w:note("UNMOCKED_FIELD", td.name .. "." .. name)
    end
    return w:wrap(w:cur_script(), val)
end
function VT_METHODS.set_field(v, name, val) rawget(v, "__f")[name] = val end
function VT_METHODS.get_type_definition(v) return rawget(v, "__t") end
function VT_METHODS.get_address(v) return rawget(v, "__addr") end
function VT_METHODS.address(v) return rawget(v, "__addr") end
function VT_METHODS.call(v, sig, ...)
    local w = rawget(v, "__w")
    local name = parse_sig(sig)
    local td = rawget(v, "__t")
    if w.fault_names[name] then
        local f = w:match_fault(td, name, v)
        if f then
            local handled, ret = w:apply_fault(f, td.name .. "." .. name)
            if handled then return ret end
        end
    end
    local h = rawget(v, "__m")[name]
    if not h then
        local th = w.type_handlers[td.name]
        h = th and th[name]
    end
    if not h then
        w:note("UNMOCKED", td.name .. "." .. name)
        return nil
    end
    return w:wrap_out(w:cur_script(), h(v, unwrap_args(...)))
end
function VT_METHODS.add_ref() error("add_ref 不能用于值类型", 2) end
function VT_METHODS.release() error("release 不能用于值类型", 2) end

-- 原生单例（via.Application 等）
NATIVE.__name = "sdk::NativeObject"
NATIVE.__index = function() return nil end
NATIVE.__tostring = function(n) return "NativeObject(" .. rawget(n, "name") .. ")" end

function World:native_singleton(name)
    local n = self.native_singletons[name]
    if not n then
        n = setmetatable({ name = name, addr = self:alloc_addr(nil, "aux") }, NATIVE)
        self.native_singletons[name] = n
    end
    return n
end

-- System.Type（sdk.typeof 的返回值；getComponent 用它找组件）
function World:typeof(name)
    self.typeofs = self.typeofs or {}
    local t = self.typeofs[name]
    if not t then
        if not self.types[name] then self:find_type(name) end
        t = self:new_object("System.RuntimeType", { data = { typename = name }, space = "aux" })
        self.typeofs[name] = t
    end
    return t
end

-- ---------- 指针转换（钩子参数 / 返回值） ----------

function World:ptr_of(v)
    v = unwrap(v)
    if v == nil then return new_ptr("int", 0) end
    local tv = type(v)
    if tv == "boolean" then return new_ptr("int", v and 1 or 0) end
    if tv == "number" then
        if math.type(v) == "integer" then return new_ptr("int", v) end
        local bits = string.unpack("<I4", string.pack("<f", v))
        return new_ptr("float", bits, v)
    end
    local mt = getmetatable(v)
    if mt == OBJ then return new_ptr("obj", rawget(v, "__addr")) end
    if mt == VT then return new_ptr("vt", rawget(v, "__addr")) end
    if mt == VEC then
        local vt = self:new_vt("via.vec3", { x = v.x, y = v.y, z = v.z })
        return new_ptr("vt", rawget(vt, "__addr"))
    end
    if mt == PTR then return v end
    if tv == "string" then
        local s = self:new_object("System.String", { data = { value = v }, space = "aux" })
        return new_ptr("obj", rawget(s, "__addr"))
    end
    return new_ptr("int", 0)
end

local function ptr_value(p)
    if getmetatable(p) == PTR then return rawget(p, "kind"), rawget(p, "v"), rawget(p, "f") end
    return nil
end

function World:to_managed_object(p)
    if p == nil then return nil end
    local mt = getmetatable(p)
    if mt == OBJ or mt == HANDLE then return p end
    local addr
    if mt == PTR then
        addr = rawget(p, "v")
    elseif math.type(p) == "integer" then
        addr = p
    else
        error("bad argument #1 to 'to_managed_object' (" .. type(p) .. ")", 3)
    end
    if addr == 0 then return nil end
    local o = self.objects[addr]
    if not o then self:note("BAD_PTR", "to_managed_object 收到不是托管对象的指针") end
    return o
end

function World:to_int64(p)
    if p == nil then return 0 end
    p = unwrap(p)
    local kind, v = ptr_value(p)
    if kind then return v end
    local mt = getmetatable(p)
    if mt == OBJ then return rawget(p, "__addr") end
    if type(p) == "number" then return math.tointeger(p) or math.floor(p) end
    if type(p) == "boolean" then return p and 1 or 0 end
    error("bad argument #1 to 'to_int64' (" .. type(p) .. ")", 3)
end

function World:to_float(p)
    local kind, v, f = ptr_value(p)
    if kind == "float" then return f end
    if kind then return (string.unpack("<f", string.pack("<I4", v & 0xFFFFFFFF))) end
    if type(p) == "number" then return p + 0.0 end
    error("bad argument #1 to 'to_float' (" .. type(p) .. ")", 3)
end

function World:to_valuetype(p, td)
    local kind, v = ptr_value(p)
    local vt
    if kind == "vt" then vt = self.vts[v] end
    if getmetatable(p) == VT then vt = p end
    if not vt then
        self:note("BAD_PTR", "to_valuetype 收到不是值类型的指针")
        return nil
    end
    local want = td
    if getmetatable(td) == TD then want = td.name end
    if type(want) == "string" and want ~= rawget(vt, "__t").name then
        self:note("VT_TYPE_MISMATCH", "to_valuetype(" .. want .. ") 实际是 " .. rawget(vt, "__t").name)
    end
    return vt
end

-- ---------- 钩子 ----------

-- sdk.hook 登记。forbidden：高频函数（PLAN：onParryHitPreProcess 每秒 6~18 万次）
function World:add_hook(md, pre, post)
    local s = self:cur_script() or "game"
    if getmetatable(md) ~= MD then
        self:violation("BAD_HOOK", "sdk.hook 的第一个参数不是方法定义（多半是 get_method 返回了 nil）")
        error("sdk.hook: method definition is nil or invalid", 3)
    end
    if pre ~= nil and type(pre) ~= "function" then error("sdk.hook: pre 必须是函数或 nil", 3) end
    if post ~= nil and type(post) ~= "function" then error("sdk.hook: post 必须是函数或 nil", 3) end
    if self.forbidden_hooks[md.name] then
        self:violation("FORBIDDEN_HOOK", "钩了禁止的高频函数 " .. md.key)
    end
    if self.allowed_hooks and not self.allowed_hooks[md.key] then
        self:note("HOOK_NOT_IN_ALLOWLIST", md.key, s)
    end
    if md.generic then
        self:note("HOOK_ON_UNMOCKED", md.key, s)
    end
    local list = self.hooks[md.key]
    if not list then
        list = {}
        self.hooks[md.key] = list
    end
    list[#list + 1] = { script = s, pre = pre, post = post }
    self.hook_regs[#self.hook_regs + 1] = { script = s, key = md.key, t = self.t }
end

-- 带钩子的调用：args[1]=线程上下文，args[2]=this，args[3..]=参数（全部是指针对象）
function World:invoke_hooked(o, key, original, params)
    local hooks = self.hooks[key]
    local args = { self.ctx_ptr, self:ptr_of(o) }
    local n = params.n or #params
    for i = 1, n do args[i + 2] = self:ptr_of(params[i]) end
    local snap = {}
    for i = 1, #args do snap[i] = args[i] end
    local skip = false
    local prev_ctx = self.hook_ctx
    for _, h in ipairs(hooks) do
        if h.pre then
            self.hook_ctx = { key = key, stage = "pre" }
            local res = pack(self:run_as(h.script, h.pre, "hook pre " .. key, args))
            if res[1] and res[2] == SKIP_ORIGINAL then
                skip = true
                self.effects[#self.effects + 1] = self:effect_ctx({ script = h.script, kind = "skip_original", type = "-",
                    name = key, sig = key, target = describe(o), args = {}, t = self.t, frame = self.frame,
                    phase = self.phase })
            end
        end
    end
    self.hook_ctx = prev_ctx
    for i = 1, math.max(#args, #snap) do
        if args[i] ~= snap[i] then
            self.effects[#self.effects + 1] = { script = "hook@" .. key, kind = "hook_args_modified", type = "-",
                name = key, sig = key, target = "-", args = { tostring(i) }, t = self.t, frame = self.frame,
                phase = self.phase }
            break
        end
    end
    local rets
    if skip then
        rets = pack(nil)
    else
        rets = pack(original(o, unpack(params, 1, n)))
    end
    local retptr = self:ptr_of(rets[1])
    for _, h in ipairs(hooks) do
        if h.post then
            self.hook_ctx = { key = key, stage = "post" }
            local res = pack(self:run_as(h.script, h.post, "hook post " .. key, retptr))
            self.hook_ctx = prev_ctx
            if res[1] then
                local r = res[2]
                if r == nil then
                    self:note("POST_NO_RETURN", key, h.script)
                elseif not (getmetatable(r) == PTR and r == retptr) then
                    self.effects[#self.effects + 1] = { script = h.script, kind = "hook_retval_modified", type = "-",
                        name = key, sig = key, target = "-", args = { describe(r) }, t = self.t, frame = self.frame,
                        phase = self.phase }
                end
            end
        end
    end
    return unpack(rets, 1, rets.n)
end

-- 游戏（模拟器）发起的调用：走钩子，原函数由模拟器提供
function World:fire(o, decl_type, sig, params, original)
    local name, ps = parse_sig(sig)
    local key = decl_type .. "." .. name .. (ps or "()")
    local hooks = self.hooks[key]
    if hooks and #hooks > 0 then
        params.n = params.n or #params
        return self:invoke_hooked(o, key, original or function() return nil end, params)
    end
    if original then return original(o, unpack(params, 1, params.n or #params)) end
    return nil
end

-- ---------- 脚本执行 ----------

function World:run_as(script, fn, what, ...)
    local ctx = self.ctx
    ctx[#ctx + 1] = script
    local t0 = host_clock()
    local res = pack(pcall(fn, ...))
    local dt = host_clock() - t0
    ctx[#ctx] = nil
    local p = self.perf[script]
    if not p then
        p = { total = 0.0, calls = 0 }
        self.perf[script] = p
    end
    p.total = p.total + dt
    p.calls = p.calls + 1
    self.frame_cost[script] = (self.frame_cost[script] or 0) + dt
    if not res[1] then self:script_error(script, what, res[2]) end
    return unpack(res, 1, res.n)
end

function World:script_error(script, what, err)
    local msg = tostring(err)
    self:violation("SCRIPT_ERROR", what .. ": " .. msg, script)
    self:log_raw("error", string.format("[mock] 脚本 %s 未捕获的错误（%s）: %s", script, what, msg))
end

function World:add_cb(kind, script, fn)
    if type(fn) ~= "function" then error("回调必须是函数（" .. kind .. "）", 3) end
    local list = self.cb[kind]
    if not list then
        list = {}
        self.cb[kind] = list
        self.cb_order[#self.cb_order + 1] = kind
    end
    list[#list + 1] = { script = script, fn = fn }
end

function World:run_cbs(kind, imgui_check)
    local list = self.cb[kind]
    if not list then return end
    for _, c in ipairs(list) do
        if imgui_check then self.ui_stack = {} end
        self.ui_cur_script = c.script
        self:run_as(c.script, c.fn, kind)
        if imgui_check then
            if #self.ui_stack > 0 then
                local names = {}
                for _, e in ipairs(self.ui_stack) do names[#names + 1] = e end
                self:violation("IMGUI_UNBALANCED", kind .. " 结束时 imgui 栈没有弹干净: " .. table.concat(names, ","), c.script)
            end
            self.ui_stack = nil
        end
    end
end

-- ---------- 环境表 ----------

local ALLOWED_GLOBALS = {
    "sdk", "re", "imgui", "log", "json", "ValueType", "draw", "fs", "pairs", "ipairs", "pcall", "tostring",
    "tonumber", "string", "math", "table", "type", "error", "select", "next", "print", "os",
    "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen", "assert",
}
M.ALLOWED_GLOBALS = ALLOWED_GLOBALS

local function copy_table(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

function World:make_math(script)
    local m = copy_table(math)
    local rng = M.make_rng(0)
    m.random = function(a, b) return rng.random(a, b) end
    m.randomseed = function(x)
        rng.seed(x or 0)
        self:note("RANDOMSEED", tostring(x), script)
    end
    return m
end

function World:make_os()
    local w = self
    return {
        clock = function() return w:clock() end,
        time = function(t) if t then return os.time(t) end return w:wall_time() end,
        date = function(fmt, t) return os.date(fmt, t or w:wall_time()) end,
        difftime = os.difftime,
    }
end

function World:make_log(script)
    local w = self
    local function mk(level)
        return function(msg)
            if type(msg) == "number" then msg = tostring(msg) end
            if type(msg) ~= "string" then
                w:violation("LOG_BAD_ARG", "log." .. level .. " 的参数不是字符串（" .. type(msg) .. "）")
                error("bad argument #1 to '" .. level .. "' (string expected, got " .. type(msg) .. ")", 2)
            end
            w:log_raw(level == "warn" and "warning" or level, msg)
        end
    end
    local lg = { info = mk("info"), warn = mk("warn"), error = mk("error"), debug = mk("debug") }
    return lg
end

function World:data_path(path)
    if type(path) ~= "string" or path == "" then return nil, "路径为空" end
    if path:find("%.%.") or path:match("^[/\\]") or path:match("^%a:") then return nil, "路径越界: " .. path end
    local flat = path:gsub("[/\\]", "__")
    if flat ~= path then self:note("PATH_FLATTENED", path) end
    return self.out_dir .. "/" .. flat, flat
end

function World:remember_file(rel)
    if not self.files[rel] then
        self.files[rel] = true
        self.file_order[#self.file_order + 1] = rel
    end
end

function World:read_file(rel)
    local f = io.open(self.out_dir .. "/" .. rel, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

function World:write_file(rel, s)
    local f, err = io.open(self.out_dir .. "/" .. rel, "wb")
    if not f then return false, err end
    f:write(s)
    f:close()
    self:remember_file(rel)
    return true
end

function World:make_json(script)
    local w = self
    local j = {}
    function j.load_file(path)
        local fp, rel = w:data_path(path)
        if not fp then
            w:note("JSON_BAD_PATH", tostring(path), script)
            return nil
        end
        w.json_reads = w.json_reads or {}
        w.json_reads[#w.json_reads + 1] = { script = script, path = rel, t = w.t, phase = w.phase }
        -- 场景注入的读盘故障（文件被占用等）：只支持 throw（合并版读旧配置抛错要报 ERR mod=cfg，MERGE 第 3.3 节）
        local jf = w:api_fault("json.load_file", rel)
        if jf then error(jf.msg or "mock: json.load_file 读盘失败", 2) end
        local s = w:read_file(rel)
        if not s then return nil end
        local v = json_lite.decode(s)
        return v
    end
    function j.dump_file(path, value, indent)
        local fp, rel = w:data_path(path)
        if not fp then
            w:violation("JSON_REJECT", "json.dump_file 路径不合法: " .. tostring(rel))
            return false
        end
        -- 场景注入的写盘失败（磁盘满、文件被占用）：记成一次失败的写出（injected，run.lua 按场景预期核对）
        local jf = w:api_fault("json.dump_file", rel)
        if jf then
            w.json_writes[#w.json_writes + 1] = { script = script, path = rel, ok = false, err = "mock 注入的写盘失败",
                t = w.t, frame = w.frame, phase = w.phase, injected = true }
            if jf.mode == "throw" then error(jf.msg or "mock: json.dump_file 写盘失败", 2) end
            return false
        end
        local s, err = json_lite.encode(value, indent)
        if not s then
            w:violation("JSON_REJECT", "json.dump_file(\"" .. path .. "\") 被拒绝: " .. err)
            w.json_writes[#w.json_writes + 1] = { script = script, path = rel, ok = false, err = err, t = w.t,
                frame = w.frame }
            return false
        end
        local ok, werr = w:write_file(rel, s)
        -- 配置文件（不是「前缀_会话_序号.json」的数据分块）记下写出的原文：合并版加载时迁移就要写回 AutoGuardGS.json，
        -- 场景结束存配置又会覆盖它，run.lua 要核对加载那一刻写的内容（MERGE 第 3.3、6.4 节）
        local text = (not rel:match("_%d+_%d+%.json$")) and s or nil
        w.json_writes[#w.json_writes + 1] = { script = script, path = rel, ok = ok, err = werr, t = w.t,
            frame = w.frame, bytes = #s, phase = w.phase, text = text }
        return ok
    end
    function j.dump_string(value, indent)
        local s, err = json_lite.encode(value, indent)
        if not s then
            w:violation("JSON_REJECT", "json.dump_string 被拒绝: " .. err)
            return nil
        end
        return s
    end
    function j.load_string(s)
        local v = json_lite.decode(s)
        return v
    end
    return j
end

function World:make_fs(script)
    local w = self
    local fs = {}
    function fs.write(path, text)
        local fp, rel = w:data_path(path)
        if not fp then
            w:violation("FS_BAD_PATH", "fs.write 路径不合法: " .. tostring(path))
            return false
        end
        if type(text) ~= "string" then error("fs.write: 内容必须是字符串", 2) end
        w:write_file(rel, text)
        w:note("FS_WRITE", rel, script)
        return true
    end
    function fs.read(path)
        local fp, rel = w:data_path(path)
        if not fp then return nil end
        return w:read_file(rel)
    end
    function fs.glob(pattern)
        local out = {}
        for _, rel in ipairs(w.file_order) do
            local ok, hit = pcall(string.find, rel, pattern)
            if ok and hit then out[#out + 1] = rel end
        end
        return out
    end
    return fs
end

function World:make_value_type()
    local w = self
    return {
        new = function(td)
            if getmetatable(td) ~= TD then
                w:violation("BAD_VALUETYPE", "ValueType.new 的参数不是类型定义（多半是 find_type_definition 返回了 nil）")
                error("ValueType.new: bad type definition", 2)
            end
            if not td.vt then w:note("VALUETYPE_OF_REFTYPE", td.name) end
            local fields = {}
            for _, cur in ipairs(w:chain(td)) do
                for _, f in ipairs(cur.flist) do
                    if fields[f] == nil then fields[f] = 0 end
                end
            end
            return w:new_vt(td.name, fields, { script_made = true })
        end,
    }
end

function World:make_sdk(script)
    local w = self
    local sdk = {}
    sdk.PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = SKIP_ORIGINAL }
    function sdk.find_type_definition(name) return w:find_type(name) end
    function sdk.typeof(name)
        if type(name) ~= "string" then error("bad argument #1 to 'typeof' (string expected)", 2) end
        if w.missing["type:" .. name] then return nil end
        return w:wrap(script, w:typeof(name))
    end
    function sdk.get_managed_singleton(name)
        local s = w.singletons[name]
        if s == nil then w:note("UNMOCKED_SINGLETON", tostring(name)) end
        if type(s) == "function" then s = s(w) end
        return w:wrap(script, s)
    end
    function sdk.get_native_singleton(name)
        if w.native_types[name] then return w:native_singleton(name) end
        w:note("UNMOCKED_SINGLETON", "native " .. tostring(name))
        return nil
    end
    function sdk.call_native_func(obj, td, name, ...)
        local tname = getmetatable(td) == TD and td.name or tostring(td)
        local h = w.native_handlers[tname .. "." .. (parse_sig(name))]
        if is_write_method(parse_sig(name)) then w:record_effect_raw("call_native_func", tname .. "." .. name) end
        if not h then
            w:note("UNMOCKED", "native " .. tname .. "." .. name)
            return nil
        end
        return h(obj, ...)
    end
    function sdk.call_object_func(obj, name, ...) return obj:call(name, ...) end
    function sdk.get_native_field(_, td, name)
        w:note("UNMOCKED", "get_native_field " .. tostring(getmetatable(td) == TD and td.name) .. "." .. tostring(name))
        return nil
    end
    function sdk.set_native_field() w:record_effect_raw("set_native_field", "?") end
    function sdk.hook(md, pre, post, _) w:add_hook(md, pre, post) end
    function sdk.hook_vtable() w:note("UNMOCKED", "sdk.hook_vtable") end
    function sdk.to_managed_object(p) return w:wrap(script, w:to_managed_object(p)) end
    function sdk.to_int64(p) return w:to_int64(p) end
    function sdk.to_float(p) return w:to_float(p) end
    function sdk.to_double(p) return w:to_float(p) end
    function sdk.to_ptr(v) return w:ptr_of(v) end
    function sdk.float_to_ptr(v) return w:ptr_of((tonumber(v) or 0) + 0.0) end
    function sdk.deref_ptr(p) return p end
    function sdk.to_valuetype(p, td) return w:to_valuetype(p, td) end
    function sdk.is_managed_object(v) return getmetatable(v) == OBJ or getmetatable(v) == HANDLE end
    function sdk.create_instance(name)
        w:record_effect_raw("create_instance", tostring(name))
        return w:wrap(script, w:new_object(name, { space = "aux" }))
    end
    function sdk.create_managed_string(s)
        return w:wrap(script, w:new_object("System.String", { data = { value = s }, space = "aux" }))
    end
    function sdk.create_managed_array(t, n)
        w:record_effect_raw("create_managed_array", tostring(t))
        local a = {}
        for i = 1, (n or 0) do a[i] = 0 end
        return w:wrap(script, w:new_object("System.Array", { array = a, space = "aux" }))
    end
    function sdk.get_tdb_version() return 81 end
    function sdk.game_namespace(n) return "app." .. n end
    function sdk.get_thread_context() return w.ctx_ptr end
    function sdk.get_primary_camera() return nil end
    setmetatable(sdk, { __index = function(_, k)
        w:note("UNMOCKED", "sdk." .. tostring(k))
        return nil
    end })
    return sdk
end

function World:make_re(script)
    local w = self
    local re = {}
    function re.on_pre_application_entry(name, fn) w:add_cb("pre:" .. tostring(name), script, fn) end
    function re.on_application_entry(name, fn) w:add_cb("post:" .. tostring(name), script, fn) end
    function re.on_frame(fn) w:add_cb("frame", script, fn) end
    function re.on_draw_ui(fn) w:add_cb("draw_ui", script, fn) end
    function re.on_script_reset(fn) w:add_cb("reset", script, fn) end
    function re.on_config_save(fn) w:add_cb("config_save", script, fn) end
    function re.on_pre_gui_draw_element(fn) w:add_cb("pre_gui", script, fn) end
    function re.on_gui_draw_element(fn) w:add_cb("gui", script, fn) end
    function re.msg(text) w:note("RE_MSG", tostring(text), script) end
    setmetatable(re, { __index = function(_, k)
        w:note("UNMOCKED", "re." .. tostring(k), script)
        return function() end
    end })
    return re
end

-- 屏幕/菜单文字里不该出现的字形（CONTRACT：避开 °、全角空格）
local BAD_GLYPHS = { "°", "　" }

function World:check_text(script, where, text)
    for _, g in ipairs(BAD_GLYPHS) do
        if text:find(g, 1, true) then
            self:note("BAD_GLYPH", where .. ": " .. text:sub(1, 60), script)
        end
    end
end

function World:make_draw(script)
    local w = self
    local d = {}
    function d.text(text, x, y, color)
        if w.draw_throws then error(w.draw_throws.msg or "mock: draw.text 不可用", 2) end
        if type(text) ~= "string" then error("bad argument #1 to 'text' (string expected, got " .. type(text) .. ")", 2) end
        if type(x) ~= "number" or type(y) ~= "number" then error("draw.text: 坐标必须是数字", 2) end
        w:hud_text(script, text)
    end
    local function noop() end
    d.filled_rect, d.outline_rect, d.line, d.filled_circle, d.outline_circle = noop, noop, noop, noop, noop
    d.filled_quad, d.outline_quad = noop, noop
    function d.world_text(text) if type(text) == "string" then w:hud_text(script, text) end end
    function d.world_to_screen(_) return nil end
    function d.gizmo() return false end
    setmetatable(d, { __index = function(_, k)
        w:note("UNMOCKED", "draw." .. tostring(k), script)
        return noop
    end })
    return d
end

function World:hud_text(script, text)
    local h = self.hud[script]
    if not h then
        h = { list = {}, seen = {} }
        self.hud[script] = h
    end
    if not h.seen[text] then
        h.seen[text] = true
        h.list[#h.list + 1] = { t = self.t, text = text }
        self:check_text(script, "HUD", text)
    end
    h.last = text
    h.last_t = self.t
end

-- 场景里的菜单操作：{ t =, kind = "button"|"checkbox"|"slider", match = "写出数据", value = ... }
function World:ui_match(script, kind, label)
    for _, a in ipairs(self.ui_actions) do
        if a.kind == kind and self.t >= a.t and not (a.done and a.done[script])
            and (not a.script or a.script == script) and label:find(a.match, 1, true) then
            a.done = a.done or {}
            a.done[script] = self.t
            return a
        end
    end
    return nil
end

function World:make_imgui(script)
    local w = self
    local im = {}
    local function menu_line(text)
        local m = w.menu[script]
        if not m then
            m = {}
            w.menu[script] = m
        end
        m[#m + 1] = text
        local seen = w.menu_seen[script]
        if not seen then
            seen = {}
            w.menu_seen[script] = seen
        end
        if not seen[text] then seen[text] = w.t end
    end
    local function check_label(kind, label)
        if type(label) ~= "string" then error("imgui." .. kind .. ": label 必须是字符串", 3) end
        -- 场景注入的 imgui 故障（菜单代码出错的降级路径）：只支持 throw
        local f = w.api_faults and w:api_fault("imgui." .. kind)
        if f then error(f.msg or ("mock: imgui." .. kind .. " 抛错"), 3) end
        w:check_text(script, "imgui." .. kind, label)
        if not label:find("##", 1, true) then w:note("LABEL_NO_ID", kind .. ": " .. label, script) end
    end
    local function push(kind)
        if w.ui_stack then w.ui_stack[#w.ui_stack + 1] = kind end
    end
    local function pop(kind, fname)
        local st = w.ui_stack
        if not st then return end
        if st[#st] ~= kind then
            w:violation("IMGUI_UNBALANCED", "imgui." .. fname .. " 和栈顶 " .. tostring(st[#st]) .. " 不配对", script)
            return
        end
        st[#st] = nil
    end
    function im.tree_node(label)
        check_label("tree_node", label)
        menu_line("[+] " .. label)
        push("tree_node")
        return true
    end
    im.tree_node_str_id = function(_, label) return im.tree_node(label) end
    im.tree_node_ptr_id = function(_, label) return im.tree_node(label) end
    function im.tree_pop() pop("tree_node", "tree_pop") end
    function im.collapsing_header(label)
        check_label("collapsing_header", label)
        menu_line("[=] " .. label)
        return true
    end
    function im.begin_window(name)
        if type(name) ~= "string" then error("imgui.begin_window: name 必须是字符串", 2) end
        -- REF 文档：begin_window 只能在 on_frame 里用，不能在 on_draw_ui 里
        if w.phase == "ui" then w:note("BEGIN_WINDOW_IN_DRAW_UI", name, script) end
        w.hud_window[script] = (w.hud_window[script] or 0) + 1
        push("window")
        return true
    end
    function im.end_window() pop("window", "end_window") end
    function im.begin_child_window() push("child") return true end
    function im.end_child_window() pop("child", "end_child_window") end
    function im.begin_group() push("group") end
    function im.end_group() pop("group", "end_group") end
    function im.push_id() push("id") end
    function im.pop_id() pop("id", "pop_id") end
    function im.push_style_color() push("style_color") end
    function im.pop_style_color(n)
        for _ = 1, (n or 1) do pop("style_color", "pop_style_color") end
    end
    function im.push_style_var() push("style_var") end
    function im.pop_style_var(n)
        for _ = 1, (n or 1) do pop("style_var", "pop_style_var") end
    end
    function im.push_item_width() push("item_width") end
    function im.pop_item_width() pop("item_width", "pop_item_width") end
    function im.begin_table() push("table") return true end
    function im.end_table() pop("table", "end_table") end
    function im.begin_menu() return false end
    function im.begin_popup() return false end
    function im.begin_popup_context_item() return false end
    function im.text(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        local s = table.concat(parts, " ")
        w:check_text(script, "imgui.text", s)
        menu_line(s)
    end
    function im.text_colored(text, _)
        local s = tostring(text)
        w:check_text(script, "imgui.text_colored", s)
        menu_line(s)
    end
    im.text_wrapped = im.text
    im.bullet_text = im.text
    function im.button(label)
        check_label("button", label)
        menu_line("[" .. label .. "]")
        return w:ui_match(script, "button", label) ~= nil
    end
    im.small_button = im.button
    function im.checkbox(label, v)
        check_label("checkbox", label)
        menu_line("[" .. (v and "x" or " ") .. "] " .. label)
        local a = w:ui_match(script, "checkbox", label)
        if a then return true, a.value end
        return false, v
    end
    local function slider(kind)
        return function(label, v, ...)
            check_label(kind, label)
            menu_line(kind .. " " .. label .. " = " .. tostring(v))
            local a = w:ui_match(script, "slider", label)
            if a then return true, a.value end
            return false, v
        end
    end
    im.slider_int, im.slider_float, im.drag_int, im.drag_float = slider("slider_int"), slider("slider_float"),
        slider("drag_int"), slider("drag_float")
    im.input_int, im.input_float = slider("input_int"), slider("input_float")
    function im.input_text(label, v)
        check_label("input_text", label)
        return false, v
    end
    function im.combo(label, v, items)
        check_label("combo", label)
        menu_line("combo " .. label .. " = " .. tostring(v))
        local a = w:ui_match(script, "combo", label)
        if a then return true, a.value end
        return false, v
    end
    local function noop() end
    im.separator, im.same_line, im.spacing, im.new_line, im.bullet = noop, noop, noop, noop, noop
    im.indent, im.unindent, im.set_tooltip = noop, noop, noop
    im.set_next_window_pos, im.set_next_window_size, im.set_next_item_open = noop, noop, noop
    im.progress_bar, im.set_next_window_bg_alpha = noop, noop
    function im.is_item_hovered() return false end
    function im.is_window_hovered() return false end
    function im.get_display_size() return { x = 1920.0, y = 1080.0 } end
    function im.get_window_size() return { x = 400.0, y = 300.0 } end
    function im.calc_text_size(text) return { x = #tostring(text) * 7.0, y = 13.0 } end
    setmetatable(im, { __index = function(_, k)
        w:note("UNMOCKED", "imgui." .. tostring(k), script)
        return function() return false end
    end })
    return im
end

function World:make_env(script)
    local w = self
    local env = {}
    env.pairs, env.ipairs, env.pcall, env.tostring, env.tonumber = pairs, ipairs, pcall, tostring, tonumber
    env.error, env.select, env.next, env.assert = error, select, next, assert
    env.setmetatable, env.getmetatable = setmetatable, getmetatable
    env.rawget, env.rawset, env.rawequal, env.rawlen = rawget, rawset, rawequal, rawlen
    -- 真 REF 里游戏对象是 userdata
    env.type = function(v)
        if is_mock_ud(v) then return "userdata" end
        return type(v)
    end
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        w.prints[#w.prints + 1] = { script = script, t = w.t, text = table.concat(parts, "\t") }
    end
    env.string = copy_table(string)
    env.table = copy_table(table)
    env.math = w:make_math(script)
    env.os = w:make_os()
    env.sdk = w:make_sdk(script)
    env.re = w:make_re(script)
    env.imgui = w:make_imgui(script)
    env.draw = w:make_draw(script)
    env.log = w:make_log(script)
    env.json = w:make_json(script)
    env.fs = w:make_fs(script)
    env.ValueType = w:make_value_type()
    setmetatable(env, {
        __index = function(_, k)
            w:violation("GLOBAL_READ", "读了未定义的全局变量 " .. tostring(k) .. "（check.sh 也会拦）", script)
            return nil
        end,
        __newindex = function(t, k, v)
            w:violation("GLOBAL_WRITE", "写了全局变量 " .. tostring(k) .. "（应该用 local）", script)
            rawset(t, k, v)
        end,
    })
    return env
end

-- 载入被测脚本：独立环境表 + load(源码, 名字, "t", env)
function World:load_script(name, path, tag)
    local f = io.open(path, "rb")
    if not f then return false, "missing" end
    local src = f:read("a")
    f:close()
    local env = self:make_env(name)
    local chunk, err = load(src, "@" .. path, "t", env)
    self.scripts[name] = { env = env, path = path, tag = tag, src = src }
    self.script_order[#self.script_order + 1] = name
    if not chunk then
        self:violation("SCRIPT_ERROR", "语法错误: " .. tostring(err), name)
        return false, "syntax: " .. tostring(err)
    end
    local prev = self.phase
    self.phase = "load"
    local ok, e = self:run_as(name, chunk, "load")
    self.phase = prev
    if not ok then return false, "load error: " .. tostring(e) end
    return true
end

-- ---------- 内置类型库（名字、签名来自 MCP 类型库和已实测的脚本） ----------

function M.declare_builtin_types(w)
    local function D(name, parent, methods, fields, extra)
        local spec = { parent = parent, methods = methods, fields = fields }
        if extra then for k, v in pairs(extra) do spec[k] = v end end
        w:declare_type(name, spec)
    end
    D("System.Object", nil, { "ToString()", "Equals(System.Object)", "GetHashCode()" })
    D("System.ValueType", "System.Object", nil, nil, { vt = true })
    D("System.Enum", "System.ValueType", nil, nil, { vt = true })
    D("System.String", "System.Object", { "get_Length()" })
    D("System.Type", "System.Object", { "get_FullName()", "get_Name()" })
    D("System.RuntimeType", "System.Type")
    D("System.Array", "System.Object", { "get_Length()", "GetValue(System.Int32)" })
    D("via.Object", "System.Object")
    D("via.Component", "via.Object", { "get_GameObject()" })
    D("via.Behavior", "via.Component")
    D("via.GameObject", "via.Object", { "get_Name()", "get_Transform()", "getComponent(System.Type)",
        "get_TimeScale()", "get_Valid()", "get_UpdateSelf()", "get_DrawSelf()", "get_Tag()",
        "set_TimeScale(System.Single)", "set_UpdateSelf(System.Boolean)", "set_DrawSelf(System.Boolean)" })
    D("via.Transform", "via.Component", { "get_Position()", "get_AxisX()", "get_AxisY()", "get_AxisZ()",
        "get_Rotation()", "get_LocalPosition()", "get_EulerAngle()", "get_Joints()", "getJointByName(System.String)",
        "set_Position(via.vec3)", "set_Rotation(via.Quaternion)" })
    D("via.motion.Motion", "via.Component", { "getLayer(System.UInt32)", "get_LayerCount()" })
    D("via.motion.TreeLayer", "System.Object", { "get_Frame()", "get_Speed()", "get_MotionID()",
        "get_MotionBankID()", "get_EndFrame()" })
    D("via.Application", "System.Object", { "get_DeltaTime()", "get_FrameCount()", "get_UpTimeSecond()" })
    D("via.vec3", "System.ValueType", nil, { "x", "y", "z" }, { vt = true })
    D("via.OBB", "System.ValueType", { "get_Position()", "get_Extent()" }, { "coord", "extent" }, { vt = true })
    D("ace.ACTION_ID", "System.ValueType", nil, { "_Category", "_Index" }, { vt = true })
    D("app.TARGET_ACCESS_KEY", "System.ValueType", nil, { "Category", "UniqueIndex" }, { vt = true })
    D("System.Nullable`1<System.Int32>", "System.ValueType",
        { "get_HasValue()", "get_Value()", "GetValueOrDefault()", "GetValueOrDefault(System.Int32)" },
        { "_HasValue", "_Value" }, { vt = true, short = "NullableInt32" })
    D("System.Nullable`1<System.UInt32>", "System.ValueType",
        { "get_HasValue()", "get_Value()", "GetValueOrDefault()", "GetValueOrDefault(System.UInt32)" },
        { "_HasValue", "_Value" }, { vt = true, short = "NullableUInt32" })

    D("app.AppBehavior", "via.Behavior")
    D("app.CharacterBase", "app.AppBehavior", { "get_BaseActionController()", "get_SubActionController()",
        "get_MotionComponent()", "get_HitComponent()" })
    D("app.HunterCharacter", "app.CharacterBase", {
        "get_WeaponType()", "get_IsMaster()",
        "get_HunterStatus()", "get_WeaponHandling()", "get_DamageInfo()", "get_AttackAreaResult()", "get_Weapon()",
        "get_IsWeaponOn()", "isActionAttrCurrentAction(app.HunterDef.ACTION_ATTR)",
        "changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)",
        "changeActionImmediate(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)",
        "checkHunterContinueFlag(app.HunterDef.CONTINUE_FLAG)", "checkHunterStatusFlag(app.HunterDef.STATUS_FLAG)",
        "evHit_DamagePreProcess(app.HitInfo)", "evHit_ShellDamagePreProcess(app.HitInfo)",
        "evHit_Damage(app.HitInfo)", "evHit_AttackPreProcess(app.HitInfo)", "get_HunterHealth()",
    }, { "_HunterMotionSupporter", "_HunterContinueFlag" }, { short = "HunterCharacter" })
    -- 血量（NOTES「血量」，v1.4.2 的【测试】锁血用；MERGE 第 6.2 节第 3 条）：受击时 requestDamage 登记、update 里结算；
    -- 红血 requestRedDamage。签名 2026-10-11 MCP get_type 核对过（AutoGuardGS v1.4.2 钩的就是这两个）
    D("app.cHunterHealth", "System.Object", {
        "requestDamage(app.HunterCharacter, System.Single, System.Single, System.Boolean, System.Boolean, System.Boolean, "
            .. "System.Boolean, System.Boolean, System.Boolean)",
        "requestRedDamage(System.Single)", "get_HealthMgr()", "get_IsNoDamage()", "set_IsNoDamage(System.Boolean)",
    }, { "_RequestedTotalDamage", "_IsNoDamage" }, { short = "HunterHealth" })
    D("app.cHealthManager", "System.Object", { "get_Health()", "get_MaxHealth()", "set_Health(System.Single)" },
        { "_Health", "_MaxHealth" }, { short = "HealthManager" })
    D("ace.cActionController", "System.Object", { "get_CurrentActionID()", "get_CurrentAction()",
        "get_PrevActionID()", "get_NextActionID()" }, nil, { short = "ActionController" })
    D("ace.cActionBase", "System.Object", nil, { "_RawTotalElapsedSecond" })
    D("app.cCharacterActionBase", "ace.cActionBase", { "get_CharaDeltaTime()", "get_CharaElapsedSecond()",
        "get_RawTotalElapsedSecond()", "get_SelfObject()" }, nil, { short = "CharacterAction" })
    D("app.cHunterActionBase", "app.cCharacterActionBase")
    D("app.cEnemyActionBase", "app.cCharacterActionBase", { "get_Chara()" }, nil, { short = "EnemyAction" })
    D("ace.cSafeContinueFlagGroup", "System.Object", { "check(System.UInt32)", "on(System.UInt32)",
        "off(System.UInt32)" }, nil, { short = "FlagGroup" })
    D("app.cHunterStatus", "System.Object", nil, { "_HunterStatusFlag" })
    D("app.cHunterWeaponHandlingBase", "System.Object", {
        "get_ParryState()", "get_ParryTarget()", "get_IsParryInfoContinue()", "get_Hunter()", "get_Weapon()",
        "onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3)",
        "onParrySuccess(app.HunterDef.PARRY_STATE)", "onParryHitPreProcess(app.HitInfo)",
        "set_ParryState(app.HunterDef.PARRY_STATE)", "set_ParryTarget(via.GameObject)",
        "set_IsParryInfoContinue(System.Boolean)",
    }, { "<ParryState>k__BackingField", "<ParryTarget>k__BackingField", "<Hunter>k__BackingField" },
        { short = "WeaponHandling" })
    D("app.cHunterWp00Handling", "app.cHunterWeaponHandlingBase", nil, { "_ChargeLevel", "_ChargeTimer", "_ChargeType",
        "_IsOverheat", "_ChargeContinue" })
    D("app.Weapon", "app.AppBehavior", nil, { "_IsAttackColliderOn" })
    D("app.cHunterDamageInfo", "System.Object", nil, { "_TotalDamage", "_GuardReaction", "_DamageType" })
    D("app.mcHunterAttackAreaResultHolder", "System.Object", nil, { "_AttackAreaResultList" })
    D("app.HunterCharacter.cMotionSupporter", "System.Object", nil, { "_BaseBasicMotionSeq" })
    D("app.motion_track.HunterBasic", "System.Object", { "get_ParryImmdiate()", "get_SuperArmor()",
        "get_HyperArmor()", "get_NoHit()", "get_ActionFlag1()", "get_WpUniqueFlag1()" },
        { "_ParryImmdiate", "_ActionFlag1", "_ActionFlag2", "_ActionFlag3", "_WpUniqueFlag1", "_SuperArmor",
            "_HyperArmor", "_NoHit" })
    D("app.PlayerManager", "System.Object", { "getMasterPlayer()", "get_Catalog()", "findMasterPlayer()" },
        { "_CurrentNetworkPosition" })
    D("app.cPlayerManageInfo", "System.Object", { "get_Character()", "get_Controller()", "get_Object()" })
    D("app.cPlayerController", "System.Object", { "get_ControllerEntity()" })
    D("app.cMasterPlayerControllerEntity", "System.Object", { "receiveGameMessage(ace.cGameMessage)",
        "checkContainsActionInCurrentBTable(ace.ACTION_ID, app.AppActionDef.LAYER, app.ACTION_CANCEL_INDEX)" })
    D("app.cPlayerCatalogHolder", "System.Object", { "getWeaponActionParam(app.WeaponDef.TYPE)" })
    D("via.UserData", "System.Object")
    D("app.user_data.WpActionParamBase", "via.UserData", nil, { "_GuardDegree", "_AimGuardDegree" })
    D("app.user_data.Wp00ActionParam", "app.user_data.WpActionParamBase", nil, { "_ChargeParam",
        "_ChargeParam_Strong", "_ChargeParam_Spirit", "_ChargeParam_Parry", "_ChargeParam_Fly",
        "_ChargeParam_Sliding", "_ChargeParam_BattleRide" })
    D("app.user_data.Wp00ActionParam.cCharge", "System.Object", nil, { "_OverheatTime" })
    D("ace.cGameMessage", "System.Object", { "get_SendGameObject()" }, { "_SendGameObject" })
    D("app.game_message.cMsgEmAttackAreaResult", "ace.cGameMessage", { "get_AttackAreaResult()" },
        { "<AttackAreaResult>k__BackingField" })
    D("app.game_message.cMsgParrySuccess", "ace.cGameMessage", { "get_State()" }, { "<State>k__BackingField" })
    D("app.game_message.cMsgMockNoise", "ace.cGameMessage")
    D("app.AttackAreaResult", "System.Object", {
        "get_DetectedDataList()", "get_EmID()", "get_EmSystemIndex()", "get_IsAttackFinished()", "get_KeepActionID()",
        "get_MergedAreaData()", "get_ResultType()", "get_RootMove()", "get_TargetCharacter()",
        "get_TargetCapsuleRadius()", "getCautionDetectedDataList()", "getClosestAttackParam()",
        "getClosestDetectedData()", "getDangerousDetectedDataList()",
    }, { "<DetectedDataList>k__BackingField", "<EmID>k__BackingField", "<EmSystemIndex>k__BackingField",
        "<KeepActionID>k__BackingField", "<MergedAreaData>k__BackingField", "<ResultType>k__BackingField",
        "<TargetCharacter>k__BackingField" }, { short = "AttackAreaResult" })
    D("app.AttackAreaResult.DetectedData", "System.Object", {
        "get_AttackParam()", "get_HitEndRemainFrame()", "get_HitStartRemainFrame()", "get_Obb()",
        "get_RequestSetID()", "get_ResultType()", "get_ShellIndex()",
    }, { "<AttackParam>k__BackingField", "<HitEndRemainFrame>k__BackingField",
        "<HitStartRemainFrame>k__BackingField", "<Obb>k__BackingField", "<RequestSetID>k__BackingField",
        "<ResultType>k__BackingField", "<ShellIndex>k__BackingField" }, { short = "DetectedData" })
    D("app.AttackAreaData", "System.Object", nil, { "AttackStartFrame", "AttackEndFrame" }, { short = "AttackAreaData" })
    D("System.Collections.Generic.List`1<app.AttackAreaResult.DetectedData>", "System.Object",
        { "get_Count()", "get_Item(System.Int32)", "get_Capacity()", "ToArray()" }, { "_items", "_size", "_version" },
        { short = "DetectedDataList" })
    D("System.Collections.Generic.List`1<app.AttackAreaResult>", "System.Object",
        { "get_Count()", "get_Item(System.Int32)", "get_Capacity()", "ToArray()" }, { "_items", "_size", "_version" },
        { short = "AttackAreaResultList" })
    D("app.cAttackParamBase", "System.Object", { "get_UserData()", "checkFlag(app.col_user_data.AttackParam.FLAG)" },
        { "_Attack", "_GuardType", "_DamageType", "_DamageTypeCustom", "_DamageAngle", "_UserData",
            "_VersusGuardPower", "_FixAttack", "_AttackAttr" }, { short = "AttackParam" })
    D("app.cAttackParamEm", "app.cAttackParamBase", nil, { "_DamageLevel", "_AttackFilterType", "_IsParryBreak",
        "_IsParryFix", "_IsParryStockOnly", "_IsTechGuardBreak", "_IsBlockEnable", "_EnemyDamageType",
        "_SelfAccessKey" }, { short = "AttackParamEm" })
    D("app.cAttackParamPl", "app.cAttackParamBase")
    D("via.physics.UserData", "System.Object")
    D("via.physics.RequestSetColliderUserData", "via.physics.UserData", { "get_Name()", "get_NameHash()",
        "get_RequestSetIndex()" })
    D("app.col_user_data.AttackParam", "via.physics.RequestSetColliderUserData")
    D("app.HitInfo", "System.Object", { "get_AttackOwner()", "get_DamageObj()", "get_CollisionLayer()",
        "get_AttackData()", "get_DamageData()", "get_Position()", "getActualAttackOwner()",
        "getActualDamageOwner()", "get_DamageOwner()", "get_AttackObj()", "get_HitID()", "get_DamageAttackData()",
        "get_AttackHit()", "get_DamageHit()", "get_Normal()" }, nil, { short = "HitInfo" })
    D("app.EnemyCharacter", "app.CharacterBase", {
        "getCurrentAction()", "calcMotionSpeedTotal(System.Boolean)", "get_MotionSpeed_Action()",
        "get_MotionSpeed_Base()", "get_MotionSpeed_CoreState()", "get_MotionSpeed_Random()",
        "get_MotionSpeed_Replica()", "get_MotionSpeed_ScaleAdjusted()", "get_MotionSpeed_WaitPacket()",
        "get_EffectController()", "evHit_DamagePreProcess(app.HitInfo)",
        "evHit_AttackParry(app.HitInfo, app.cAttackParamEm)", "evHit_Damage(app.HitInfo)",
    }, { "_Context", "_EffectController" }, { short = "EnemyCharacter" })
    D("app.cGameContextHolder", "System.Object")
    D("app.cEnemyContextHolder", "app.cGameContextHolder", { "get_IsMaster()", "get_Em()", "get_Chara()",
        "get_IsHealthZero()" }, { "_Em", "_Chara" }, { short = "EnemyContextHolder" })
    D("app.cEnemyContext", "System.Object", { "get_EmID()", "get_SystemIndex()" }, { "Hit", "Target", "ThisKey" },
        { short = "EnemyContext" })
    D("app.cEmModuleBase", "System.Object")
    D("app.cEmModuleHit", "app.cEmModuleBase", {
        "onParryDamage(app.TARGET_ACCESS_KEY, System.Boolean, via.GameObject)",
        "requestDelayParry(System.Single, System.Single, app.cHorizontalUDDirection, via.GameObject)",
        "updateParryInfo(app.cEnemyStockDamage)",
    }, { "DelayParryInfo", "IsParryStocked", "DamageActionType", "DamageActionID", "IsExternalDamageActionRequested" },
        { short = "EmModuleHit" })
    D("app.cEmModuleHit.cParryInfo", "System.Object", nil, { "ConditionStockDamage", "DelayFrame", "Direction", "Target" })
    D("app.cEmModuleTarget", "app.cEmModuleBase", { "getTarget(System.Boolean, app.cEmModuleTarget.TARGET_ORDER)",
        "get_This()" }, nil, { short = "EmModuleTarget" })
    D("app.EnemyManager", "System.Object", { "findEnemy_SystemIndex(System.Int32)" }, nil, { short = "EnemyManager" })
    D("app.cEnemyManageInfo", "System.Object", { "get_Character()", "get_CharacterValid()", "get_Pos()",
        "get_Context()", "get_ContextValid()", "get_Object()" }, nil, { short = "EnemyManageInfo" })
    D("app.ColliderSwitcher", "via.Behavior", { "activateAttack(System.Boolean, System.UInt32, System.UInt32, "
        .. "System.Nullable`1<System.Boolean>, app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, "
        .. "System.Nullable`1<System.Single>)" }, { "_HitController" }, { short = "ColliderSwitcher" })
    D("app.HitController", "via.Behavior", { "get_Owner()", "notifyHitProc(app.HitInfo)" })
    D("app.cEffectController", "System.Object")
    -- 静态常量（System.Single）。类型库里有这些字段，但读不到真值；这里放合理的占位值
    D("app.mcEnemyAttackAreaDetector", "System.Object", nil, nil, { values = { PLAYER_RADIUS = 0.45,
        PLAYER_HEIGHT = 1.7, DEFAULT_RADIUS = 0.5, DEFAULT_HEIGHT = 1.8, OTOMO_RADIUS = 0.35, OTOMO_HEIGHT = 0.9,
        DETECT_DISTANCE_SQ = 2500.0 } })

    -- 枚举：数值是本机游戏的真实常量（用只读脚本从 REFramework 生成的 .NET 元数据里读出来的）
    local function E(name, values) w:declare_type(name, { enum = true, values = values }) end
    E("app.AttackAreaResult.RESULT_TYPE", { SAFE = 0, CAUTION = 1, DANGER = 2 })
    E("app.HunterDef.PARRY_STATE", { NONE = 0, WAIT = 1, HIT = 2, SUCCESS = 3, RECOIL = 4 })
    E("app.Hit.RESULT", { SUCCESS = 0, FAILURE = 1, PASS = 2 })
    E("app.TARGET_ACCESS_KEY.CATEGORY", { INVALID = -1, PLAYER = 0, ENEMY = 1, OTOMO = 2, PORTER = 3, GIMMICK = 4,
        NPC = 5, MAX = 6, EM_LOST_PARTS = 7 })
    -- CATCH_ZAKO、CATCH_SLINGER（抓取，v1.5.1 否决用）：名字 2026-10-11 用 MCP get_type 核对过在类型库里，数值没读到
    -- （get_type 不给静态字段的值），这里取不和别的名字重复的占位值 —— 被测脚本按名字读，不依赖具体数值
    E("app.HitDef.DAMAGE_TYPE", { NONE = -1, NORMAL = 0, QUAKE = 1, EAR = 2, SOUND_REACT = 3, WIND = 4,
        GESTURE = 5, FLASH = 6, FORCE_KILL = 7, SLIP = 9, SMASH = 10, CATCH = 15, CATCH_ZAKO = 16, CATCH_SLINGER = 17,
        MAX = 42 })
    E("app.cEmModuleTarget.TARGET_ORDER", { FIRST = 0, SECOND = 1, MAX = 2 })
    E("app.AppActionDef.LAYER", { BASE = 0, SUB = 1, MAX = 2 })
    E("app.WeaponDef.TYPE", { INVALID = -1, LONG_SWORD = 0, SHORT_SWORD = 1, TWIN_SWORD = 2, TACHI = 3,
        HAMMER = 4, WHISTLE = 5, LANCE = 6, GUN_LANCE = 7, SLASH_AXE = 8, CHARGE_AXE = 9, ROD = 10, BOW = 11,
        HEAVY_BOWGUN = 12, LIGHT_BOWGUN = 13, MAX = 14 })
    E("app.CollisionFilter.LAYER", { ATTACK_GET = 16, ATTACK_PARRY_PUT = 17, ATTACK_PARRY_GET = 18 })
    E("app.HunterDef.STATUS_FLAG", { NO_DAMAGE = 0, GUARD = 2, POWER_GUARD = 3, TECHNICAL_GUARD = 4,
        GUARD_POINT = 6, SUPER_ARMOR = 7, HYPER_ARMOR = 8, KEEP_STUN_REQUEST = 15, NO_DAMAGE_REACTION = 16,
        WP_05_SUPER_ARMOR = 85 })
    E("app.HunterDef.CONTINUE_FLAG", { WP_ATTACK_COLLISION_ON = 93, PARRY_IMMDIATE = 96, PARRY_COMBO = 286 })
    E("app.EnemyDef.ID", { INVALID = -1, EM0001_00_0 = 0, EM0165_00_0 = 33, EM0020_00_0 = 156 })
    E("app.EnemyDef.Damage.ACTION_TYPE", { NONE = 0, PARRY = 140, BLOCK = 141 })
    E("app.ACTION_CANCEL_INDEX", { Invalid = 0 })
    -- 动作属性：AutoGuardGS 的「不能举剑」黑名单（BLOCKED_ATTR_NAMES）逐个按名字读。真值没读到（get_type 不给静态字段的值），
    -- 数值只要互不相同（game_sim 按名字判断某个属性此刻是否成立）
    local attrs = { NONE = 0 }
    for i, n in ipairs({ "DODGE", "DODGE_BACK", "DODGE_LEFT", "DODGE_RIGHT", "DAMAGE", "DAMAGE_DOWN", "DAMAGE_SLIP",
        "SMASH_DAMAGE", "SMASH_DAMAGE_LAND", "PRONE", "SUPINE", "STUN", "SLEEP", "PARALYZE", "FROZEN", "STICKY", "QUAKE",
        "ITEM_USE", "WP_OFF", "BATTLE_RIDING", "PORTER", "TARZAN_ATTACH", "USE_ROPE", "HAGITORI", "FACILITY",
        "COMMUNICATION", "PETTING", "DIE" }) do attrs[n] = i end
    E("app.HunterDef.ACTION_ATTR", attrs)
    E("app.Hit.GUARD_TYPE", { NORMAL = 0, ALL_RANGE = 1, UNABLE_GUARD = 2, SKILL_GUARD = 3, SKILL_GUARD_ALL_RANGE = 4,
        MAX = 5 })
    E("app.HunterDef.GUARD_REACTION", { NONE = 0, S = 1, M = 2, L = 3, TECHNICAL = 4, TECHNICAL_M = 5, BLOCK = 6,
        LASER = 7, GUARD_POINT_S = 8, GUARD_POINT_M = 9, GUARD_POINT_L = 10, MAX = 14 })
    E("app.PlayerDef.NETWORK_POSITION", { NONE = 0, QUEST = 1, LOBBY = 2, VISUAL_LOBBY = 3, LINKED = 4 })
    E("app.Wp00Def.CHARGE_LEVEL", { LV0 = 0, LV1 = 1, LV2 = 2, LV3 = 3, MAX = 4 })
    E("app.Hit.HIT_ID_GROUP", { NONE = -1, GROUP_00 = 0, GROUP_01 = 1, GROUP_02 = 2, GROUP_03 = 3, MAX = 32 })
    E("app.EnemyDef.ACT_ATTR", {})
end

-- 高频、禁止钩的函数（PLAN DROPPED：onParryHitPreProcess 每秒 6~18 万次）
M.FORBIDDEN_HOOK_NAMES = { onParryHitPreProcess = true }

M.SKIP_ORIGINAL = SKIP_ORIGINAL
M.new_ptr = new_ptr

return M

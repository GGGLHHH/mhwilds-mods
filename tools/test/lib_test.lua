-- tools/test/lib_test.lua：共享库 src/lib/ 的单元测试。不开游戏，REF 的全局 API 用最小的桩代替。
-- 用法（仓库根目录）：lua tools/test/lib_test.lua     退出码 0 = 全部通过
--
-- 库按打包后的样子载入：模块名 "<Mod>.lib.<名字>" 映射到 src/lib/<名字>.lua（tools/build.sh 把库复制进每个 mod 的
-- <Mod>/lib/）。用两个命名空间 T、U 各载入一份，核对两份互不相干（docs/ARCHITECTURE.md「库没有模块级状态」）。
-- 游戏层 lib/wilds/ 只在这里核对能载入；它们的行为由 mock（tools/mock/run.lua --merged）对着真实的调用顺序验证。
local here = arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]*$") or "tools/test"
local ROOT = here .. "/../.."

table.insert(package.searchers, 2, function(name)
    local rest = name:match("^[TU]%.lib%.(.+)$")
    if not rest then return nil end
    local file = ROOT .. "/src/lib/" .. rest:gsub("%.", "/") .. ".lua"
    local f, err = loadfile(file)
    if not f then return "\n\t" .. tostring(err) end
    return f, file
end)

-- ---------- REF 全局 API 的桩 ----------
local lines = {}            -- 写出的日志 { level, text }
log = {
    info = function(t) lines[#lines + 1] = { "info", t } end,
    warn = function(t) lines[#lines + 1] = { "warn", t } end,
}
local files, dump_ret, load_throws = {}, nil, false
json = {
    load_file = function(p)
        if load_throws then error("file busy") end
        return files[p]
    end,
    dump_file = function(p, t)
        if dump_ret == false then return false end
        files[p] = t
        return true
    end,
}
local now = 0.0
os.clock = function() return now end
local drawn, popped = {}, 0
imgui = {
    text = function(t) drawn[#drawn + 1] = t end,
    tree_node = function() return true end,
    tree_pop = function() popped = popped + 1 end,
}
sdk = {}
local enum_td = {
    get_fields = function()
        return { { is_static = function() return true end, get_name = function() return "A" end,
            get_data = function() return 1 end } }
    end,
    get_field = function(_, n)
        if n == "B" then return { get_data = function() return 2 end } end
        return nil
    end,
}
local hooks = {}            -- sdk.hook 登记的 { pre, post }
local hook_td = {
    get_method = function(_, sig) return sig == "m()" and { sig = sig } or nil end,
    get_full_name = function() return "app.T" end,
}
sdk.find_type_definition = function(n)
    if n == "E" then return enum_td end
    if n == "app.T" then return hook_td end
    return nil
end
sdk.hook = function(_, pre, post) hooks[#hooks + 1] = { pre = pre, post = post } end
sdk.get_managed_singleton = function() return nil end
local cbs = {}              -- re.* 登记的回调
re = {
    on_pre_application_entry = function(_, fn) cbs.frame = fn end,
    on_script_reset = function(fn) cbs.reset = fn end,
    on_config_save = function(fn) cbs.save = fn end,
    on_draw_ui = function(fn) cbs.ui = fn end,
}
imgui.checkbox = function(_, v) return false, v end
imgui.same_line = function() end
imgui.separator = function() end
imgui.text_colored = function(t) drawn[#drawn + 1] = t end

-- ---------- 小测试框架 ----------
local fails, n = 0, 0
local function check(cond, what)
    n = n + 1
    if cond then
        print("  ✓ " .. what)
    else
        fails = fails + 1
        print("  ✗ " .. what)
    end
end
local function last() return lines[#lines] and lines[#lines][2] end
local function clear() lines = {} end

-- ---------- 各模块 ----------
print("util")
local util = require("T.lib.util")
local fmt_errs = {}
local F = util.formatter(function(m) fmt_errs[#fmt_errs + 1] = m end)
check(F.int(3) == "3" and F.int(3.0) == "3" and F.int(2.5) == "2.5", "int：整数不带小数、非整数 %.1f")
check(F.hex(255) == "FF" and F.hex(1.5) == nil, "hex：整数转十六进制，非整数 nil")
check(F.fmt("%d", "x") == "FMT_ERR %d" and fmt_errs[1] == "FMT_ERR %d", "fmt：格式化抛错时返回 FMT_ERR 并回调")
check(util.finite(1) and not util.finite(0 / 0) and not util.finite(math.huge) and not util.finite("1"), "finite")
check(util.clean_str("a b\tc") == "a_b_c", "clean_str：空白换成 _")
check(util.clamp(5, 0, 3) == 3 and util.clamp(-1, 0, 3) == 0, "clamp")

print("log")
local Log = require("T.lib.log")
local dbg = false
local L = Log.new({ tag = "[T] ", debug_on = function() return dbg end, warn_max = 2 })
clear()
L.debug("x")
check(#lines == 0, "调试日志关着时 debug 不写")
dbg = true
L.debug("x")
check(last() == "[T] x", "调试日志开着时 debug 写，带标签")
clear()
for _ = 1, 5 do L.warn_err("k", "boom") end
L.warn_err("other", "boom")
check(#lines == 3 and lines[1][2] == "[T] k err: boom" and lines[3][2] == "[T] other err: boom", "warn_err 每类最多 warn_max 行")

print("record")
local Record = require("T.lib.record")
local hdr_val = "a"
local R = Record.new({ tag = "[REC]", fmt = F, header_kind = "HDR", header = function() return { hdr_val } end,
    spec = { HDR = "v:s", X = "i:i f:f2 b:b h:h s:s" } })
clear()
R.emit("X", { 1, 1.234, true, 255, "a b" })
check(#lines == 0, "加载期间的行先攒着")
hdr_val = "late"
R.finish_loading(false)
check(#lines == 2 and lines[1][2] == "[REC] HDR v=late" and lines[2][2] == "[REC] X i=1 f=1.23 b=1 h=FF s=a_b",
    "加载完：先写头行（取那一刻的值）再写攒下的行；各格式")
clear()
R.emit("X", { nil, 0 / 0, false, nil, nil })
check(#lines == 1 and lines[1][2] == "[REC] X i=- f=- b=0 h=- s=-", "头行只写一次；nil、NaN 写 -")
local R2 = Record.new({ tag = "[REC]", fmt = F, header_kind = "HDR", header = function() return { "v" } end,
    spec = { HDR = "v:s" } })
clear()
R2.finish_loading(false)
check(#lines == 0, "没有攒下的行、不要求头行时什么都不写")

print("health")
local Health = require("T.lib.health")
local emitted = {}
local H = Health.new({ core = { frame = true }, emit = function(k, v) emitted[#emitted + 1] = { k, v } end, log_max = 4 })
now = 0.0
H.note("opt", "e1")
check(H.off.opt and H.yellow == 1 and not H.red, "可选模块第一次出错标黄")
H.note("opt", "e2")
check(H.yellow == 1, "同一个可选模块再出错不重复计黄")
now = 1.0; H.note("frame", "a")
now = 20.0; H.note("frame", "b")
check(not H.red, "核心模块 10 s 内不到 3 次不标红")
now = 21.0; H.note("frame", "c")
now = 22.0; H.note("frame", "d\200")
check(H.red and emitted[#emitted][1] == "RED", "核心模块 10 s 内 3 次标红，写 RED")
check(#emitted == 5, "ERR 每次加载最多 log_max 行（4 行 ERR + 1 行 RED）")
check(emitted[4][1] == "ERR" and emitted[4][2][1] == "frame" and emitted[4][2][2] == "red" and emitted[4][2][3] == "b",
    "ERR 写模块、级别、文本")
H.set_red(23.0, "frame", "again")
check(#emitted == 5, "已经红了不再写 RED")
H.set_red(23.0, "frame", "self_stop")
check(#emitted == 6 and emitted[6][2][3] == "self_stop", "自停另写一行 RED")

print("config")
local Config = require("T.lib.config")
local errs = {}
local data = { on = true, n = 1, opt = nil }
files["c.json"] = { on = false, n = "x", opt = 500, unknown = 1 }
local C = Config.new({ path = "c.json", data = data, on_error = function(e) errs[#errs + 1] = e end,
    validators = { opt = function(v) return type(v) == "number" and math.min(v, 100) or nil end } })
C.load()
check(data.on == false and data.n == 1 and data.opt == 100 and data.unknown == nil,
    "类型相同才收、validator 判断默认 nil 的键、不认识的键忽略")
dump_ret = false
C.save()
check(errs[1] == "config dump_file returned false", "dump_file 返回 false 报错")
dump_ret = nil
load_throws = true
local data2 = { on = true }
local C2 = Config.new({ path = "c2.json", data = data2, on_error = function(e) errs[#errs + 1] = e end })
C2.load()
load_throws = false
C2.save()
check(C2.unreadable and files["c2.json"] == nil, "读的时候抛错：这次加载不写配置")

print("patch")
local patch = require("T.lib.patch")
local obj = { f = { a = 1, b = 2 } }
function obj:get_field(k) return self.f[k] end
function obj:set_field(k, v)
    if self.fail == k then error("set fail") end
    self.f[k] = v
end
local p = patch.new()
check(p:begin() and not p:begin(), "begin：已经改过还没还原时返回 false")
p:set(obj, "a", 10)
p:set(obj, "b", 20)
check(obj.f.a == 10 and p:count() == 2, "set 改值并记原值")
obj.fail = "b"
check(not pcall(function() p:restore() end) and p:active(), "restore 写回抛错：记录留着")
obj.fail = nil
p:restore()
check(obj.f.a == 1 and obj.f.b == 2 and not p:active(), "restore 写回原值、清掉记录")
p:set(obj, "a", 10)
obj.fail = "a"
p:restore_each()
obj.fail = nil
check(not p:active() and obj.f.a == 10, "restore_each：写不回的放弃，记录一律清掉")
obj.f.a = 1
p:set(obj, "a", 5)
p:set(obj, "a", 7)
p:restore()
check(obj.f.a == 1, "同一个字段改两次：后进先出，还原回真正的原值")

print("ui")
local Ui = require("T.lib.ui")
local ui_errs = 0
local U = Ui.new({ retry = 2.0, on_error = function() ui_errs = ui_errs + 1 end })
now = 100.0
local calls = 0
local function bad_part() calls = calls + 1; error("draw fail") end
U.part("p", bad_part)
now = 101.0
drawn = {}
U.part("p", bad_part)
check(ui_errs == 1 and calls == 1 and drawn[1] ~= nil, "出错后 retry 秒内只画提示")
now = 103.0
U.part("p", bad_part)
check(calls == 2 and ui_errs == 2, "retry 秒后再试")
popped = 0
U.tree("x##x", function() error("inner") end)
check(popped == 1 and ui_errs == 3, "树节点里出错也配对 tree_pop")

print("prof")
local Prof = require("T.lib.prof")
local reports = {}
now = 0.0
local P = Prof.new({ keys = { "a" }, interval = 5.0, on_report = function(t) reports[#reports + 1] = t end })
local timed = P.timed("a", function(x) return x * 2 end)
check(timed(21) == 42, "timed 原样返回")
now = 4.0; P.report()
check(#reports == 0, "不到 interval 不汇总")
now = 5.0; P.report()
check(#reports == 1 and P.text:match("^a 0/s") ~= nil, "满 interval 汇总，P.text 是最近一次的文字")

print("ref")
local ref = require("T.lib.ref")
check(ref.enum_value("E", "A") == 1 and ref.enum_value("E", "B") == 2, "enum_value：先找静态字段，再按名字取")
local into, miss = {}, {}
local first = ref.enum_into("E", { "A", "Z", "B" }, into, miss)
check(into[1] == "A" and into[2] == "B" and miss[1] == "Z" and first ~= nil, "enum_into：读不到的进 miss，返回第一个错误")
check(not pcall(ref.need, nil, "X") and select(2, pcall(ref.need, nil, "X")) == "X not found", "need：报清楚缺了哪个")

local by_value, by_name = ref.enum_map("E")
check(by_value[1] == "A" and by_name.A == 1, "enum_map：值 → 名字、名字 → 值")
check(not pcall(ref.enum_map, "nope"), "enum_map：类型拿不到抛错")

print("mod（骨架）")
local Mod = require("T.lib.mod")
files["Tm.json"] = { strength = 9 }
clear()
local m = Mod.new({ name = "Tm", version = "v0.1", config = { strength = 1 },
    validators = { strength = function(v) return math.min(v, 2) end } })
check(m.config.strength == 2 and m.config.enabled == true and m.config.debug_log == false,
    "读配置走 validator；enabled、debug_log 自动补上")
local pre_calls, frames = 0, {}
m.hook("app.T", "m()", function() pre_calls = pre_calls + 1; error("pre boom") end,
    function(r) error("post boom") end)
check(#hooks == 1, "hook 登记了一个钩子")
check(hooks[1].pre({}) == nil and pre_calls == 1, "pre 出错：返回 nil（照常调用原函数）")
check(hooks[1].post("rv") == "rv", "post 出错：原样返回 retval")
check(not pcall(m.hook, "app.T", "missing()", function() end), "方法拿不到时抛错")
m.config.enabled = false
hooks[1].pre({})
check(pre_calls == 1, "「启用」关着时不调 pre")
m.config.enabled = true
local pf = m.patch({ per_frame = true })
local keep = m.patch()
local o2 = { f = { x = 1, y = 1 } }
function o2:get_field(k) return self.f[k] end
function o2:set_field(k, v) self.f[k] = v end
m.on_frame(function(snap) frames[#frames + 1] = snap == nil and "nil" or "snap" end)
m.on_frame(function() error("frame boom") end)
m.menu("main", function() drawn[#drawn + 1] = "main" end)
m.start()
check(not pcall(m.start), "start 只能调一次")
check(last() == "[Tm] v0.1 loaded", "start 写 loaded")
pf:set(o2, "x", 5)
keep:set(o2, "y", 7)
cbs.frame()
check(o2.f.x == 1 and o2.f.y == 7, "帧开头：per_frame 的改写还原，其余的留着")
check(frames[1] == "nil", "没有主角时帧回调拿到 nil 快照；一个回调出错不影响别的")
cbs.reset()
check(o2.f.y == 1, "Reset：全部还原")
m.config.enabled = false
cbs.frame()
check(#frames == 1, "「启用」关着时帧回调不跑")
drawn = {}
popped = 0
cbs.ui()
check(drawn[#drawn] == "main" and popped == 1, "菜单：画了 main 一块，树节点配对 tree_pop")
cbs.save()
check(files["Tm.json"] and files["Tm.json"].strength == 2, "存配置")

print("隔离（同一份库挂在两个 mod 名下）")
local LogU = require("U.lib.log")
check(LogU ~= Log and require("U.lib.util") ~= util, "T.lib.* 和 U.lib.* 是两份模块")
clear()
local La = Log.new({ tag = "[A] ", debug_on = function() return false end, warn_max = 1 })
local Lb = LogU.new({ tag = "[B] ", debug_on = function() return false end, warn_max = 1 })
La.warn_err("k", 1); La.warn_err("k", 2); Lb.warn_err("k", 3)
check(#lines == 2 and lines[2][2] == "[B] k err: 3", "两个实例的限量互不影响")

print("游戏层能载入")
for _, m in ipairs({ "player", "action", "weapon", "hunter", "enemy", "forecast" }) do
    local ok, mod = pcall(require, "T.lib.wilds." .. m)
    check(ok and type(mod) == "table", "lib/wilds/" .. m)
end

if fails == 0 then
    print(string.format("lib 单元测试：%d 条全部通过", n))
    os.exit(0)
end
print(string.format("lib 单元测试：%d 条失败（共 %d 条）", fails, n))
os.exit(1)

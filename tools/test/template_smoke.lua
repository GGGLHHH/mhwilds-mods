-- tools/test/template_smoke.lua：新 mod 模板的冒烟测试。用 mock（tools/mock/mock_ref.lua）的假 REF 把组装好的模板
-- （tools/build.sh 的产物，带共享库）载入，跑几秒帧回调、画菜单、存配置、Reset，核对：
--   加载不报错、require 都找得到；没有违规（读写全局变量、imgui 栈不平衡、未捕获的错误）；写了 loaded；配置能存。
-- 用法：lua tools/test/template_smoke.lua 入口脚本路径     （tools/test.sh 会先组装再调用）
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "tools/test"
package.path = here .. "/../mock/?.lua;" .. package.path
local mock = require("mock_ref")

local entry = arg[1]
if not entry then
    print("用法：lua tools/test/template_smoke.lua 入口脚本路径")
    os.exit(2)
end
local name = entry:match("([^/\\]+)%.lua$")
local out_dir = (entry:match("^(.*)[/\\]reframework[/\\]") or ".") .. "/smoke_out"

local w = mock.new_world({ out_dir = out_dir, dt = 1 / 60 })
local fails = 0
local function check(cond, what)
    print((cond and "  ✓ " or "  ✗ ") .. what)
    if not cond then fails = fails + 1 end
end

local ok, err = w:load_script(name, entry, name)
check(ok, "加载：" .. tostring(err or "ok"))
for _ = 1, 180 do
    w.t = w.t + w.dt
    w.frame = w.frame + 1
    w.phase = "pre"
    w:run_cbs("pre:UpdateBehavior")
    if w.frame % 9 == 0 then
        w.phase = "ui"
        w.menu = {}
        w:run_cbs("draw_ui", true)
    end
end
w.phase = "late"
w:run_cbs("config_save")
w.phase = "reset"
w:run_cbs("reset")

local loaded = false
for _, l in ipairs(w.logs) do
    if l.text:find(name .. "%] v[%d.]+ loaded") then loaded = true end
end
check(loaded, "日志里有 [" .. name .. "] … loaded")
local mods = w.scripts[name] and w.scripts[name].modules or {}
local nmod = 0
for _ in pairs(mods) do nmod = nmod + 1 end
check(nmod > 0, "通过 require 载入了 " .. nmod .. " 个模块")
check(#w.violations == 0, "没有违规")
for _, v in ipairs(w.violations) do print("      " .. v.kind .. "：" .. v.msg) end

if fails == 0 then
    print("模板冒烟：全部通过")
    os.exit(0)
end
print("模板冒烟：" .. fails .. " 项失败")
os.exit(1)

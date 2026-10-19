-- ModTemplate v0.1：新 mod 的起点（tools/new_mod.sh 名字 会复制这个目录并把 ModTemplate 换成新名字）
--
-- 结构（docs/ARCHITECTURE.md）：
--   reframework/autorun/ModTemplate.lua        入口
--   reframework/autorun/ModTemplate/*.lua      这个 mod 自己的模块：require("ModTemplate.xxx")
--   reframework/autorun/ModTemplate/lib/       共享库，打包时由 tools/build.sh 复制进来（源码在 src/lib/，别在这里建 lib/）
--
-- 骨架 lib/mod 已经接好：配置读写（REF 存配置时落盘）、日志、性能计数、菜单（启用、调试日志两个勾选框）、钩子和帧回调的
-- pcall、共享参数改写的还原（per_frame 的每帧开头还原，全部在 Reset 时还原）。项目约定（CLAUDE.md）里剩下要自己做的：
-- 受击结算期间改的共享参数，在结算后（后置钩子里）立刻 restore；菜单文字用中文，控件标签带 ##英文ID；
-- 新机制先在 probes/ 写只记录的探针验证，再进这里。
local LIB = "ModTemplate.lib."
local util = require(LIB .. "util")
local Mod = require(LIB .. "mod")

local mod = Mod.new({
    name = "ModTemplate",
    version = "v0.1",
    title = "模板 Mod",
    config = {
        strength = 1.0,     -- 示例：数值配置，validator 夹到合法范围（enabled、debug_log 由骨架补上）
    },
    validators = {
        strength = function(v) return util.finite(v) and util.clamp(v, 0.0, 2.0) or nil end,
    },
})
local config, L = mod.config, mod.L

-- 改共享参数（例如 lib/wilds/weapon 的 action_param）的写法：
--   local angle = mod.patch({ per_frame = true })
--   if angle:begin() then angle:set(param, "_GuardDegree", 360.0) end    -- 受击前置钩子里改
--   angle:restore()                                                       -- 后置钩子里还原；漏了骨架每帧开头兜底

local frames_with_hunter = 0

-- 帧开头（UpdateBehavior 之前）。改动作（lib/wilds/action 的 request）只能在这里做；受击结算中途只能改状态
-- （NOTES「改状态 vs 改动作」）。snap 为 nil = 这一帧没有主角
mod.on_frame(function(snap)
    if not snap then return end
    frames_with_hunter = frames_with_hunter + 1
    if frames_with_hunter % 600 == 1 then
        L.debug(string.format("weapon %s action (%s,%s)", tostring(snap.wtype), tostring(snap.cat), tostring(snap.idx)))
    end
end)

-- 钩子示例（默认「启用」关着时不调；出错只写警告）：
-- mod.hook("app.HunterCharacter", "evHit_Damage(app.HitInfo)", nil, function(retval) return retval end)

mod.menu("main", function()
    local changed, v = imgui.slider_float("强度##strength", config.strength, 0.0, 2.0, "%.2f")
    if changed then config.strength = v end
end)

mod.start()

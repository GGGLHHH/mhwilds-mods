-- lib/mod：mod 的骨架。把每个 mod 都要写的接线收在一起：配置读写、日志、性能计数、帧回调、Reset、存配置、菜单。
-- 思路参考了 _CatLib 的 NewMod（一行建好一个 mod），另外加上本项目的约定：
--   - 钩子、帧回调、菜单都包 pcall，出错写警告（按类别限量），不让错误漏进游戏
--   - 共享参数的改写用 M.patch() 登记：per_frame 的每帧开头还原，全部在 Reset 时还原（三处兜底里的两处，
--     第三处「结算后」由钩子自己调 restore）
--   - 配置什么时候落盘由 REF 决定（re.on_config_save），不在菜单每改一次就写盘
--   - 「启用」关着时帧回调和带闸门的钩子都不跑，但还原照做
--
-- 用法（templates/ModTemplate 是完整的例子）：
--   local M = Mod.new({ name = "MyMod", version = "v0.1", title = "我的 Mod",
--       config = { enabled = true, debug_log = false, strength = 1.0 },
--       validators = { strength = function(v) ... end } })
--   M.hook("app.HunterCharacter", "evHit_Damage(app.HitInfo)", nil, function(retval) ... end)
--   M.on_frame(function(snap) ... end)   -- snap = lib/wilds/player 的快照：{ hunter, addr, wtype, cat, idx }
--   M.menu("main", function() ... end)
--   M.start()                            -- 最后调一次：挂回调、写 loaded
--
-- 不适合用它的：对帧内顺序有逐项等价要求的老 mod（AutoGuardGS 照旧自己接线，它的调用顺序被 mock 逐刀比对着）。
local LIB = ((...) or error("lib 模块要用 require 载入")):gsub("[^.]+$", "")
local Log = require(LIB .. "log")
local Prof = require(LIB .. "prof")
local Config = require(LIB .. "config")
local Ui = require(LIB .. "ui")
local ref = require(LIB .. "ref")
local patch = require(LIB .. "patch")
local Player = require(LIB .. "wilds.player")

local M = {}

-- opts.name：标签、配置文件名、菜单 ID（只用 [A-Za-z0-9_]）；opts.version；opts.title：菜单里显示的名字（默认 name）；
-- opts.config：默认配置（原地改，enabled、debug_log 没写就补上）；opts.validators：见 lib/config；
-- opts.config_path：默认 "<name>.json"；opts.prof_keys：除 frame 以外还要计时的名字（给 M.timed 用）
function M.new(opts)
    local name, version = opts.name, opts.version or ""
    local config = opts.config or {}
    if config.enabled == nil then config.enabled = true end
    if config.debug_log == nil then config.debug_log = false end

    local mod = { name = name, version = version, config = config }
    local L = Log.new({ tag = "[" .. name .. "] ", debug_on = function() return config.debug_log end })
    local keys = { "frame" }
    for _, k in ipairs(opts.prof_keys or {}) do keys[#keys + 1] = k end
    local prof = Prof.new({ keys = keys, on_report = function(text) L.debug("PERF " .. text) end })
    local cfg = Config.new({ path = opts.config_path or (name .. ".json"), data = config, validators = opts.validators,
        on_error = function(err) L.warn_err("cfg", err) end })
    local U = Ui.new({ on_error = function(err) L.warn_err("ui", err) end })
    mod.L, mod.prof, mod.cfg, mod.ui = L, prof, cfg, U
    mod.timed = prof.timed

    local frame_fns, reset_fns, menus = {}, {}, {}
    local patches = {}      -- { p = patch, per_frame = bool }
    local started = false

    local ok, err = pcall(cfg.load)
    if not ok then L.warn_err("cfg", err) end

    -- 登记一份共享参数的改写。per_frame = true：不许跨帧（例如只在受击结算期间改），每帧开头兜底还原
    function mod.patch(popts)
        local p = patch.new()
        patches[#patches + 1] = { p = p, per_frame = popts and popts.per_frame or false }
        return p
    end

    -- 钩子。pre / post 各自包 pcall：pre 出错返回 nil（照常调用原函数），post 出错原样返回 retval；
    -- 「启用」关着时不调 pre / post，除非 hopts.always。类型、方法拿不到时抛错（初始化就该失败，别悄悄不工作）
    function mod.hook(type_name, sig, pre, post, hopts)
        local always = hopts and hopts.always
        local kind = (hopts and hopts.kind) or sig:match("^[%w_]+") or "hook"
        local wpre, wpost = nil, nil
        if pre then
            wpre = function(args)
                if not always and not config.enabled then return nil end
                local okp, r = pcall(pre, args)
                if okp then return r end
                L.warn_err(kind, r)
                return nil
            end
        end
        if post then
            wpost = function(retval)
                if not always and not config.enabled then return retval end
                local okp, r = pcall(post, retval)
                if not okp then
                    L.warn_err(kind, r)
                    return retval
                end
                if r == nil then return retval end
                return r
            end
        end
        ref.hook(ref.type(type_name), sig, wpre, wpost)
    end

    function mod.on_frame(fn) frame_fns[#frame_fns + 1] = fn end
    function mod.on_reset(fn) reset_fns[#reset_fns + 1] = fn end
    function mod.menu(part, fn) menus[#menus + 1] = { part = part, fn = fn } end

    local function restore_all(strict_per_frame_only)
        for _, e in ipairs(patches) do
            if strict_per_frame_only then
                if e.per_frame then
                    local okr, er = pcall(e.p.restore, e.p)
                    if not okr then L.warn_err("restore", er) end
                end
            else
                e.p:restore_each()
            end
        end
    end
    mod.restore_all = function() restore_all(false) end

    local function frame()
        local okp, er = pcall(prof.report)
        if not okp then L.warn_err("perf", er) end
        restore_all(true)
        if not config.enabled then return end
        local snap = nil
        local oks, hunter, addr, wtype, cat, idx = pcall(Player.snapshot)
        if not oks then
            L.warn_err("snapshot", hunter)
        elseif hunter then
            snap = { hunter = hunter, addr = addr, wtype = wtype, cat = cat, idx = idx }
        end
        for _, fn in ipairs(frame_fns) do
            local okf, ef = pcall(fn, snap)
            if not okf then L.warn_err("frame", ef) end
        end
    end

    local function draw_header()
        if cfg.unreadable then
            imgui.text_colored("读不出配置文件 " .. (opts.config_path or (name .. ".json"))
                .. "：这次用默认设置，改动也不保存。Reset Scripts 重读", Ui.COLOR.RED)
        end
        local changed, v = imgui.checkbox("启用##enabled", config.enabled)
        if changed then config.enabled = v == true end
        imgui.same_line()
        changed, v = imgui.checkbox("调试日志##debug_log", config.debug_log)
        if changed then config.debug_log = v == true end
        if config.debug_log then imgui.text("性能（每秒）：" .. (prof.text ~= "" and prof.text or "统计中……")) end
    end

    function mod.start()
        if started then error("mod.start 只能调一次", 2) end
        started = true
        re.on_pre_application_entry("UpdateBehavior", prof.timed("frame", frame))
        re.on_script_reset(function()
            local okr, er = pcall(restore_all, false)
            if not okr then L.warn_err("reset", er) end
            for _, fn in ipairs(reset_fns) do
                local okf, ef = pcall(fn)
                if not okf then L.warn_err("reset", ef) end
            end
        end)
        re.on_config_save(function()
            local oks, es = pcall(cfg.save)
            if not oks then L.warn_err("cfg", es) end
        end)
        re.on_draw_ui(function()
            U.tree((opts.title or name) .. " " .. version .. "##" .. name, function()
                U.part("_header", draw_header)
                for _, m in ipairs(menus) do
                    imgui.separator()
                    U.part(m.part, m.fn)
                end
            end)
        end)
        L.info(version .. " loaded")
    end
    return mod
end

return M

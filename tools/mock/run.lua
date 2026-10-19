-- tools/mock/run.lua：不开游戏，用假的 REF API 逐帧驱动放刀模块（AutoParryGS）和探针（AutoParryCalib.lua）
--
-- 合并模式（docs/autoparry/MERGE.md 第 6 节）：放刀逻辑已并入 AutoGuardGS.lua（AutoGuardGS v1.5，放刀规则版本仍记 1.6），
-- 独立的 v1.6 归档在 tools/archive/AutoParryGS_v1.6.lua，作为参照组 A0。
--   lua tools/mock/run.lua             144 个场景原样跑 A0（归档的 v1.6），原有断言全部照查（集成时 133 个，审查后补了 11 个）
--   lua tools/mock/run.lua --merged    另外把每个 v16 场景（两个引用负对照除外，共 132 个）用合并脚本再跑两遍：
--                                      B = 调试日志开（out/<场景>/merged_on/）、C = 调试日志关（.../merged_off/），
--                                      逐刀和 A0 比（请求序列、FIRE / RES 字段、计数、RED、错误、状态行、引用记账），
--                                      结果写 out/<场景>/equiv.txt，任何一项不同就判失败；再跑只在合并模式下有的新场景
--                                      （防御功能对归档的 v1.4.2、配置迁移、两部分交互、调试日志开关、加载隔离、Reset 还原、
--                                      菜单、引用负对照，MERGE 第 6.5 节）
--   别名（合并模式下改写场景，MERGE 第 6.2 节第 2 条）：faults / ui 里的脚本名 AutoParryGS → AutoGuardGS；菜单操作按 ID 匹配
--   （启用 → ##ap_enabled、提前量 → ##ap_lead、清零统计 → ##reset_stats、调试日志 → ##debug_log），「写出数据」丢掉；
--   config.AutoParryGS 原样写成旧的 AutoParryGS.json（走迁移），AutoGuardGS.json 只写 { debug_log = 这一组的开关 }。
--
-- 放刀模块按场景的 rc_ver 选（docs/autoparry/V16.md 第 8.5 节）：
--   v16（默认）= 归档的 v1.6 tools/archive/AutoParryGS_v1.6.lua（MERGE 第 6.1 节：src/ 里已经没有独立的放刀脚本）；
--   v15        = 归档的 v1.5.1（tools/archive/AutoParryGS_v151.lua，没有就用 tools/mock/archive/ 下的同名副本），
--                只给引用记账的负对照用（V16 第 8.4 节第 41 条）；
--   rc1        = 归档的第 1 轮标定版 tools/archive/AutoParryGS_rc1.lua，只给 rc 专有的场景（轮换、机关扫描、
--                FB 兜底、HUD），保证探针和分析脚本的回归不丢。
-- 探针按场景的 probe_ver 选：不写 = probes/AutoParryCalib.lua（引用记账已修：只 add_ref、不 release）；
--   "1.0.1" = 归档的 apcal-1.0.1（AutoParryCalib_1.0.1.lua，会手动 release，只给负对照用）；false = 不载入探针。
-- 用法（仓库根目录）：
--   lua tools/mock/run.lua                     跑全部场景
--   lua tools/mock/run.lua two_entries shell   只跑指定场景
--   选项：--smoke            用 tools/mock/smoke/ 下的冒烟脚本（验证 mock 本身；冒烟 rc 按 rc1 口径、旧的按脚本计数
--                            的引用模型，跳过只测正式脚本功能的场景）
--         --merged           合并模式（见上）；--merged-path PATH 指定被测的合并脚本（变异测试用，默认组装好的 build/AutoGuardGS/…/AutoGuardGS.lua，
--                            先跑 tools/build.sh；它的模块在同一 autorun 目录下按名字找，
--                            给了路径就同时打开合并模式）；--guard142 PATH 指定归档的 v1.4.2（防御场景的参照组）
--         --rc PATH          指定 v16 场景的被测放刀脚本（变异测试用它指向 scratchpad 里改坏的副本）；
--         --rc151 PATH       指定归档 v1.5.1；--rc1 PATH 指定 rc1；--probe PATH 指定探针；--probe101 PATH 指定归档 apcal-1.0.1
--         --gc-every-frame   每帧末都强制回收（V16 第 8.2 节第 3 条的原样观测方式，慢 3~10 倍；默认只在要观测的帧回收，
--                            见「持有观测」）
--         --default-ver VER  开发用：没写 rc_ver 的场景按 VER（v16 / v15 / rc1）跑；--ref-model real|legacy 强制引用模型
--                            （例如 --default-ver v15 --ref-model legacy 用归档 v1.5.1 核对 mock 自身的改动没破坏旧口径）
--         --allow-missing    缺一个脚本时只跑另一个（缺的那个的断言跳过）
--         --out DIR          输出目录（默认 tools/mock/out）
--         --list             列出场景
--         --verbose          失败时打印更多细节
-- 输出：tools/mock/out/<场景>/ 下有 ref.log（REF 格式日志）、两个脚本写出的 JSON、summary.txt（断言明细）、
--       mock_truth.json（模拟器真值：每次放刀、每次接触）、hud.txt、menu.txt。合并模式另有 merged_on/、merged_off/ 两个子目录
--       （同样的文件）和 equiv.txt（逐刀等价的结论和差异）；新场景每个跑法一个子目录，另有 checks.txt（跨跑法的检查）。
-- 退出码：0 = 全部通过；1 = 有断言失败；2 = 缺少被测脚本。
--
-- 合并脚本（和防御参照组 v1.4.2）每次跑都查（MERGE 第 6.2 节第 4 条，check_*_merged），替换 v1.6 的发布版断言：
--   加载不报错、不写全局变量、没有 FMT_ERR；钩子恰好 5 个（v1.4.2 恰好 4 个）；副作用白名单 —— (2,23) 只在帧开头的快照是
--   (2,21)/(2,22) 时请求，肩撞只在普通蓄力且有肩撞请求在等时请求，防御标志 on 只在受击前置钩子里，off 和角度还原只在后置钩子、
--   帧开头、Reset，角度改写时（钩子里现读的）动作不在抵消动作族，_OverheatTime 只在无限蓄力「该不该生效」变的那一帧和 Reset 时改，
--   set_Health 和 SKIP_ORIGINAL 只在锁血开着时、只对主玩家，探针零副作用，同一帧最多一个动作请求；引用记账同 v1.6；放刀日志只有
--   HDR / FIRE / RES / ERR / RED、字段按 4.2、HDR 懒写且至多一行、调试日志关着的时段没有 FIRE / RES、ERR 每次加载 ≤20 行；
--   不写 AutoParryGS_*.json、旧 AutoParryGS.json 一个字节不变、迁移时加载那一刻写回、存配置的键按 3.4；菜单只有一个树节点、
--   放刀一节的控件 ID、出过 ui 错后只剩状态行。由 v16 场景改写来的跑法，放刀的 ERR / RED 不按场景的声明查（和 A0 逐项比），
--   出现配置读写错误（ERR mod=cfg）判失败。
--
-- 断言（CONTRACT 第 5 节）：
--   1. 日志里没有 FMT_ERR；没有场景没声明的 ERR；脚本没有漏出未捕获的错误
--   2. rc 只在 [L_min, L] 区间的第一帧请求放刀（按 PLAN「DECISION RULE · A」用模拟器真值逐帧核对）
--   3. 否决生效（场景里确实出现过「没有否决就会放」的帧，而 rc 没放）
--   4. 探针 PT 结局互斥（每次进 (2,23) 恰好一行 PT、恰好一个结局，接住优先）
--   5. 写出的 JSON 能被严格解析，结构符合 CONTRACT 2 节，记录不重复
--   6. 引用记账（V16 第 8.2 节）：v1.6 和修过的探针一次都不手动 release；任何脚本 OVER_RELEASE = 0、
--      ADD_REF_PERMANENT = 0；DEAD_OBJECT = 0（负对照要求 ≥1）；Reset（丢弃脚本环境、强制回收）后 REF 的共享计数
--      全部归零、游戏已放手的对象全部销毁；持有时长按句柄回收时刻观测。rc1 / 冒烟场景用旧的按脚本计数模型：
--      会手动 release 的脚本 add_ref 与 release 成对
--   7. rc 只调用 changeActionRequest(0, (2,23), false) 这一个有副作用的方法，探针一个都不调
--   另外：日志字段顺序按 CONTRACT 3.4 / 4.2 的表，★ 记录不进日志，钩子不碰禁用的高频函数，imgui 栈平衡；
--   表外约定的辅助行（rc 的 DBG、探针的 STOP/RESUME）也必须是「[TAG] KIND k=v」；JSON 里 CT 的 k 改名 kn；
--   场景可另要求：空挥样本数、跟踪上限（同时持有对象数）、re.on_config_save 存下的配置、扫描收尾原因。
--   发布版另查（v1.5.1：V15 第 2~6、9 节；v1.6：V16 第 2.5、2.7、4、6 节；check_release）：HDR 的值（v1.6：ver=1.6、
--   rule=E5c、filter=g1、cfg_ver=3、c_lo=0.50、c_hi=2.00）；菜单每次真的改了启用开关或提前量就恰好一行 CFG；STAT 的字段
--   （v1.6 23 个，新字段默认取神谕）和场景预期一致、errors 和 JSON 里的 ERR 条数对得上（清零统计之后按增量）；
--   存配置只剩三个键加 cfg_ver（v1.6 = 3），要迁移的配置迁成 28 并写 DBG cfg_upgrade（只在调试日志开着时写，
--   from = 文件里的原值）；没有 HUD、没有 SCAN、FIRE 的 src 只有 V0；VETO 的 why（long / grab / sg）和 hs 按神谕逐行核对；
--   DBG 不刷屏；菜单文字和红色提示、状态行措辞；自停后释放全部引用、不再请求；rc 日志超过 5 行/秒判失败；只钩 receiveGameMessage。
--   v1.6 另查（check_v16_fire / check_v16_skip）：FIRE 的 C1/Cf/mf/nchg/dX/A0/Q0/Qp/Qe1/vq 按神谕逐个核对（另做 Q0、Qe1 的
--   一致性核对）、UVIEW 紧跟 FIRE、SKIP 按神谕逐条核对、RES 的 outcome（(2,25) = RECOIL）和 to。
--   两个版本都查：VETO 行和 STAT 的 vetoes 等于神谕的否决 streak 段数（每段一行）；why=idle 的 JSON 写出那一帧
--   主角不在 (2,21)~(2,29)、没有未结算的放刀；强制结算（Reset、自停）的 RES 的 dt。

local here = ((arg and arg[0]) or "run.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local mock = require("mock_ref")
local Sim = require("game_sim")
local SCENARIOS = require("scenarios")
local json = mock.json

local IS_WIN = package.config:sub(1, 1) == "\\"
local ROOT = here .. "/../.."

-- ---------- 命令行 ----------

local opts = { names = {}, out = here .. "/out", smoke = false, allow_missing = false, verbose = false,
    gc_every_frame = false }
do
    local i = 1
    while arg and i <= #arg do
        local a = arg[i]
        if a == "--smoke" then
            opts.smoke = true
        elseif a == "--merged" then
            opts.merged = true
        elseif a == "--merged-path" then
            i = i + 1
            opts.merged_path = arg[i]
            opts.merged = true
        elseif a == "--guard142" then
            i = i + 1
            opts.guard142 = arg[i]
        elseif a == "--rc" then
            i = i + 1
            opts.rc = arg[i]
        elseif a == "--rc1" then
            i = i + 1
            opts.rc1 = arg[i]
        elseif a == "--rc151" then
            i = i + 1
            opts.rc151 = arg[i]
        elseif a == "--probe101" then
            i = i + 1
            opts.probe101 = arg[i]
        elseif a == "--gc-every-frame" then
            opts.gc_every_frame = true
        elseif a == "--ref-model" then
            -- 开发用：强制所有场景用某个引用模型（real / legacy）
            i = i + 1
            opts.ref_model = arg[i]
        elseif a == "--default-ver" then
            -- 开发用：场景没写 rc_ver 时按哪个版本跑（例如 v15 + --rc151 指向 v1.5.1，核对 mock 自身的改动没破坏旧口径）
            i = i + 1
            opts.default_ver = arg[i]
        elseif a == "--probe" then
            i = i + 1
            opts.probe = arg[i]
        elseif a == "--out" then
            i = i + 1
            opts.out = arg[i]
        elseif a == "--allow-missing" then
            opts.allow_missing = true
        elseif a == "--verbose" or a == "-v" then
            opts.verbose = true
        elseif a == "--list" then
            opts.list = true
        elseif a:sub(1, 2) == "--" then
            io.stderr:write("未知选项 " .. a .. "\n")
            os.exit(2)
        else
            opts.names[#opts.names + 1] = a
        end
        i = i + 1
    end
end

if opts.list then
    for _, s in ipairs(SCENARIOS) do
        print(string.format("%-24s [%s] %s", s.name, s.merged_only and "merged" or (s.rc_ver or "v16"), s.desc or ""))
    end
    os.exit(0)
end

-- ---------- 文件系统 ----------

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function winpath(p) return '"' .. p:gsub("/", "\\") .. '"' end

local function mkdir_p(p)
    if IS_WIN then
        os.execute("mkdir " .. winpath(p) .. " >nul 2>nul")
    else
        os.execute("mkdir -p '" .. p .. "'")
    end
end

-- p 下的文件（不含子目录，不递归）。两个平台口径一致：Windows 的 dir /a-d 只列文件，Linux 用 find -type f
-- （原来的 ls -1 会把子目录也列出来，GitHub Actions 上 list_tree 把 lib/ 当文件读，实测）
local function list_dir(p)
    local cmd = IS_WIN and ("dir /b /a-d " .. winpath(p) .. " 2>nul")
        or ("find '" .. p .. "' -mindepth 1 -maxdepth 1 -type f -printf '%f\\n' 2>/dev/null")
    local h = io.popen(cmd)
    local out = {}
    if h then
        for line in h:lines() do
            line = line:gsub("\r$", "")
            if line ~= "" then out[#out + 1] = line end
        end
        h:close()
    end
    return out
end

local function list_subdirs(p)
    local cmd = IS_WIN and ("dir /b /ad " .. winpath(p) .. " 2>nul")
        or ("find '" .. p .. "' -mindepth 1 -maxdepth 1 -type d -printf '%f\\n' 2>/dev/null")
    local h = io.popen(cmd)
    local out = {}
    if h then
        for line in h:lines() do
            line = line:gsub("\r$", "")
            if line ~= "" then out[#out + 1] = line end
        end
        h:close()
    end
    return out
end

-- p 下全部文件（递归），返回相对 p 的路径（用 / 分隔），排好序
local function list_tree(p, prefix, out)
    out = out or {}
    prefix = prefix or ""
    for _, f in ipairs(list_dir(p)) do out[#out + 1] = prefix .. f end
    for _, d in ipairs(list_subdirs(p)) do list_tree(p .. "/" .. d, prefix .. d .. "/", out) end
    table.sort(out)
    return out
end

local function write_text(path, s)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local function read_text(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- ---------- 被测脚本 ----------

-- 归档的旧版本：先找 tools/archive/<名字>（V16 第 8.5 节的位置），没有再找 tools/mock/archive/<名字>
-- （本轮 mock 只许改 tools/mock 下的文件，负对照用的副本先放在这里）
local function archive_path(name)
    local a = ROOT .. "/tools/archive/" .. name
    if file_exists(a) then return a end
    return here .. "/archive/" .. name
end

-- 放刀模块的各版本用同一个脚本名 AutoParryGS（日志标签、配置文件、菜单操作的 script 都按这个名字），
-- 一个场景只载入其中一个。policy：no_release = 只 add_ref、不手动 release（v1.6、修过的探针，V16 第 5 节）；
-- manual = 会手动 release（归档版、冒烟脚本）
local PROBE_SCRIPTS, RC_SCRIPTS
local GUARD_SCRIPTS = {}
if opts.smoke then
    local smoke_probe = { name = "AutoParryCalib", tag = "APCal", path = opts.probe or (here .. "/smoke/AutoParryCalib.lua"),
        role = "probe", policy = "manual" }
    PROBE_SCRIPTS = { cur = smoke_probe, ["1.0.1"] = smoke_probe }
    local smoke_rc = { name = "AutoParryGS", tag = "AutoParryGS", path = opts.rc or (here .. "/smoke/AutoParryGS.lua"),
        role = "rc", ver = "rc1", policy = "manual" }
    RC_SCRIPTS = { v16 = smoke_rc, v15 = smoke_rc, rc1 = smoke_rc }
else
    PROBE_SCRIPTS = {
        cur = { name = "AutoParryCalib", tag = "APCal", path = opts.probe or (ROOT .. "/probes/AutoParryCalib.lua"),
            role = "probe", policy = "no_release" },
        ["1.0.1"] = { name = "AutoParryCalib", tag = "APCal",
            path = opts.probe101 or archive_path("AutoParryCalib_1.0.1.lua"), role = "probe", policy = "manual" },
    }
    RC_SCRIPTS = {
        -- 参照组 A0：归档的 v1.6（MERGE 第 6.1 节，md5 a83527d9…，和此前游戏 autorun 里的逐字节相同）
        v16 = { name = "AutoParryGS", tag = "AutoParryGS",
            path = opts.rc or archive_path("AutoParryGS_v1.6.lua"), role = "rc", ver = "v16",
            policy = "no_release" },
        -- 合并版（MERGE 第 6.2 节第 1 条）：脚本名 AutoGuardGS（菜单操作、故障、副作用按它归属），放刀记录的日志标签仍是
        -- [AutoParryGS]（tag / rec_tag），防御自己的行是 [AutoGuardGS]（guard_tag，不解析、不限速）
        merged = { name = "AutoGuardGS", tag = "AutoParryGS", rec_tag = "AutoParryGS", guard_tag = "AutoGuardGS",
            path = opts.merged_path or (ROOT .. "/build/AutoGuardGS/reframework/autorun/AutoGuardGS.lua"), role = "rc", guard = true,
            ver = "merged", policy = "no_release", json = false },
        v15 = { name = "AutoParryGS", tag = "AutoParryGS", path = opts.rc151 or archive_path("AutoParryGS_v151.lua"),
            role = "rc", ver = "v15", policy = "manual" },
        rc1 = { name = "AutoParryGS", tag = "AutoParryGS",
            path = opts.rc1 or (ROOT .. "/tools/archive/AutoParryGS_rc1.lua"), role = "rc", ver = "rc1",
            policy = "manual" },
    }
end
-- 防御场景的参照组 G-ref：归档的 v1.4.2 tools/archive/AutoGuardGS_v1.4.2.lua（MERGE 第 6.1 节，md5 85fedcc0…，和此前游戏
-- autorun 里的逐字节相同；回滚也用它），单独加载、不带放刀模块。src/ 里的 AutoGuardGS.lua 已经是合并版，git 里只有更早的 v1.3
if not opts.smoke then
    GUARD_SCRIPTS.v142 = { name = "AutoGuardGS", tag = "AutoGuardGS", guard_tag = "AutoGuardGS",
        path = opts.guard142 or archive_path("AutoGuardGS_v1.4.2.lua"), role = "guard", ver = "v142", policy = "no_release",
        json = false }
end
local PROBE_SCRIPT = PROBE_SCRIPTS.cur

-- 当前场景实际载入的脚本（run_scenario 开头按场景的 rc_ver / probe_ver 设置；各断言函数按它判断「有没有 rc / 探针」）
local present, HAS = {}, {}
local CUR_VER = "v16"       -- 当前场景按哪个版本的口径断言（--smoke 时一律 rc1）

-- ---------- CONTRACT 的记录字段表 ----------

local function split(s)
    local t = {}
    for w in s:gmatch("%S+") do t[#t + 1] = w end
    return t
end

-- 放刀模块的记录表按版本分：rc1 有 SCAN、STAT 只核对 CONTRACT 3.4 的 6 个必有字段（冒烟 rc 只写这 6 个）；
-- v15 删了 SCAN、加了 CFG（V15 第 4 节），STAT 保留 rc 的 12 个字段（fb 恒为 0）并追加 replica readerr，14 个字段全核对；
-- v1.5.1 的 VETO 在原字段后追加 why（long / grab，V15 第 9 节）
-- v1.6（V16 第 6.1 节）：旧字段的位置、名字、格式一个都不动，新字段只追加在后面；新增 UVIEW、SKIP
local V16_STAT_EXTRA = "recoils speedfail speedhold clockskip vetoq fclosed excl uview sidmis"
local function rc_kinds(ver)
    local k = {
        HDR = split("ver session auto_parry lead rotation scan L_min W_long H_veto credit"),
        FIRE = split("id t L R0 he0 src ent res em keep from"),
        FIRE_END = split("id t R1 n entered"),
        VETO = split("t hs he res ent em"),
        RES = split("id t outcome dt"),
        ERR = split("mod level msg"),
        RED = split("t mod why"),
    }
    if ver == "v15" or ver == "v16" then
        k.VETO = split("t hs he res ent em why")
        k.CFG = split("t auto_parry lead")
        k.STAT = split("fires catches vetoes fb failopen errors red yellow lua_ms_avg lua_ms_max hook_ms_ps readfail "
            .. "replica readerr")
    else
        k.SCAN = split("id t phase X t0 Dc t_req status reason")
        k.STAT = split("fires catches vetoes fb failopen errors")
    end
    if ver == "v16" then
        k.HDR = split("ver session auto_parry lead rotation scan L_min W_long H_veto credit rule filter cfg_ver c_lo c_hi")
        k.FIRE = split("id t L R0 he0 src ent res em keep from C1 Cf mf nchg dX A0 Q0 Qp Qe1 mode vq")
        k.RES = split("id t outcome dt to")
        for _, f in ipairs(split(V16_STAT_EXTRA)) do k.STAT[#k.STAT + 1] = f end
        k.UVIEW = split("id t hs he why em keep same res ent")
        k.SKIP = split("t why hs he Q em keep res ent")
    end
    return k
end
-- 合并版的放刀记录（MERGE 第 4.2 节）：只剩 HDR、FIRE、RES、ERR、RED。保留下来的字段格式和 v1.6 完全相同；
-- HDR 删 rotation / scan / cfg_ver、加 host / enum_skip，FIRE 删 src / Qp / Qe1 / mode / vq，RES 加 entered
local MERGED_KINDS = {
    HDR = split("ver session auto_parry lead L_min W_long H_veto credit rule filter c_lo c_hi host enum_skip"),
    FIRE = split("id t L R0 he0 ent res em keep from C1 Cf mf nchg dX A0 Q0"),
    RES = split("id t outcome dt to entered"),
    ERR = split("mod level msg"),
    RED = split("t mod why"),
}
local RC_KINDS_BY_VER = { rc1 = rc_kinds("rc1"), v15 = rc_kinds("v15"), v16 = rc_kinds("v16"), merged = MERGED_KINDS,
    v142 = rc_kinds("v16") }
local RC_KINDS = RC_KINDS_BY_VER.v16
local PROBE_KINDS = {
    HDR = split("ver session net guard_deg aim_deg overheat_parry cfg_guard cfg_parry enums"),
    SELFTEST = split("stage ok total failed"),
    HITCH = split("t f dt"), GAP = split("t f dt"),
    PERF = split("t fps maxdt hooks lua_ms_avg lua_ms_max tracked red yellow"),
    MSG = split("t f obj new tme em keep rt n mstart mend closest fin"),
    TYP = split("t f obj ent type hs he"),
    SER = split("t f obj ent type hs he charge"),
    ENT = split("obj ent idx closest shell reqset guard dmgtype dmglv filter vguard pbreak pfix pstock tgbreak block name"),
    ACT = split("t f from to from_name to_name raw_prev raw_new chara_new"),
    ARM = split("t f act sa ha nd raw"),
    PT = split("id t_obs raw0 t_start from hold lv contacts_blade contacts_body ph ps hit_t hit_idx recoil emhit dmg online_class"),
    CT = split("t f k atk atk_em dmgobj layer cls ps res act raw sa shell px py pz"),
    DMG = split("t total react"),
    PH = split("t state target raw chara delay"),
    PS = split("t state"), PMSG = split("t state"), EMPARRY = split("t em ap"),
    EMHIT = split("t raw chara dmgobj layer em"),
    EMSTATE = split("t em act"),
    EMINFO = split("t em when tgt speed_t speed_f ts master x y z"),
    ATK = split("t em a4 a5"),
    SIG = split("t name val raw chara frame"),
    ANIM = split("t raw frame speed motion"),
    HOLD = split("t n addrs"),
    POSE = split("t when px pz fx fz ex ez theta dist"),
    EP = split("id obj epoch em keep reason n_msg first_type first_hs types rate_med rate_min rate_max stall maxdt charge_all atk_on t0 t1"),
    PROG = split("t phase swings scan_pt b_pt b_contact b_danger"),
    ERR = split("mod level msg"),
    RED = split("t mod why"),
}
local KINDS_BY_TAG = { AutoParryGS = RC_KINDS, APCal = PROBE_KINDS }
local JSON_ONLY = { APCal = { SER = true, ANIM = true, HOLD = true } }
-- CONTRACT 记录表以外、部件之间约定好的辅助行：不要求在表里、离线也不解析，但「[TAG] KIND k=v」格式照样严格查
-- （不合格判失败）。rc 的 DBG = 配置 debug_log（CONTRACT 3.1）打开时的调试行；探针的 STOP / RESUME 标出
-- 「停止记录」的区间（探针头注释）。表外的其他种类仍只给警告。
local AUX_KINDS = { AutoParryGS = { DBG = true }, APCal = { STOP = true, RESUME = true } }
-- JSON 里改名存放的字段：CT 的「本帧第几次」k 和 JSON 记录的种类键 k 撞名，探针在 JSON 里存成 kn
-- （和 tools/apcal_analyze.py 的 FIELD_RENAME 一致；日志行里仍是 k=）
local JSON_RENAME = { APCal = { CT = { k = "kn" } } }
-- 布尔字段必须写成 1/0（CONTRACT 2 节）
local BOOL_FIELDS = {
    AutoParryGS = { FIRE_END = { "entered" }, HDR = { "auto_parry", "rotation", "scan" }, CFG = { "auto_parry" },
        FIRE = { "vq" }, UVIEW = { "same" }, RES = { "entered" } },
    APCal = { MSG = { "new", "tme", "fin" }, ARM = { "sa", "ha", "nd" }, SER = { "charge" } },
}

-- 允许的钩子（PLAN P04~P20 列出的低频函数）；onParryHitPreProcess 禁止（每秒 6~18 万次）
local ALLOWED_HOOKS = {}
for _, k in ipairs({
    "app.cMasterPlayerControllerEntity.receiveGameMessage(ace.cGameMessage)",
    "app.HunterCharacter.evHit_DamagePreProcess(app.HitInfo)",
    "app.HunterCharacter.evHit_ShellDamagePreProcess(app.HitInfo)",
    "app.HunterCharacter.evHit_Damage(app.HitInfo)",
    "app.cHunterWeaponHandlingBase.onParryHit(app.HunterDef.PARRY_STATE,via.GameObject,via.vec3)",
    "app.cHunterWeaponHandlingBase.onParrySuccess(app.HunterDef.PARRY_STATE)",
    "app.EnemyCharacter.evHit_DamagePreProcess(app.HitInfo)",
    "app.EnemyCharacter.evHit_AttackParry(app.HitInfo,app.cAttackParamEm)",
    "app.cEmModuleHit.onParryDamage(app.TARGET_ACCESS_KEY,System.Boolean,via.GameObject)",
    "app.ColliderSwitcher.activateAttack(System.Boolean,System.UInt32,System.UInt32,System.Nullable`1<System.Boolean>,"
        .. "app.Hit.HIT_ID_GROUP,System.Nullable`1<System.Single>,System.Nullable`1<System.Single>)",
    -- AutoGuardGS v1.4.2 的【测试】锁血（MERGE 第 6.2 节第 3 条）
    "app.cHunterHealth.requestDamage(app.HunterCharacter,System.Single,System.Single,System.Boolean,System.Boolean,"
        .. "System.Boolean,System.Boolean,System.Boolean,System.Boolean)",
    "app.cHunterHealth.requestRedDamage(System.Single)",
}) do ALLOWED_HOOKS[k] = true end

-- 合并版恰好钩这 5 个（防御 4 个 + 放刀 1 个，MERGE 第 1.6、6.2 节）；归档的 v1.4.2 钩前 4 个
local HK_MSG = "app.cMasterPlayerControllerEntity.receiveGameMessage(ace.cGameMessage)"
local HK_PRE = "app.HunterCharacter.evHit_DamagePreProcess(app.HitInfo)"
local HK_DMG = "app.HunterCharacter.evHit_Damage(app.HitInfo)"
local HK_REQ = "app.cHunterHealth.requestDamage(app.HunterCharacter,System.Single,System.Single,System.Boolean,"
    .. "System.Boolean,System.Boolean,System.Boolean,System.Boolean,System.Boolean)"
local HK_RED = "app.cHunterHealth.requestRedDamage(System.Single)"
local GUARD_HOOKS = { HK_PRE, HK_DMG, HK_REQ, HK_RED }
local MERGED_HOOKS = { HK_MSG, HK_PRE, HK_DMG, HK_REQ, HK_RED }

local ROTATION = { 20, 24, 28, 32, 36 }

-- ---------- 结果记录 ----------

local function new_result(sc)
    return { name = sc.name, fails = {}, warns = {}, infos = {} }
end
local function fail(R, msg) R.fails[#R.fails + 1] = msg end
local function warn(R, msg) R.warns[#R.warns + 1] = msg end
local function info(R, msg) R.infos[#R.infos + 1] = msg end

local function fmt_t(t) return string.format("%.4f", t) end

local function norm_act(s)
    if not s then return nil end
    local c, i = s:match("^%(?(%-?%d+)[,_](%-?%d+)%)?$")
    if c then return c .. "_" .. i end
    return s
end

-- ---------- 解析日志 ----------

local function parse_logs(w)
    local P = { list = {}, by = {}, unstructured = {}, fmt_err = {} }
    for _, l in ipairs(w.logs) do
        if l.text:find("FMT_ERR", 1, true) then P.fmt_err[#P.fmt_err + 1] = l end
        local tag, kind, rest = l.text:match("^%[([%w_]+)%] (%u[%u%d_]*)(.*)$")
        if tag and KINDS_BY_TAG[tag] then
            local f, order, bad = {}, {}, nil
            if rest ~= "" and rest:sub(1, 1) ~= " " then bad = rest end
            for tok in rest:gmatch("%S+") do
                local k, v = tok:match("^([%w_]+)=(.*)$")
                if k then
                    f[k] = v
                    order[#order + 1] = k
                else
                    bad = bad or tok
                end
            end
            local r = { tag = tag, kind = kind, f = f, order = order, bad = bad, t = l.t, frame = l.frame, text = l.text,
                phase = l.phase }
            P.list[#P.list + 1] = r
            P.by[tag] = P.by[tag] or {}
            P.by[tag][kind] = P.by[tag][kind] or {}
            local lst = P.by[tag][kind]
            lst[#lst + 1] = r
        else
            local t2 = l.text:match("^%[([%w_]+)%]")
            if t2 and KINDS_BY_TAG[t2] then P.unstructured[#P.unstructured + 1] = l end
        end
    end
    return P
end

local function lines(P, tag, kind)
    return (P.by[tag] and P.by[tag][kind]) or {}
end

local function num(v) return v and tonumber(v) or nil end

-- ---------- 断言：日志 ----------

local function check_logs(R, sc, w, P)
    for i, l in ipairs(P.fmt_err) do
        if i > 5 then break end
        fail(R, "日志里有 FMT_ERR（string.format 出错）: " .. l.text)
    end
    -- 记录格式：字段齐全、顺序一致、没有空格值、布尔写 1/0
    local seen_bad = {}
    local aux_n, aux_order = {}, {}
    for _, r in ipairs(P.list) do
        local spec = KINDS_BY_TAG[r.tag][r.kind]
        local aux = AUX_KINDS[r.tag] and AUX_KINDS[r.tag][r.kind]
        local key = r.tag .. " " .. r.kind
        if r.bad and not seen_bad[key .. "bad"] then
            seen_bad[key .. "bad"] = true
            local msg = string.format("[%s] %s 行有不是 k=v 的片段「%s」（值里有空格？）: %s", r.tag, r.kind, r.bad, r.text:sub(1, 160))
            -- CONTRACT 表里的记录离线要解析、约定的辅助行也要守同一格式，格式错是失败；其他表外行只提示
            if spec or aux then fail(R, msg) else warn(R, msg) end
        end
        if spec then
            local pos = 1
            local missing_f = {}
            local idx = {}
            for i, k in ipairs(r.order) do idx[k] = idx[k] or i end
            local last = 0
            local order_ok = true
            for _, k in ipairs(spec) do
                if not r.f[k] then
                    missing_f[#missing_f + 1] = k
                else
                    if idx[k] < last then order_ok = false end
                    last = idx[k]
                end
            end
            if #missing_f > 0 and not seen_bad[key .. "miss"] then
                seen_bad[key .. "miss"] = true
                fail(R, string.format("[%s] %s 缺字段 %s（CONTRACT 表）: %s", r.tag, r.kind, table.concat(missing_f, ","),
                    r.text:sub(1, 160)))
            end
            if not order_ok and not seen_bad[key .. "order"] then
                seen_bad[key .. "order"] = true
                fail(R, string.format("[%s] %s 字段顺序和 CONTRACT 表不一致: %s", r.tag, r.kind, r.text:sub(1, 160)))
            end
            local bools = BOOL_FIELDS[r.tag] and BOOL_FIELDS[r.tag][r.kind]
            for _, b in ipairs(bools or {}) do
                local v = r.f[b]
                if v and v ~= "0" and v ~= "1" and v ~= "-" and not seen_bad[key .. "bool" .. b] then
                    seen_bad[key .. "bool" .. b] = true
                    fail(R, string.format("[%s] %s 的 %s=%s，布尔要写 1/0", r.tag, r.kind, b, v))
                end
            end
            if r.f.t and not tonumber(r.f.t) and r.f.t ~= "-" and not seen_bad[key .. "t"] then
                seen_bad[key .. "t"] = true
                fail(R, string.format("[%s] %s 的 t=%s 不是数字", r.tag, r.kind, r.f.t))
            end
            if JSON_ONLY[r.tag] and JSON_ONLY[r.tag][r.kind] and not seen_bad[key .. "jsononly"] then
                seen_bad[key .. "jsononly"] = true
                fail(R, string.format("[%s] %s 是只进 JSON 的记录（★），不该打日志", r.tag, r.kind))
            end
        elseif aux then
            if not aux_n[key] then aux_order[#aux_order + 1] = key end
            aux_n[key] = (aux_n[key] or 0) + 1
        elseif not seen_bad[key .. "unknown"] then
            seen_bad[key .. "unknown"] = true
            warn(R, string.format("[%s] %s 不在 CONTRACT 记录表里（离线分析不会解析）", r.tag, r.kind))
        end
    end
    for _, key in ipairs(aux_order) do
        local tag, kind = key:match("^(%S+) (%S+)$")
        info(R, string.format("[%s] %s %d 行（约定的辅助行，不在 CONTRACT 表里，离线不解析）", tag, kind, aux_n[key]))
    end
    if #P.unstructured > 0 then
        warn(R, string.format("%d 行带标签但不是「[TAG] KIND k=v」格式，例如：%s", #P.unstructured, P.unstructured[1].text:sub(1, 120)))
    end
    -- 日志预算（CONTRACT 1：平均 ≤5 行/秒）。v1.5 的放刀模块只写关键事件（V15 第 3 节），超了判失败
    -- （例如每个否决帧都写 VETO）；探针和 rc1 的突发（34 条预告同时到）只提示
    local dur = math.max(1.0, w.t)
    for _, s in ipairs(present) do
        local n = 0
        for _, l in ipairs(w.logs) do if l.text:sub(1, #s.tag + 2) == "[" .. s.tag .. "]" then n = n + 1 end end
        local rate = n / dur
        info(R, string.format("%s 日志 %d 行，平均 %.2f 行/秒", s.tag, n, rate))
        if rate > 5.0 then
            local msg = string.format("%s 日志平均 %.2f 行/秒，超过预算 5 行/秒", s.tag, rate)
            if s.role == "rc" and (CUR_VER == "v15" or CUR_VER == "v16") then fail(R, msg) else warn(R, msg) end
        end
    end
    -- HDR
    for _, s in ipairs(present) do
        if #lines(P, s.tag, "HDR") == 0 then fail(R, s.tag .. " 加载时没有写 HDR 行") end
    end
    -- 引用记账修过的探针（V16 第 5.3 节）HDR 必须写 apcal-1.1 起的版本号：离线分析 1.4 按探针版本 ≥ apcal-1.1 判断 v1.6 的
    -- session 引用记账修没修，低于它整段判「需复核」（第 7 节第 4 条）。集成时抓到过实现写成 apcal-1.0.2 的情况
    for _, s in ipairs(present) do
        if s.role == "probe" and s.policy == "no_release" then
            local h = lines(P, s.tag, "HDR")[1]
            local ver = h and tostring(h.f.ver or "") or ""
            local a, b = ver:match("^apcal%-(%d+)%.(%d+)")
            a, b = tonumber(a), tonumber(b)
            if not a or a < 1 or (a == 1 and b < 1) then
                fail(R, "探针 HDR 的 ver=" .. ver .. "：引用记账修过的探针应为 apcal-1.1 起（V16 第 5.3 节；离线分析据此判断"
                    .. " B 阶段的数据要不要复核）")
            end
        end
    end
end

-- 场景声明的 ERR：{ tag, level, mod = 只算这个模块（可省）, min, max }。没声明到的 ERR 一律判失败；
-- 同一条 ERR 被多条声明覆盖时各自计数（例如 level 总数上限 + 某个模块恰好 1 条）
-- only_tags（合并模式里由 v16 场景改写来的跑法）：只查这些标签（探针）。放刀记录的 ERR / RED 由逐刀等价测试和 A0 比
-- （MERGE 第 6.3 节），场景按 v1.6 写的声明（条数含 json 模块、日志只写前 20 条的口径）不套用
local function check_err(R, sc, P, only_tags)
    local rows = {}
    local tags_seen = {}
    for _, s in ipairs(present) do
        if not tags_seen[s.tag] and (not only_tags or only_tags[s.tag]) then
            tags_seen[s.tag] = true
            for _, r in ipairs(lines(P, s.tag, "ERR")) do rows[#rows + 1] = { tag = s.tag, r = r } end
        end
    end
    local exp = {}
    for _, e in ipairs((sc.expect and sc.expect.err) or {}) do
        if not only_tags or only_tags[e.tag] then exp[#exp + 1] = e end
    end
    local covered = {}
    local function mod_ok(want, got)
        if want == nil then return true end
        if type(want) == "table" then
            for _, m in ipairs(want) do if m == got then return true end end
            return false
        end
        return want == got
    end
    for _, e in ipairs(exp) do
        if HAS[e.tag == "APCal" and "probe" or "rc"] then
            local n = 0
            for i, x in ipairs(rows) do
                if x.tag == e.tag and x.r.f.level == e.level and mod_ok(e.mod, x.r.f.mod) then
                    n = n + 1
                    covered[i] = true
                end
            end
            local what = e.level .. (e.mod and (" mod=" .. (type(e.mod) == "table" and table.concat(e.mod, "|") or e.mod)) or "")
            if e.min and n < e.min then
                fail(R, string.format("预期 [%s] 至少 %d 条 ERR level=%s，实际 %d 条", e.tag, e.min, what, n))
            end
            if e.max and n > e.max then
                fail(R, string.format("[%s] ERR level=%s 有 %d 条，超过上限 %d", e.tag, what, n, e.max))
            end
        end
    end
    local odd, odd_order = {}, {}
    for i, x in ipairs(rows) do
        if not covered[i] then
            local key = x.tag .. "|" .. tostring(x.r.f.level) .. "|" .. tostring(x.r.f.mod)
            if not odd[key] then
                odd[key] = { n = 0, ex = x.r.text, tag = x.tag, lv = x.r.f.level, mod = x.r.f.mod }
                odd_order[#odd_order + 1] = key
            end
            odd[key].n = odd[key].n + 1
        end
    end
    for _, key in ipairs(odd_order) do
        local o = odd[key]
        fail(R, string.format("意外的 ERR：[%s] level=%s mod=%s %d 条，例如 %s", o.tag, tostring(o.lv), tostring(o.mod), o.n,
            (o.ex or ""):sub(1, 200)))
    end
    -- RED（进入红状态，离线算关键错误）：只许在场景声明的脚本里出现，声明了就必须出现
    local want_red = {}
    for _, tag in ipairs((sc.expect and sc.expect.red) or {}) do want_red[tag] = true end
    for _, s in ipairs(present) do
        local n = (not only_tags or only_tags[s.tag]) and #lines(P, s.tag, "RED") or 0
        if (only_tags and not only_tags[s.tag]) or s.role == "guard" then
            -- 不查（见上）
        elseif n > 0 and not want_red[s.tag] then
            fail(R, string.format("意外的 RED（进入红状态）：[%s] %d 行，例如 %s", s.tag, n, lines(P, s.tag, "RED")[1].text:sub(1, 160)))
        elseif n == 0 and want_red[s.tag] then
            fail(R, string.format("预期 [%s] 进入红状态（RED 行），实际没有", s.tag))
        end
    end
    -- 场景要求的 RED 原因（例如帧逻辑连续出错：先 3in10s 标红，满 30 帧再写一行 why=self_stop）
    local red_why = (sc.expect and sc.expect.red_why) or {}
    for _, tag in ipairs({ "APCal", "AutoParryGS" }) do
        local whys = red_why[tag]
        if whys and HAS[tag == "APCal" and "probe" or "rc"] and (not only_tags or only_tags[tag]) then
            for _, why in ipairs(whys) do
                local found = false
                for _, r in ipairs(lines(P, tag, "RED")) do if r.f.why == why then found = true end end
                if not found then fail(R, string.format("预期 [%s] 有一行 RED why=%s，实际没有", tag, why)) end
            end
        end
    end
end

-- ---------- 断言：违规（未捕获错误、签名、对象、全局变量……） ----------

local VIOLATION_TEXT = {
    SCRIPT_ERROR = "未捕获的错误", SIG_MISMATCH = "方法签名和类型库不一致", DEAD_OBJECT = "访问已销毁的对象",
    OVER_RELEASE = "release 时 REF 的计数已经是 0 / 多于 add_ref", ADD_REF_PERMANENT = "用了 add_ref_permanent",
    FORCE_RELEASE = "用了 force_release", GLOBAL_READ = "读未定义的全局变量",
    GLOBAL_WRITE = "写全局变量", FORBIDDEN_HOOK = "钩了禁止的高频函数", JSON_REJECT = "json 写出被拒绝",
    IMGUI_UNBALANCED = "imgui 栈不平衡", BAD_HOOK = "sdk.hook 参数不对", LOG_BAD_ARG = "log 参数不是字符串",
    BAD_VALUETYPE = "ValueType.new 参数不对", FS_BAD_PATH = "fs 路径不合法",
}

local function check_violations(R, sc, w)
    local allow = {}
    for _, k in ipairs((sc.expect and sc.expect.allow_violations) or {}) do allow[k] = true end
    -- 负对照（V16 第 8.4 节第 40~42 条）：必须出现 DEAD_OBJECT，证明模型抓得到 2c 那类悬空指针
    local dead_req = sc.expect and sc.expect.dead_object == "required"
    if dead_req then allow.DEAD_OBJECT = true end
    local n_dead, ex_dead = 0, nil
    for _, v in ipairs(w.violations) do
        if v.kind == "DEAD_OBJECT" then
            n_dead = n_dead + v.count
            ex_dead = ex_dead or v
        end
        if not allow[v.kind] then
            fail(R, string.format("%s（%s）[%s] t=%.3f ×%d：%s", VIOLATION_TEXT[v.kind] or v.kind, v.kind, v.script,
                v.t, v.count, v.msg))
        end
    end
    if dead_req then
        if n_dead == 0 then
            fail(R, "负对照：要求出现 DEAD_OBJECT（访问已被游戏回收的对象），实际没有 —— 模型没抓到这类故障")
        else
            info(R, string.format("负对照：DEAD_OBJECT %d 次（预期），首次 [%s] t=%.3f：%s", n_dead, ex_dead.script, ex_dead.t,
                ex_dead.msg))
        end
    end
end

-- ---------- 断言：副作用 ----------

local function check_effects(R, w)
    local rc = HAS.rc and HAS.rc.name
    local probe = HAS.probe and HAS.probe.name
    local bad = {}
    for _, e in ipairs(w.effects) do
        local ok = false
        if rc and e.script == rc and e.kind == "call" and e.type == "app.HunterCharacter" and e.name == "changeActionRequest" then
            ok = true
        end
        if not ok then
            local key = e.script .. "|" .. e.kind .. "|" .. e.type .. "." .. e.name
            if not bad[key] then
                bad[key] = { e = e, n = 0 }
                bad[#bad + 1] = key
            end
            bad[key].n = bad[key].n + 1
        end
    end
    for _, key in ipairs(bad) do
        local b = bad[key]
        local e = b.e
        local who = (e.script == probe) and "探针" or ((e.script == rc) and "rc" or e.script)
        fail(R, string.format("%s 有副作用调用 %s %s.%s（%d 次，首次 t=%.3f %s 阶段，参数 %s）——rc 只许 changeActionRequest，探针一个都不许",
            who, e.kind, e.type, e.name, b.n, e.t, e.phase, table.concat(e.args or {}, ",")))
    end
    -- 请求本身：只在帧开头（pre-UpdateBehavior），参数必须是 (0, (2,23), false)
    local shown = 0
    for _, q in ipairs(w.requests) do
        local problem
        if q.script ~= rc then
            problem = "不是 rc 发的请求（" .. tostring(q.script) .. "）"
        elseif q.phase ~= "pre" then
            problem = "不在 pre-UpdateBehavior 里请求（阶段 " .. tostring(q.phase) .. "）"
        elseif q.layer ~= 0 or q.cat ~= 2 or q.idx ~= 23 or q.flag ~= false then
            problem = string.format("参数不对：layer=%s id=(%s,%s) flag=%s（必须是 0, (2,23), false）", tostring(q.layer),
                tostring(q.cat), tostring(q.idx), tostring(q.flag))
        elseif q.id_type ~= "ace.ACTION_ID" then
            problem = "ACTION_ID 类型不对：" .. tostring(q.id_type)
        end
        if problem then
            shown = shown + 1
            if shown <= 3 then fail(R, string.format("changeActionRequest t=%.3f：%s", q.t, problem)) end
        end
    end
end

-- ---------- 断言：引用记账（V16 第 8.2 节第 1、2、4、5 条） ----------

local function tag_of(script)
    for _, s in ipairs(present) do if s.name == script then return s.tag end end
    return tostring(script)
end

local function check_refs(R, w, sc, HO, G)
    local real = w.ref_model == "real"
    -- 1. 记账：v1.6 和修过的探针（policy = no_release）一次都不许 release / force_release；
    --    OVER_RELEASE / ADD_REF_PERMANENT / FORCE_RELEASE / DEAD_OBJECT 是违规，由 check_violations 判
    for _, s in ipairs(present) do
        local c = w.ref_counts[s.name] or {}
        local mr = c.MANUAL_RELEASE or 0
        if s.policy == "no_release" and mr > 0 then
            fail(R, string.format("%s 手动 release 了 %d 次（V16 第 5 节：持有方只 add_ref、不手动 release，丢弃时只删 Lua 引用，"
                .. "userdata 回收时 REF 自动 release）", s.tag, mr))
        end
        info(R, string.format("%s add_ref %d 次（其中 REF 已有引用、空操作 %d 次）、手动 release %d 次、同时持有预告结果峰值 %d（%s 模型）",
            s.tag, c.ADD_REF or 0, c.ADD_REF_NOOP or 0, mr, HO.peak[s.name] or 0, w.ref_model))
    end
    -- 场景要求某个脚本对某类对象至少 add_ref 几次：证明这一段真的走到了那条跨帧持有的路径（例如探针 findEnemy 不可用时
    -- 退路缓存的怪物对象 S.ems[*].ref，V16 第 5.3 节表的第二行），否则「没有手动 release」只是因为那段代码没跑
    for script, per in pairs((sc.expect and sc.expect.add_ref_min) or {}) do
        for tname, nmin in pairs(per) do
            local n = 0
            for _, e in ipairs(w.ref_events) do
                local st = w.rstates[e.addr]
                if e.s == script and e.d == 1 and st and st.tname == tname then n = n + 1 end
            end
            if n < nmin then
                fail(R, string.format("%s 对 %s 只 add_ref 了 %d 次，场景设计要求至少 %d 次（要测的持有路径没走到）", tag_of(script),
                    tname, n, nmin))
            else
                info(R, string.format("%s 对 %s add_ref %d 次（场景要求 ≥%d）", tag_of(script), tname, n, nmin))
            end
        end
    end
    if real then
        -- 2. 无泄漏：Reset（丢弃脚本环境、强制回收）之后 REF 的共享计数全部归零；游戏已放手的对象全部销毁
        local leak, live, ex_leak, ex_live = 0, 0, nil, nil
        for _, st in pairs(w.rstates) do
            if st.lua_count ~= 0 then
                leak = leak + 1
                ex_leak = ex_leak or st
            end
            if st.game_refs <= 0 and not st.scope and st.alive then
                live = live + 1
                ex_live = ex_live or st
            end
        end
        if leak > 0 then
            fail(R, string.format("Reset 后还有 %d 个地址 REF 的共享计数不是 0（例如 %s@%X lua_count=%d）", leak, ex_leak.tname,
                ex_leak.addr, ex_leak.lua_count))
        end
        if live > 0 then
            fail(R, string.format("Reset 后还有 %d 个游戏已放手的对象没有销毁（例如 %s@%X）：有引用没放干净", live, ex_live.tname,
                ex_live.addr))
        end
        -- 游戏放手时还被脚本的句柄保活的预告结果（V16 第 8.4 节第 39 条「一边先丢掉引用时对象仍由另一边的句柄保活」）
        local kept = 0
        for _, Rr in ipairs(G.results) do
            local st = rawget(Rr.obj, "__st")
            if Rr.dropped_t and st and (st.alive or (st.t_destroy and st.t_destroy > Rr.dropped_t + 1e-9)) then
                kept = kept + 1
            end
        end
        if kept > 0 then info(R, string.format("游戏放手时还被脚本句柄保活（之后才销毁）的预告结果 %d 个", kept)) end
        local want_kept = sc.expect and sc.expect.kept_alive_min
        if want_kept and kept < want_kept then
            fail(R, string.format("游戏放手时还被句柄保活的预告结果只有 %d 个，场景设计要求至少 %d 个（「一边先丢掉引用、另一边的句柄"
                .. "保活」这一段没走到）", kept, want_kept))
        end
        local n_destroy = 0
        for _, st in pairs(w.rstates) do if not st.alive then n_destroy = n_destroy + 1 end end
        info(R, string.format("对象状态 %d 个，场景结束时已销毁 %d 个；共享 userdata 回收时计数已是 0（手动 release 之后的正常现象）%d 次",
            (function() local n = 0 for _ in pairs(w.rstates) do n = n + 1 end return n end)(), n_destroy, w.gc_unmanaged))
    else
        -- legacy（rc1 / 冒烟）：会手动 release 的脚本 add_ref 与 release 成对（场景结束 reset 后计数归零）；
        -- 不手动 release 的脚本（修过的探针）不配对，上面已查过一次都没 release
        local policy = {}
        for _, s in ipairs(present) do policy[s.name] = s.policy end
        local by_type = {}
        for addr, per in pairs(w.refs) do
            for script, n in pairs(per) do
                if n ~= 0 and policy[script] ~= "no_release" then
                    local o = w.ref_objs[addr]
                    local tn = o and rawget(o, "__t").name or "?"
                    local key = script .. "|" .. tn .. "|" .. (n > 0 and "leak" or "over")
                    by_type[key] = (by_type[key] or 0) + math.abs(n)
                end
            end
        end
        local keys = {}
        for k in pairs(by_type) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local script, tn, what = k:match("^(.-)|(.-)|(.*)$")
            if what == "leak" then
                fail(R, string.format("%s 场景结束 reset 后还有 %d 个 add_ref 没 release（%s；legacy 模型按脚本配对）", script,
                    by_type[k], tn))
            else
                fail(R, string.format("%s 对 %s 多 release 了 %d 次", script, tn, by_type[k]))
            end
        end
    end
    -- 4. 同时持有峰值：按脚本数活着的 app.AttackAreaResult 句柄。场景让打我的预告多于跟踪上限时，峰值必须恰好等于上限
    --    （多了 = 没先丢最旧的，少了 = 上限被改小）
    local cap = sc.expect and sc.expect.max_held
    for _, s in ipairs(present) do
        local pk = HO.peak[s.name] or 0
        if cap and pk ~= cap then
            fail(R, string.format("%s 同时持有预告结果峰值 %d 个，跟踪上限应为 %d（场景的预告数超过上限，峰值必须顶到上限、不能超过）",
                s.tag, pk, cap))
        elseif not cap and pk > 40 then
            warn(R, string.format("%s 同时持有 %d 个预告结果，超过跟踪上限 32 太多", s.tag, pk))
        end
    end
    -- 5. 共享持有（只报告）
    local n_sh = 0
    for _ in pairs(HO.shared_addrs) do n_sh = n_sh + 1 end
    if n_sh > 0 then
        info(R, string.format("两个脚本同时持有同一个预告结果的句柄：共 %d 个对象，同一时刻最多 %d 个（REF 按地址共用一份计数，"
            .. "谁都不手动 release 才安全）", n_sh, HO.shared_max))
    end
    if (w.ref_shared or 0) > 0 then
        info(R, string.format("legacy 模型：两个脚本同时持有同一对象的 add_ref %d 次", w.ref_shared))
    end
end

-- ---------- 持有观测（V16 第 8.2 节第 3 条：持有时长按句柄回收时刻观测） ----------
-- 规则不变：IsAttackFinished 之后 ≤ 1.5 s、距消息 ≤ 9.5 s、主角消失 / 换人 / 关开关 / 自停 / 探针停止记录后 ≤ 0.5 s
-- （再加一帧回收粒度）。观测方式：句柄（每个脚本、每个地址、每一代一个）被回收的时刻 = 脚本丢掉引用的时刻。
-- 和规格的写法差一点：规格是「每帧末 collectgarbage 两次」，实测要慢 10~30 倍（rotation 2.9 s → 99 s）。这里在
-- 真正需要观测的帧末才回收：① 到了某条规则的期限（消息 + 9.5 s、结束 + 1.5 s、释放点 + 0.5 s、held_at 时刻）；
-- ② 本帧新建了预告结果的句柄（同时持有峰值只可能在这时变大）；③ 每 0.5 s 一次兜底。到期限那一帧回收之后句柄还活着
-- = 脚本在期限那一刻还引用着它 —— 和逐帧回收的判定一模一样（结论不依赖回收的频率）；--gc-every-frame 可切回逐帧回收核对。
-- GC 在场景运行期间是停着的（collectgarbage("stop")），回收时刻完全由这里决定，结果可复现。

local HOLD_FIN, HOLD_STALE, HOLD_RP, GC_PERIOD = 1.5, 9.5, 0.5, 0.5

local function new_holds(w, G, sc)
    local HO = { w = w, G = G, sc = sc, dl = {}, peak = {}, shared_max = 0, shared_addrs = {}, held = {},
        problems = {}, shown = {}, msg_i = {}, fin_i = {}, hev_i = 0, log_i = 1, next_gc = 0.0, gc_n = 0 }
    return HO
end

local function ho_schedule(HO, t, d)
    d.t = t
    local list = HO.dl
    local i = #list
    while i >= 1 and list[i].t > t do i = i - 1 end
    table.insert(list, i + 1, d)
end

local function ho_problem(HO, kind, msg)
    HO.shown[kind] = (HO.shown[kind] or 0) + 1
    if HO.shown[kind] == 1 then HO.problems[#HO.problems + 1] = { kind = kind, msg = msg } end
end

-- 释放点：主角消失 / 换人（两个脚本），场景声明的（关开关只对 rc、停止记录只对探针），rc 自停（RED why=self_stop）
local function ho_release_point(HO, t, what, script)
    ho_schedule(HO, t + HOLD_RP, { kind = "rp", ref = t, what = what, script = script })
end

local function ho_init(HO)
    for _, rp in ipairs((HO.sc.expect and HO.sc.expect.release_all_at) or {}) do
        ho_release_point(HO, rp.t, rp.what or "关开关", rp.script)
    end
    for _, h in ipairs((HO.sc.expect and HO.sc.expect.held_at) or {}) do
        ho_schedule(HO, h.t, { kind = "held_at", em = h.em, want = h.held })
    end
end

local function ho_scan(HO)
    local w, G = HO.w, HO.G
    for _, Rr in ipairs(G.results) do
        local i = HO.msg_i[Rr] or 0
        for k = i + 1, #Rr.msg_times do
            ho_schedule(HO, Rr.msg_times[k] + HOLD_STALE, { kind = "stale", R = Rr, t_msg = Rr.msg_times[k] })
        end
        HO.msg_i[Rr] = #Rr.msg_times
        local j = HO.fin_i[Rr] or 1     -- fin_changes[1] 是建对象时的初值，不是一次结束
        for k = j + 1, #Rr.fin_changes do
            local ch = Rr.fin_changes[k]
            if ch.fin then ho_schedule(HO, ch.t + HOLD_FIN, { kind = "fin", R = Rr, ifin = k, ref = ch.t }) end
        end
        HO.fin_i[Rr] = #Rr.fin_changes
    end
    local hev = G.truth.hunter_events or {}
    for k = HO.hev_i + 1, #hev do
        ho_release_point(HO, hev[k].t, hev[k].op == "swap" and "主角换人" or "主角消失", nil)
    end
    HO.hev_i = #hev
    -- rc 帧逻辑自停（V15 第 2 节「自停并释放全部引用」）：RED why=self_stop 那一刻
    for k = HO.log_i, #w.logs do
        local text = w.logs[k].text
        if text:sub(1, 18) == "[AutoParryGS] RED " and text:find("why=self_stop", 1, true) then
            local t = tonumber(text:match(" t=([%d%.]+)"))
            if t then
                HO.rc_stop = HO.rc_stop or (t - w.clock_base)
                -- 合并版的放刀记录标签仍是 [AutoParryGS]，持有方是 AutoGuardGS 这个脚本
                ho_release_point(HO, t - w.clock_base, "帧逻辑自停", HAS.rc and HAS.rc.name or "AutoParryGS")
            end
        end
    end
    HO.log_i = #w.logs + 1
end

local function ho_count(HO)
    local w = HO.w
    local per = {}
    for addr, list in pairs(w.hrecs) do
        local who, n = {}, 0
        for _, rec in ipairs(list) do
            if not rec.t_gc then
                per[rec.script] = (per[rec.script] or 0) + 1
                if not who[rec.script] then
                    who[rec.script] = true
                    n = n + 1
                end
            end
        end
        if n >= 2 then HO.shared_addrs[addr] = true end
    end
    local sh = 0
    for addr in pairs(HO.shared_addrs) do
        local who = {}
        for _, rec in ipairs(w.hrecs[addr] or {}) do if not rec.t_gc then who[rec.script] = true end end
        local n = 0
        for _ in pairs(who) do n = n + 1 end
        if n >= 2 then sh = sh + 1 end
    end
    if sh > HO.shared_max then HO.shared_max = sh end
    for s, n in pairs(per) do
        if n > (HO.peak[s] or 0) then HO.peak[s] = n end
    end
end

local function ho_check(HO, d)
    local w, G = HO.w, HO.G
    if d.kind == "stale" then
        local Rr = d.R
        local last = Rr.msg_times[#Rr.msg_times]
        if last and last > d.t_msg + 1e-9 then return end      -- 之后又来过消息：另有更晚的期限
        for _, rec in ipairs(w.hrecs[Rr.obj:get_address()] or {}) do
            if not rec.t_gc then
                ho_problem(HO, rec.script .. "stale", string.format("%s 持有预告结果 @%X 到 t=%.2f，距最后一条消息已 %.1f s"
                    .. "（规则：距 t_msg ≥8 s 就释放）", tag_of(rec.script), rec.addr, w.t, w.t - d.t_msg))
            end
        end
    elseif d.kind == "fin" then
        local Rr = d.R
        if #Rr.fin_changes ~= d.ifin then return end           -- 之后又变回没结束（复用结果的旧场景）
        for _, rec in ipairs(w.hrecs[Rr.obj:get_address()] or {}) do
            if not rec.t_gc and (not d.only or d.only == rec) then
                if rec.t_push <= d.ref + 1e-9 then
                    ho_problem(HO, rec.script .. "fin", string.format("%s 在预告结果 @%X 已 IsAttackFinished（t=%.2f）之后又持有到 t=%.2f"
                        .. "（规则：结束就释放，≤1.5 s）", tag_of(rec.script), rec.addr, d.ref, w.t))
                else
                    -- 结束之后又拿到过（重新推入）：从那一刻起再算 1.5 s
                    ho_schedule(HO, rec.t_push + HOLD_FIN, { kind = "fin", R = Rr, ifin = d.ifin, ref = rec.t_push, only = rec })
                end
            end
        end
    elseif d.kind == "rp" then
        for _, list in pairs(w.hrecs) do
            for _, rec in ipairs(list) do
                if not rec.t_gc and (not d.script or d.script == rec.script) and rec.t_push < d.ref - 1e-9 then
                    ho_problem(HO, rec.script .. "rp", string.format("%s 在%s（t=%.2f）之后还持有预告结果 @%X 到 t=%.2f"
                        .. "（规则：主角为 nil、换人、关开关、自停、停止记录时全部释放）", tag_of(rec.script), d.what, d.ref, rec.addr, w.t))
                end
            end
        end
    elseif d.kind == "held_at" then
        local M = G.monsters[d.em]
        local Rr = M and M.results and M.results.me
        local addr = Rr and Rr.obj:get_address()
        for _, s in ipairs(present) do
            local held = false
            for _, rec in ipairs((addr and w.hrecs[addr]) or {}) do
                if rec.script == s.name and not rec.t_gc then held = true end
            end
            HO.held[#HO.held + 1] = { t = d.t, em = d.em, tag = s.tag, held = held, want = d.want, ok = Rr ~= nil }
        end
    end
end

-- 每帧末调用：排期限、按需回收、核对到期的期限
local function ho_frame_end(HO, force)
    local w = HO.w
    ho_scan(HO)
    local due = HO.dl[1] ~= nil and HO.dl[1].t <= w.t + 1e-9
    if force or w.gc_due or due or w.t >= HO.next_gc then
        w:gc_now()
        HO.gc_n = HO.gc_n + 1
        HO.next_gc = w.t + GC_PERIOD
        ho_count(HO)
        while HO.dl[1] and HO.dl[1].t <= w.t + 1e-9 do ho_check(HO, table.remove(HO.dl, 1)) end
    end
end

local function check_holds(R, w, G, sc, P, HO)
    for _, p in ipairs(HO.problems) do fail(R, p.msg) end
    for kind, n in pairs(HO.shown) do
        if n > 1 then fail(R, string.format("……同类持有问题（%s）共 %d 处", kind, n)) end
    end
    for _, h in ipairs(HO.held) do
        if not h.ok then
            fail(R, "held_at：没有怪物 " .. tostring(h.em) .. " 的结果对象")
        elseif h.held ~= h.want then
            fail(R, string.format("t=%.2f 时 %s %s持有 %s 的结果对象（预期%s持有；跟踪满了丢 t_msg 最旧的）", h.t, h.tag,
                h.held and "" or "没", h.em, h.want and "" or "不"))
        end
    end
    info(R, string.format("持有观测：回收 %d 次（%s）", HO.gc_n, opts.gc_every_frame and "逐帧" or "按期限 + 新建句柄 + 每 0.5 s"))
    -- 自停后不再登记新的预告（消息钩子第一行就返回），也不再请求放刀
    local ts = HO.rc_stop
    if ts and HAS.rc then
        for _, e in ipairs(w.ref_events) do
            if e.s == HAS.rc.name and e.d > 0 and e.t > ts + 1e-6 then
                fail(R, string.format("rc 在 t=%.2f 自停之后，t=%.2f 又 add_ref 了对象", ts, e.t))
                break
            end
        end
        for _, q in ipairs(w.requests) do
            if q.script == HAS.rc.name and q.t > ts + 1e-6 and q.cat == 2 and (q.idx == 23 or q.idx == 24) then
                fail(R, string.format("rc 在 t=%.2f 自停之后，t=%.3f 还在请求放刀", ts, q.t))
                break
            end
        end
    end
end

-- ---------- 断言：钩子 ----------

local function check_hooks(R, w)
    local seen = {}
    for _, h in ipairs(w.hook_regs) do
        local key = h.script .. "|" .. h.key
        if not seen[key] then
            seen[key] = true
            if not ALLOWED_HOOKS[h.key] then
                warn(R, string.format("%s 钩了 PLAN 没列出的函数 %s（频率未知，确认有自停守卫）", h.script, h.key))
            end
        end
    end
end

-- ---------- 断言：JSON ----------

local function check_json(R, sc, w, P)
    local per_prefix = {}
    local rec_seen = {}
    local files = {}
    for _, rel in ipairs(w.file_order) do files[#files + 1] = rel end
    table.sort(files)
    local all_records = { AutoParryGS = {}, APCal = {} }
    for _, rel in ipairs(files) do
        local s = w:read_file(rel)
        -- 场景故意写坏的种子文件（config_raw，MERGE 第 3.5 节第 7 条「旧文件不是 JSON」）不按 JSON 查
        if rel:match("%.json$") and not (R.raw_seed and R.raw_seed[rel]) then
            local v, err = json.decode(s or "", { keep_null = true })
            if v == nil then
                fail(R, "JSON 解析失败 " .. rel .. "：" .. tostring(err))
            else
                local prefix, session, seq = rel:match("^(%a+)_(%d+)_(%d+)%.json$")
                if prefix == "APCal" or prefix == "AutoParryGS" then
                    if type(v) ~= "table" or type(v.records) ~= "table" then
                        fail(R, rel .. " 结构不对：缺 records 数组")
                    else
                        if v.kind ~= prefix then fail(R, rel .. " 的 kind=" .. tostring(v.kind) .. "，应为 " .. prefix) end
                        if tonumber(v.session) ~= tonumber(session) then
                            fail(R, rel .. " 的 session 和文件名不一致")
                        end
                        if tonumber(v.seq) ~= tonumber(seq) then fail(R, rel .. " 的 seq 和文件名不一致") end
                        if v.ver == nil then fail(R, rel .. " 缺 ver") end
                        per_prefix[prefix] = per_prefix[prefix] or {}
                        local pp = per_prefix[prefix]
                        pp[#pp + 1] = { seq = tonumber(seq), session = tonumber(session), rel = rel, n = #v.records,
                            why = v.why }
                        local bad_k = 0
                        for _, r in ipairs(v.records) do
                            if type(r) ~= "table" or type(r.k) ~= "string" then
                                bad_k = bad_k + 1
                                if bad_k == 1 then
                                    fail(R, string.format("%s 有记录的 k 不是记录种类字符串（k=%s；CT 的「本帧第几次」字段 k 和 JSON 的种类键 k 撞名，JSON 里要改名，探针用 kn）",
                                        rel, tostring(type(r) == "table" and r.k)))
                                end
                                goto next_record
                            end
                            all_records[prefix][#all_records[prefix] + 1] = r
                            if r.t ~= nil and r.t ~= json.null then
                                local canon = json.encode(r) or ""
                                if rec_seen[canon] and rec_seen[canon] ~= rel then
                                    fail(R, string.format("同一条记录写进了两个文件（%s 和 %s）：%s", rec_seen[canon], rel, canon:sub(1, 120)))
                                end
                                rec_seen[canon] = rel
                            end
                            ::next_record::
                        end
                    end
                end
            end
        end
    end
    for prefix, list in pairs(per_prefix) do
        table.sort(list, function(a, b) return a.seq < b.seq end)
        for i, f in ipairs(list) do
            if f.seq ~= i then
                fail(R, string.format("%s 的序号不连续：第 %d 个文件 seq=%d", prefix, i, f.seq))
                break
            end
        end
        -- 场景要求的写出时机序列（why = button / idle / reset，CONTRACT 2 节；离线据最后一份判断有没有正常收尾）
        local want_why = sc.expect and sc.expect.json_why and sc.expect.json_why[prefix]
        local holder = HAS[prefix == "APCal" and "probe" or "rc"]
        if want_why and holder and holder.json ~= false then
            local got = {}
            for _, f in ipairs(list) do got[#got + 1] = tostring(f.why) end
            if table.concat(got, ",") ~= table.concat(want_why, ",") then
                fail(R, string.format("%s 的 JSON 写出时机（why）依次是 %s，预期 %s", prefix, table.concat(got, ","),
                    table.concat(want_why, ",")))
            end
        end
        local tag = prefix
        local hdr = lines(P, tag, "HDR")[1]
        if hdr and hdr.f.session and tonumber(hdr.f.session) ~= list[1].session then
            fail(R, string.format("%s 的 JSON session=%d 和 HDR 的 session=%s 不一致", prefix, list[1].session, hdr.f.session))
        end
        info(R, string.format("%s 写出 %d 个 JSON 文件，共 %d 条记录", prefix, #list, #all_records[prefix]))
    end
    for _, s in ipairs(present) do
        if s.json ~= false and not per_prefix[s.tag] then
            fail(R, s.tag .. " 场景结束（re.on_script_reset）后没有写出任何 JSON 数据文件")
        end
    end
    -- JSON 里某种记录的某个字段一次都没出现过：多半是字段名写错或漏写（值为 nil 的字段在 JSON 里会被省略，
    -- 所以只在「从来没出现过」时才提示）
    for prefix, recs in pairs(all_records) do
        local kinds = KINDS_BY_TAG[prefix]
        local present_f, nkind = {}, {}
        for _, r in ipairs(recs) do
            nkind[r.k] = (nkind[r.k] or 0) + 1
            present_f[r.k] = present_f[r.k] or {}
            for k in pairs(r) do present_f[r.k][k] = true end
        end
        local ks = {}
        for k in pairs(nkind) do ks[#ks + 1] = k end
        table.sort(ks)
        for _, k in ipairs(ks) do
            local spec = kinds[k]
            if spec then
                local miss = {}
                local ren = JSON_RENAME[prefix] and JSON_RENAME[prefix][k] or {}
                for _, fld in ipairs(spec) do
                    -- JSON 里 k 是记录种类；CT 的字段 k（本帧第几次）在 JSON 里改名存放（JSON_RENAME：kn），按新名字查
                    local jf = ren[fld] or fld
                    if jf ~= "k" and not present_f[k][jf] then miss[#miss + 1] = jf end
                end
                if #miss > 0 then
                    warn(R, string.format("%s 的 JSON 里 %d 条 %s 记录都没有字段 %s（离线分析优先读 JSON）", prefix, nkind[k], k,
                        table.concat(miss, ",")))
                end
            end
        end
    end
    -- 场景注入的写盘失败（mock 的 json.dump_file 故障，injected）：次数必须等于场景声明的 expect.json_fail[标签]；
    -- Reset 时那一份写失败的话，Reset 时才产生的记录只在日志里（下面的「日志有的 JSON 也要有」不算它们）
    local exp = sc.expect or {}
    local injected, reset_lost = {}, {}
    for _, j in ipairs(w.json_writes) do
        if j.injected then
            local s = HAS.rc and j.script == HAS.rc.name and "AutoParryGS" or "APCal"
            injected[s] = (injected[s] or 0) + 1
            if j.phase == "reset" then reset_lost[s] = true end
        end
    end
    for _, s in ipairs(present) do
        local want = s.json ~= false and ((exp.json_fail or {})[s.tag] or 0) or 0
        if s.json ~= false and (injected[s.tag] or 0) ~= want then
            fail(R, string.format("%s 的 JSON 注入写盘失败 %d 次，场景预期 %d 次", s.tag, injected[s.tag] or 0, want))
        end
    end
    -- 日志里出现过的核心记录，JSON 里也要有（日志会被覆盖，离线优先读 JSON）
    -- CFG：第 2 轮验收按第一次改动截断（PLAN D），离线优先读 JSON，日志里有的 JSON 里必须也有
    local core = { AutoParryGS = { "HDR", "FIRE", "FIRE_END", "RES", "VETO", "SCAN", "CFG", "STAT", "RED", "UVIEW", "SKIP" },
        APCal = { "PT", "CT", "ACT", "MSG", "EP", "DMG" } }
    for tag, kinds in pairs(core) do
        if per_prefix[tag] then
            local cnt = {}
            for _, r in ipairs(all_records[tag]) do cnt[r.k] = (cnt[r.k] or 0) + 1 end
            for _, k in ipairs(kinds) do
                local nlog = 0
                for _, r in ipairs(lines(P, tag, k)) do
                    if not (reset_lost[tag] and r.phase == "reset") then nlog = nlog + 1 end
                end
                if (cnt[k] or 0) < nlog then
                    fail(R, string.format("%s 的 %s：日志 %d 行，JSON 只有 %d 条", tag, k, nlog, cnt[k] or 0))
                end
            end
        end
    end
    local wr = 0
    for _, j in ipairs(w.json_writes) do if not j.ok and not j.injected then wr = wr + 1 end end
    if wr > 0 then fail(R, string.format("json.dump_file 返回 false %d 次", wr)) end
    if exp.json_files_min then
        -- 数字 = 两个脚本都要求；表 = 按标签分别要求（例如 { APCal = 2 }：探针「停止记录」时也写一次）
        for _, s in ipairs(present) do
            local want = exp.json_files_min
            if type(want) == "table" then want = want[s.tag] end
            if s.json == false then want = nil end
            local n = per_prefix[s.tag] and #per_prefix[s.tag] or 0
            if want and n < want then
                fail(R, string.format("%s 只写出 %d 个 JSON 文件，预期至少 %d 个（菜单按钮 + 空闲 ≥60 s + 停止记录 + reset）",
                    s.tag, n, want))
            end
        end
    end
    return all_records
end

-- JSON 只在空闲帧写（CONTRACT 2 写出时机①，V15 第 2 节「写出时机不变」）：几 MB 的 JSON 会卡 0.1~0.3 s，不能压在
-- 判定时机上。rc 每次 why=idle 的写出，那一帧主角不在 (2,21)~(2,29)（神谕记的这一帧开头的动作），也不在某次放刀的
-- FIRE 和它的 RES 之间。自停之后 rc 不再读主角（V15 第 2 节），写出不看动作，不核对
local function check_json_idle(R, w, G, P)
    if not HAS.rc then return end
    local rc = HAS.rc.name
    local res_t, busy = {}, {}
    for _, r in ipairs(lines(P, "AutoParryGS", "RES")) do res_t[r.f.id or "?"] = num(r.f.t) end
    for _, f in ipairs(lines(P, "AutoParryGS", "FIRE")) do
        local t0 = num(f.f.t)
        if t0 then busy[#busy + 1] = { t0, res_t[f.f.id or "?"] or math.huge, f.f.id } end
    end
    local t_stop = math.huge
    for _, r in ipairs(lines(P, "AutoParryGS", "RED")) do
        if r.f.why == "self_stop" and num(r.f.t) then t_stop = math.min(t_stop, num(r.f.t)) end
    end
    local n = 0
    for _, j in ipairs(w.json_writes) do
        if j.script == rc and j.ok and j.path:match("^AutoParryGS_%d+_%d+%.json$") then
            local s = w:read_file(j.path)
            local v = s and json.decode(s)
            local tc = w.clock_base + j.t
            if type(v) == "table" and v.why == "idle" and tc < t_stop then
                n = n + 1
                local o = G.oracle[j.frame]
                if o and o.cat == 2 and o.idx and o.idx >= 21 and o.idx <= 29 then
                    fail(R, string.format("rc 在 t=%.3f 空闲写出 %s，可那一帧主角在 (2,%d)（只许在空闲帧写：不在 (2,21)~(2,29)）",
                        j.t, j.path, o.idx))
                end
                for _, b in ipairs(busy) do
                    if tc >= b[1] and tc < b[2] then
                        fail(R, string.format("rc 在 t=%.3f 空闲写出 %s，可放刀 id=%s 还没结算（FIRE 之后、RES 之前）", j.t, j.path,
                            tostring(b[3])))
                        break
                    end
                end
            end
        end
    end
    if n > 0 then info(R, string.format("rc 空闲写出 JSON %d 次，都在空闲帧", n)) end
end

-- ---------- 断言：rc 放刀时机（神谕） ----------

local function request_frames(w, rc_name)
    local by = {}
    for _, q in ipairs(w.requests) do
        if q.script == rc_name then
            by[q.frame] = by[q.frame] or {}
            local l = by[q.frame]
            l[#l + 1] = q
        end
    end
    return by
end

local function oracle_desc(w, o)
    if not o then return "无记录" end
    return string.format("t=%s 蓄力=%s 否决=%s Q*=%s L=%s", fmt_t(w.clock_base + o.t), tostring(o.charging), tostring(o.veto),
        o.q and string.format("%.2f", o.q) or "-", tostring(o.L))
end

-- 菜单「清零统计」被 rc 处理的时刻（模拟时间；没点过返回 nil）：STAT 的计数从这之后重新累计
local function rc_clear_time(w, rc_name)
    local t
    for _, a in ipairs(w.ui_actions) do
        local d = a.kind == "button" and a.match and a.match:find("清零", 1, true) and a.done and a.done[rc_name]
        if d and (not t or d > t) then t = d end
    end
    return t
end

-- 神谕：每帧的 L 用这一帧开头 rc 在用的提前量（o.L：加载时的配置，菜单滑块改动从下一帧起生效），
-- L_min 按版本（G.L_MIN：v15 22，rc1 18）
local function check_rc_oracle(R, sc, w, G, P, rc_name, mode)
    local reqs = request_frames(w, rc_name)
    local until_t = sc.oracle_until
    local exp = sc.expect or {}
    local miss, extra = {}, {}
    local veto_frames = 0
    local fire_by_t = {}
    for _, r in ipairs(lines(P, "AutoParryGS", "FIRE")) do
        local t = num(r.f.t)
        if t then fire_by_t[#fire_by_t + 1] = { t = t, L = num(r.f.L), r = r } end
    end
    -- 把连续请求帧合成 streak，找对应的 FIRE（rotation 时用它的 L）
    local streak_L = {}
    local prev_req = false
    local cur_L
    for frame = 1, w.frame do
        local has = reqs[frame] ~= nil
        if has and not prev_req then
            cur_L = nil
            local tq = w.clock_base + G.oracle[frame].t
            for _, f in ipairs(fire_by_t) do
                if math.abs(f.t - tq) < 0.003 then
                    cur_L = f.L
                    break
                end
            end
            if mode == "oracle_rotation" and not cur_L then
                fail(R, string.format("t=%s 的请求找不到同一帧的 FIRE 行（streak 第一帧必须写 FIRE）", fmt_t(tq)))
            end
        end
        if has then streak_L[frame] = cur_L end
        prev_req = has
    end
    local function skipped(t)
        if until_t and t >= until_t then return true end
        for _, wd in ipairs(sc.oracle_skip or {}) do
            if t >= wd[1] and t < wd[2] then return true end
        end
        return false
    end
    for frame = 1, w.frame do
        local o = G.oracle[frame]
        if o and not skipped(o.t) then
            local got = reqs[frame] ~= nil
            local expect
            if mode == "oracle_rotation" then
                if got then
                    local Ls = streak_L[frame] or 36
                    expect = o.charging and not o.veto and o.q ~= nil and o.q <= Ls
                    local po = G.oracle[frame - 1]
                    if expect and not reqs[frame - 1] and po and po.charging and not po.veto and po.q and po.q <= Ls then
                        miss[#miss + 1] = { frame = frame - 1, o = po, why = string.format("上一帧 Q* 已经 ≤ L=%d，晚了一帧", Ls) }
                    end
                else
                    expect = o.charging and not o.veto and o.q ~= nil and o.q <= ROTATION[1]
                end
            else
                expect = o.charging and not o.veto and o.q ~= nil and o.q <= o.L
            end
            if o.charging and o.veto and o.q and o.q <= o.L then veto_frames = veto_frames + 1 end
            if expect and not got then
                miss[#miss + 1] = { frame = frame, o = o }
            elseif got and not expect then
                extra[#extra + 1] = { frame = frame, o = o }
            end
        end
    end
    for i, m in ipairs(miss) do
        if i > 4 then
            fail(R, string.format("……另有 %d 帧漏放", #miss - 4))
            break
        end
        fail(R, string.format("漏放：%s 时应请求放刀（%s）%s", "第 " .. m.frame .. " 帧", oracle_desc(w, m.o), m.why or ""))
    end
    for i, m in ipairs(extra) do
        if i > 4 then
            fail(R, string.format("……另有 %d 帧误放", #extra - 4))
            break
        end
        local why = (not m.o.charging) and "不在 (2,21)/(2,22)"
            or (m.o.veto and ("否决中（" .. tostring(m.o.veto_why or "long") .. "）")
            or (m.o.q and string.format("Q*=%.2f 不在 [%d, L=%s]", m.o.q, G.L_MIN, tostring(m.o.L)) or "没有候选条目"))
        fail(R, string.format("误放：第 %d 帧不该请求（%s；%s）", m.frame, why, oracle_desc(w, m.o)))
    end
    if exp.veto_frames_min and veto_frames < exp.veto_frames_min then
        fail(R, string.format("场景设计没起作用：没有出现「没有否决就会放刀」的帧（%d）", veto_frames))
    elseif veto_frames > 0 then
        info(R, string.format("否决（长窗口 / 抓取）压住了 %d 帧本该放刀的请求", veto_frames))
    end
    -- 否决 streak（CONTRACT 3.4「每个否决 streak 一行 VETO」，STAT 的 vetoes 同一口径）：神谕里 rc 生效（蓄力中、开关开）
    -- 且否决成立的连续帧算一段，离开蓄力或关开关就断开。VETO 行数和最后一行 STAT 的 vetoes 都必须等于它
    -- （「清零统计」之后 STAT 只算清零之后开始的段）。神谕不可靠的时段（oracle_skip / oracle_until）里有否决帧时只提示
    local v_n, v_prev, v_unsure, v_after = 0, false, false, 0
    local v_first = {}      -- 每个否决 streak 第一帧的神谕记录（VETO 行的 hs、why 按这一帧核对）
    local t_clear = rc_clear_time(w, rc_name)
    for frame = 1, w.frame do
        local o = G.oracle[frame]
        -- 读主角抛错、容忍期内整帧跳过的帧（神谕 skip_frame）：脚本这一帧不存在，否决状态原样延续到下一帧
        if not (o and o.skip_frame) then
            local on = o ~= nil and o.veto == true
            if on and skipped(o.t) then v_unsure = true end
            if on and not v_prev then
                v_n = v_n + 1
                v_first[v_n] = o
                if not t_clear or o.t > t_clear then v_after = v_after + 1 end
            end
            v_prev = on
        end
    end
    local vetoes = lines(P, "AutoParryGS", "VETO")
    local n_veto = #vetoes
    local stats = lines(P, "AutoParryGS", "STAT")
    local st_v = stats[#stats] and num(stats[#stats].f.vetoes)
    if v_unsure then
        info(R, string.format("神谕跳过的时段里有否决帧：不核对 VETO 行数（%d 行，神谕 %d 段）", n_veto, v_n))
    else
        if n_veto ~= v_n then
            fail(R, string.format("VETO 行 %d，神谕里否决 streak %d 段（每个否决 streak 恰好一行，CONTRACT 3.4）", n_veto, v_n))
        end
        if st_v and st_v ~= v_after then
            fail(R, string.format("最后一行 STAT 的 vetoes=%s，神谕里否决 streak %d 段%s", stats[#stats].f.vetoes, v_after,
                t_clear and "（清零统计之后）" or ""))
        end
    end
    -- v1.5.1 的 VETO.why（V15 第 9 节）：long / grab；记的是 streak 第一帧触发否决的条目里 hs 最小的那条
    -- （同一个 hs 两种原因都有时记 long）。行数和神谕一致时逐行核对 why 和 hs
    if CUR_VER == "v15" or CUR_VER == "v16" then
        -- v1.6 另认 sg（SKILL_GUARD 家族，V16 第 3.4 节）
        local whys = CUR_VER == "v16" and { long = true, grab = true, sg = true } or { long = true, grab = true }
        for i, l in ipairs(vetoes) do
            local why = l.f.why
            if not whys[why] then
                fail(R, string.format("第 %d 行 VETO 的 why=%s，应为 %s：%s", i, tostring(why),
                    CUR_VER == "v16" and "long / grab / sg" or "long 或 grab", l.text:sub(1, 140)))
            elseif not v_unsure and n_veto == v_n then
                local o = v_first[i]
                if o.veto_why ~= why then
                    fail(R, string.format("第 %d 行 VETO 的 why=%s，神谕在这个否决 streak 第一帧是 %s（hs 最小的那条否决）", i, why,
                        tostring(o.veto_why)))
                end
                local hs = num(l.f.hs)
                if hs and o.veto_hs and math.abs(hs - o.veto_hs) > 0.02 then
                    fail(R, string.format("第 %d 行 VETO 的 hs=%s，神谕在这个否决 streak 第一帧 hs 最小的否决条目是 %.2f", i, l.f.hs,
                        o.veto_hs))
                end
            end
        end
        if exp.veto_why then
            local got = {}
            for _, l in ipairs(vetoes) do got[#got + 1] = tostring(l.f.why) end
            if table.concat(got, ",") ~= table.concat(exp.veto_why, ",") then
                fail(R, string.format("VETO 的 why 依次是 %s，场景预期 %s", table.concat(got, ","), table.concat(exp.veto_why, ",")))
            end
        end
    end
end

-- ---------- v1.6 专有断言（docs/autoparry/V16.md 第 2~6 节）：FIRE 新字段、UVIEW、SKIP、RES 的 to ----------

local function oracle_reliable(sc, w, rc_name)
    return not sc.oracle_skip and not sc.oracle_until and sc.stat_oracle ~= false and not rc_clear_time(w, rc_name)
end

local function close(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= tol end

local function exp_fire_props(sc) return (sc.expect and sc.expect.fire_props) or {} end

-- FIRE 各字段按神谕逐个核对（V16 第 6.2 节），UVIEW 紧跟 FIRE；返回 vq=1 的 FIRE 数和该有 UVIEW 的 FIRE 数
local function check_v16_fire(R, sc, w, G, P, rc_name)
    local fires = lines(P, "AutoParryGS", "FIRE")
    local uv_by_id, fire_ids = {}, {}
    for _, u in ipairs(lines(P, "AutoParryGS", "UVIEW")) do
        local id = u.f.id or "?"
        if uv_by_id[id] then fail(R, "UVIEW id 重复：" .. id) end
        uv_by_id[id] = u
    end
    -- UVIEW 紧跟 FIRE：日志里 FIRE 之后下一行放刀模块的记录就是同一个 id 的 UVIEW
    local next_rc = {}
    do
        local last_fire
        for _, r in ipairs(P.list) do
            if r.tag == "AutoParryGS" then
                if last_fire then
                    next_rc[last_fire] = r
                    last_fire = nil
                end
                if r.kind == "FIRE" then last_fire = r.f.id or "?" end
            end
        end
    end
    local n_vq, n_u, shown = 0, 0, 0
    local function bad(msg)
        shown = shown + 1
        if shown <= 8 then fail(R, msg) end
    end
    local skipped_t = function(t)
        if sc.oracle_until and t >= sc.oracle_until then return true end
        for _, wd in ipairs(sc.oracle_skip or {}) do if t >= wd[1] and t < wd[2] then return true end end
        return false
    end
    for _, f in ipairs(fires) do
        local id = f.f.id or "?"
        fire_ids[id] = true
        local F = {}
        for _, k in ipairs({ "R0", "he0", "C1", "Cf", "mf", "nchg", "dX", "A0", "Q0", "Qp", "Qe1", "L" }) do F[k] = num(f.f[k]) end
        if f.f.mode ~= "E5c" then bad(string.format("FIRE id=%s 的 mode=%s，应为 E5c", id, tostring(f.f.mode))) end
        if f.f.vq ~= "0" and f.f.vq ~= "1" then bad(string.format("FIRE id=%s 的 vq=%s，应为 0/1", id, tostring(f.f.vq))) end
        -- 一致性（V16 第 7 节第 4 条，用日志里取整后的值）：Q0 = (R0 − dX)/mf、Qe1 = R0 − A0·(1 − 1/max(1, C1))、
        -- L_min ≤ Q0 ≤ L。不符多半是实现错误
        if F.R0 and F.dX and F.mf and F.Q0 and F.mf > 0 and math.abs(F.Q0 - (F.R0 - F.dX) / F.mf) > 0.02 then
            bad(string.format("FIRE id=%s 的 Q0=%s 和 (R0 − dX)/mf = (%s − %s)/%s 对不上", id, f.f.Q0, f.f.R0, f.f.dX, f.f.mf))
        end
        if F.R0 and F.A0 and F.C1 and F.Qe1 and math.abs(F.Qe1 - (F.R0 - F.A0 * (1.0 - 1.0 / math.max(1.0, F.C1)))) > 0.02 then
            bad(string.format("FIRE id=%s 的 Qe1=%s 和 R0 − A0·(1 − 1/max(1, C1)) 对不上（R0=%s A0=%s C1=%s）", id, f.f.Qe1, f.f.R0,
                f.f.A0, f.f.C1))
        end
        if F.Q0 and F.L and (F.Q0 > F.L + 0.006 or F.Q0 < G.L_MIN - 0.006) then
            bad(string.format("FIRE id=%s 的 Q0=%s 不在 [L_min=%d, L=%s] 内（v1.6 的 L 是真实剩余帧，比的是 Q）", id, f.f.Q0, G.L_MIN,
                f.f.L))
        end
        local ft = num(f.f.t)
        local q
        for _, rq in ipairs(w.requests) do
            if rq.script == rc_name and ft and math.abs(rq.t + w.clock_base - ft) < 0.002 then
                q = rq
                break
            end
        end
        local o = q and G.oracle[q.frame]
        if o and o.fire and not skipped_t(o.t) then
            local fe = o.fire
            local function cmp(k, want, tol, fmtw)
                local got = f.f[k]
                if want == nil then
                    if got ~= "-" then
                        bad(string.format("FIRE id=%s 的 %s=%s，神谕在放刀这一帧读不到（应写 -）", id, k, tostring(got)))
                    end
                elseif not close(num(got), want, tol) then
                    bad(string.format("FIRE id=%s 的 %s=%s，神谕是 " .. (fmtw or "%.3f") .. "（%s）", id, k, tostring(got), want,
                        oracle_desc(w, o)))
                end
            end
            cmp("R0", o.hs, 0.011, "%.2f")
            cmp("he0", o.he, 0.011, "%.2f")
            cmp("C1", fe.C1, 0.0015)
            cmp("Cf", fe.Cf, 0.0015)
            cmp("mf", fe.mf, 0.0015)
            cmp("dX", fe.dX, 0.011, "%.2f")
            cmp("A0", fe.A0, 0.011, "%.2f")
            cmp("Q0", fe.Q0, 0.011, "%.2f")
            cmp("Qp", fe.Qp, 0.011, "%.2f")
            cmp("Qe1", fe.Qe1, 0.011, "%.2f")
            if F.nchg ~= fe.nchg then
                bad(string.format("FIRE id=%s 的 nchg=%s，神谕是 %d（这个结果登记以来 m 变过几次）", id, tostring(f.f.nchg), fe.nchg))
            end
            if (f.f.vq == "1") ~= fe.vq then
                bad(string.format("FIRE id=%s 的 vq=%s，神谕是 %s（长窗口条目 Q ≤ 90 < hs）", id, tostring(f.f.vq), fe.vq and 1 or 0))
            end
            if fe.vq then n_vq = n_vq + 1 end
            local u = uv_by_id[id]
            if o.u then
                n_u = n_u + 1
                if not u then
                    bad(string.format("FIRE id=%s：放刀第一帧视野内有 %s 条目（hs=%.2f），应紧跟一行 UVIEW", id, o.u.why, o.u.hs))
                else
                    if next_rc[id] ~= u then bad(string.format("UVIEW id=%s 没有紧跟在 FIRE 后面", id)) end
                    if u.f.why ~= o.u.why then bad(string.format("UVIEW id=%s 的 why=%s，神谕是 %s（pb 优先）", id, tostring(u.f.why), o.u.why)) end
                    if not close(num(u.f.hs), o.u.hs, 0.011) or not close(num(u.f.he), o.u.he, 0.011) then
                        bad(string.format("UVIEW id=%s 的 hs/he=%s/%s，神谕是 %.2f/%.2f（U 里 hs 最小的那条）", id, tostring(u.f.hs),
                            tostring(u.f.he), o.u.hs, o.u.he))
                    end
                    if (u.f.same == "1") ~= (o.u.same == true) then
                        bad(string.format("UVIEW id=%s 的 same=%s，神谕是 %s（和触发条目是不是同一个结果）", id, tostring(u.f.same),
                            o.u.same and 1 or 0))
                    end
                    if (u.f.res or ""):upper() ~= o.u.res or (u.f.ent or ""):upper() ~= o.u.ent then
                        bad(string.format("UVIEW id=%s 的 res/ent=%s/%s，神谕是 %s/%s", id, tostring(u.f.res), tostring(u.f.ent), o.u.res,
                            o.u.ent))
                    end
                    local M = G.monsters[o.u.em]
                    local want_em = M and ("em" .. M.emid .. "#" .. M.sysidx)
                    if want_em and u.f.em ~= want_em then
                        bad(string.format("UVIEW id=%s 的 em=%s，应为 %s", id, tostring(u.f.em), want_em))
                    end
                end
            elseif u then
                bad(string.format("FIRE id=%s 后面写了 UVIEW，但放刀第一帧视野内没有 pb=1 / UNABLE_GUARD 的非弹体条目", id))
            end
        end
    end
    for id in pairs(uv_by_id) do
        if not fire_ids[id] then fail(R, "UVIEW id=" .. id .. " 没有对应的 FIRE") end
    end
    if shown > 8 then fail(R, string.format("……FIRE / UVIEW 另有 %d 处不符", shown - 8)) end
    -- 场景对第 i 刀写明的性质（V16 第 8.4 节各场景的要点，和神谕的逐字段核对互为印证）：
    --   nchg、C1、Cf（"-" = 读不到）、mf、A0、Q0、dX、vq、r0_gt（原始 hs 大于它）、qe1_q0（Qe1 与 Q0 相等 / 不等）、
    --   qp（true = 有上一帧的 Q，false = "-"）、uview（{ why, same } 或 false = 不该有）
    for i, props in pairs(exp_fire_props(sc)) do
        local f = fires[i]
        if not f then
            fail(R, string.format("场景要求第 %d 刀的性质，可只有 %d 行 FIRE", i, #fires))
        else
            local id = f.f.id or "?"
            local function nv(k) return num(f.f[k]) end
            for k, v in pairs(props) do
                local ok = true
                if k == "nchg" then ok = nv("nchg") == v
                elseif k == "C1" or k == "mf" then ok = close(nv(k), v, 0.0015)
                elseif k == "Cf" then ok = (v == "-" and f.f.Cf == "-") or (v ~= "-" and close(nv("Cf"), v, 0.0015))
                elseif k == "A0" or k == "Q0" or k == "dX" then ok = close(nv(k), v, 0.011)
                elseif k == "vq" then ok = f.f.vq == tostring(v)
                elseif k == "r0_gt" then ok = (nv("R0") or -1e9) > v
                elseif k == "qe1_q0" then
                    local d = (nv("Qe1") and nv("Q0")) and math.abs(nv("Qe1") - nv("Q0")) or nil
                    ok = d ~= nil and ((v and d <= 0.011) or (not v and d > 0.02))
                elseif k == "qp" then ok = (v and f.f.Qp ~= "-") or (not v and f.f.Qp == "-")
                elseif k == "uview" then
                    local u = uv_by_id[id]
                    if v == false then ok = u == nil
                    else ok = u ~= nil and u.f.why == v.why and ((u.f.same == "1") == (v.same == true)) end
                end
                if not ok then
                    fail(R, string.format("第 %d 刀（FIRE id=%s）不满足场景要求 %s=%s：%s", i, id, k,
                        type(v) == "table" and ("{why=" .. tostring(v.why) .. ",same=" .. tostring(v.same) .. "}") or tostring(v),
                        f.text:sub(1, 220)))
                end
            end
        end
    end
    return n_vq, n_u
end

-- SKIP（V16 第 2.4、6.1 节）：蓄力中、条目进了窗口但被该接过滤挡掉（pb / ug / fc），每个结果的每条条目一次。
-- 按神谕逐条核对（同一帧的先后不比：脚本按 pairs 遍历跟踪表）
local function check_v16_skip(R, sc, w, G, P)
    local skips = lines(P, "AutoParryGS", "SKIP")
    for _, s in ipairs(skips) do
        if s.f.why ~= "pb" and s.f.why ~= "ug" and s.f.why ~= "fc" then
            fail(R, "SKIP 的 why=" .. tostring(s.f.why) .. "，应为 pb / ug / fc：" .. s.text:sub(1, 140))
        end
    end
    local skipped_t = function(t)
        if sc.oracle_until and t >= sc.oracle_until then return true end
        for _, wd in ipairs(sc.oracle_skip or {}) do if t >= wd[1] and t < wd[2] then return true end end
        return false
    end
    local used, shown = {}, 0
    local function bad(msg)
        shown = shown + 1
        if shown <= 6 then fail(R, msg) end
    end
    for _, e in ipairs(G.oskips) do
        if not skipped_t(e.t) then
            local hit
            for i, s in ipairs(skips) do
                if not used[i] and (s.f.ent or ""):upper() == e.ent and (s.f.res or ""):upper() == e.res then
                    hit = i
                    break
                end
            end
            if not hit then
                bad(string.format("缺 SKIP：t=%.4f why=%s hs=%.2f Q=%.2f（%s 的条目 @%s 进了窗口、被该接过滤挡掉）", e.t + w.clock_base,
                    e.why, e.hs, e.Q, e.em, e.ent))
            else
                used[hit] = true
                local s = skips[hit]
                if s.f.why ~= e.why then bad(string.format("SKIP @%s 的 why=%s，神谕是 %s", e.ent, tostring(s.f.why), e.why)) end
                if not close(num(s.f.hs), e.hs, 0.011) or not close(num(s.f.Q), e.Q, 0.011) or not close(num(s.f.he), e.he, 0.011) then
                    bad(string.format("SKIP @%s 的 hs/he/Q=%s/%s/%s，神谕是 %.2f/%.2f/%.2f", e.ent, tostring(s.f.hs), tostring(s.f.he),
                        tostring(s.f.Q), e.hs, e.he, e.Q))
                end
                if not close(num(s.f.t), e.t + w.clock_base, 0.002) then
                    bad(string.format("SKIP @%s 的 t=%s，神谕在 t=%.4f（条目第一次进窗口的那一帧）", e.ent, tostring(s.f.t), e.t + w.clock_base))
                end
            end
        end
    end
    for i, s in ipairs(skips) do
        local t = num(s.f.t)
        if not used[i] and not (t and skipped_t(t - w.clock_base)) then
            bad("多出来的 SKIP（神谕里这条条目没有进窗口被挡掉，或者同一条条目写了两次）：" .. s.text:sub(1, 160))
        end
    end
    if shown > 6 then fail(R, string.format("……SKIP 另有 %d 处不符", shown - 6)) end
end

-- RES 的 to（V16 第 4 节）：放刀进 (2,23) 之后帧回调第一次看到的、不是 (2,23)/(2,24) 的基础层动作；到结算时还没离开写 -。
-- 神谕不可靠的时段（oracle_skip / oracle_until：脚本可能读不到动作）里还没找到就返回 nil（不核对）
local function want_to(G, sc, attempt, rt_sim)
    if not attempt then return "-" end
    for fr = attempt.frame, #G.oracle do
        local o = G.oracle[fr]
        if o and not o.skip_frame then
            if o.t > rt_sim + 0.001 then break end     -- RES 的 t 是 %.4f 取整后的
            if sc.oracle_until and o.t >= sc.oracle_until then return nil end
            for _, wd in ipairs(sc.oracle_skip or {}) do
                if o.t >= wd[1] and o.t < wd[2] then return nil end
            end
            if o.cat and not (o.cat == 2 and (o.idx == 23 or o.idx == 24)) then
                return string.format("(%d,%d)", o.cat, o.idx)
            end
        end
    end
    return "-"
end

local function check_rc_records(R, sc, w, G, P, rc_name)
    local exp = sc.expect or {}
    local fires = lines(P, "AutoParryGS", "FIRE")
    local ends = lines(P, "AutoParryGS", "FIRE_END")
    local res = lines(P, "AutoParryGS", "RES")
    if exp.fires and #fires ~= exp.fires then
        fail(R, string.format("FIRE 行数 %d，预期 %d", #fires, exp.fires))
    end
    if exp.fires_min and #fires < exp.fires_min then
        fail(R, string.format("FIRE 行数 %d，预期至少 %d", #fires, exp.fires_min))
    end
    if exp.requests and #w.requests ~= exp.requests then
        fail(R, string.format("changeActionRequest 调用 %d 次，预期 %d 次", #w.requests, exp.requests))
    end
    -- 场景要求的 rc 日志行数（例如 STAT：每 60 s 一行，「写出数据」和 Reset 时各补一行）
    local kinds = {}
    for k in pairs(exp.rc_counts or {}) do kinds[#kinds + 1] = k end
    table.sort(kinds)
    for _, k in ipairs(kinds) do
        local n = #lines(P, "AutoParryGS", k)
        if n ~= exp.rc_counts[k] then fail(R, string.format("rc 的 %s 行 %d 条，预期 %d 条", k, n, exp.rc_counts[k])) end
    end
    local end_by_id = {}
    for _, e in ipairs(ends) do end_by_id[e.f.id or "?"] = e end
    local res_by_id = {}
    for _, e in ipairs(res) do res_by_id[e.f.id or "?"] = e end
    local ids = {}
    local max_n = 0
    for _, f in ipairs(fires) do
        local id = f.f.id or "?"
        if ids[id] then fail(R, "FIRE id 重复：" .. id) end
        ids[id] = true
        local L = num(f.f.L)
        local R0 = num(f.f.R0)
        -- 不轮换时 L = 这一刀请求那一帧 rc 在用的提前量（加载时的配置，或菜单滑块改过之后的值）
        local ft0 = num(f.f.t)
        local want_L = ft0 and G:lead_at(ft0 - w.clock_base) or G.rc_cfg.parry_lead
        if not sc.expect.rotation and L and L ~= want_L then
            fail(R, string.format("FIRE id=%s 的 L=%s，这时的配置是 %d（轮换关）", id, f.f.L, want_L))
        end
        if sc.expect.rotation and L then
            local ok = false
            for _, v in ipairs(ROTATION) do if v == L then ok = true end end
            if not ok then fail(R, string.format("FIRE id=%s 的 L=%s 不在轮换表 {20,24,28,32,36} 里", id, f.f.L)) end
        end
        -- v1.6 的 R0 是原始 hs，C > 1 时可以大于 L（触发量是 Q，check_v16_fire 按 Q0 核对）
        if CUR_VER ~= "v16" and R0 and L and (R0 > L + 1e-6 or R0 < G.L_MIN - 1e-6) then
            fail(R, string.format("FIRE id=%s 的 R0=%s 不在 [%d, L=%s] 内", id, f.f.R0, G.L_MIN, f.f.L))
        end
        -- v15 起删了 closest 兜底（V15 第 3 节）：src 只能是 V0
        local release_ver = CUR_VER == "v15" or CUR_VER == "v16"
        local srcs = release_ver and { V0 = true } or { V0 = true, FB = true }
        if f.f.src and not srcs[f.f.src] then
            fail(R, string.format("FIRE id=%s 的 src=%s，应为 %s", id, f.f.src, release_ver and "V0（v1.5 起没有 FB 兜底）"
                or "V0 或 FB"))
        end
        if exp.src_fb and f.f.src ~= "FB" then
            fail(R, string.format("FIRE id=%s 的 src=%s，get_Item 抛错时应退回 closest（src=FB）", id, tostring(f.f.src)))
        end
        local from = norm_act(f.f.from)
        if from and from ~= "2_21" and from ~= "2_22" then
            fail(R, string.format("FIRE id=%s 的 from=%s，应为 (2,21) 或 (2,22)", id, f.f.from))
        end
        if exp.fire_from and from ~= exp.fire_from then
            fail(R, string.format("FIRE id=%s 的 from=%s，预期 %s", id, tostring(f.f.from), exp.fire_from))
        end
        local e = end_by_id[id]
        if not e then
            fail(R, "FIRE id=" .. id .. " 没有对应的 FIRE_END")
        else
            local n = num(e.f.n)
            if n and n > max_n then max_n = n end
            -- 找真值里的这次放刀
            local ft = num(f.f.t)
            local attempt
            if ft then
                for _, a in ipairs(G.truth.attempts) do
                    if a.origin == "request" and a.t_req and a.t_req + w.clock_base >= ft - 0.003
                        and a.t_req + w.clock_base <= ft + 0.5 then
                        attempt = a
                        break
                    end
                end
            end
            local entered = e.f.entered
            if attempt and entered ~= "1" then
                fail(R, string.format("FIRE_END id=%s entered=%s，但模拟器里这次请求进了 (2,23)", id, tostring(entered)))
            elseif not attempt and entered == "1" then
                fail(R, string.format("FIRE_END id=%s entered=1，但模拟器里这次没有进 (2,23)", id))
            end
            if CUR_VER == "v16" and not attempt then
                local r = res_by_id[id]
                if r and r.f.to ~= "-" then
                    fail(R, string.format("RES id=%s 的 to=%s，这一刀没进 (2,23)，应为 -", id, tostring(r.f.to)))
                end
            end
            if attempt then
                local r = res_by_id[id]
                local want = attempt.outcome == "parry" and ("CATCH" .. tostring(attempt.hit_level)) or "NOCATCH"
                -- v1.6：(2,25) cParrySlashHitS 是 RECOIL（被弹并随即身体挨打），不算接住（V16 第 4 节，G1 实测）
                if CUR_VER == "v16" and want == "CATCH25" then want = "RECOIL" end
                if CUR_VER == "v16" and r then
                    local wt = want_to(G, sc, attempt, num(r.f.t) and (num(r.f.t) - w.clock_base) or w.t)
                    if wt and r.f.to ~= wt then
                        fail(R, string.format("RES id=%s 的 to=%s，应为 %s（进 (2,23) 之后帧回调第一次看到的别的动作，结算前没离开写 -）",
                            id, tostring(r.f.to), wt))
                    end
                end
                if not r then
                    fail(R, string.format("FIRE id=%s 进了 (2,23) 但没有 RES 行（预期 %s）", id, want))
                elseif r.f.outcome ~= want then
                    fail(R, string.format("RES id=%s outcome=%s，模拟器真值是 %s", id, tostring(r.f.outcome), want))
                else
                    -- dt：接住 = 进 (2,25..27) 那一帧距 FIRE；没接住 = CREDIT 1.3 s 到点那一帧。
                    -- 强制结算（Reset 时；或 oracle_until 之后 rc 读不到主角、自停时）：dt = 结算那一刻距 FIRE
                    local dt = num(r.f.dt)
                    local rt = num(r.f.t)
                    -- 场景声明的提前结算时段 expect.res_forced = { {from, to}, ... }（主角消失、CREDIT 内又放了一刀：当场结算成
                    -- NOCATCH，dt = 结算那一刻距 FIRE；审查补充）
                    local early = false
                    for _, wd in ipairs(exp.res_forced or {}) do
                        if rt and rt >= w.clock_base + wd[1] and rt < w.clock_base + wd[2] then early = true end
                    end
                    local forced = r.phase == "reset" or (sc.oracle_until and rt and rt >= w.clock_base + sc.oracle_until) or early
                    local want_dt = forced and rt and ft and (rt - ft)
                        or (attempt.hit_t and (attempt.hit_t + w.clock_base - ft) or 1.3)
                    local tol = forced and 0.002 or (attempt.hit_t and 0.013 or 0.035)
                    if dt and ft and math.abs(dt - want_dt) > tol then
                        fail(R, string.format("RES id=%s dt=%s，模拟器真值 %.3f（%s）", id, r.f.dt, want_dt,
                            forced and "强制结算的那一刻" or (attempt.hit_t and "进 (2,25..27) 的那一帧" or "CREDIT=1.3 s")))
                    end
                end
            end
        end
        -- FIRE 选的条目必须是神谕在这一帧算出的最小 Q 条目（逐条取最小 hs，不是 closest）
        local ft = num(f.f.t)
        local q
        if ft then
            for _, rq in ipairs(w.requests) do
                if rq.script == rc_name and math.abs(rq.t + w.clock_base - ft) < 0.002 then
                    q = rq
                    break
                end
            end
        end
        local o = q and G.oracle[q.frame]
        if o and o.q and (not sc.oracle_until or o.t < sc.oracle_until) then
            -- v1.6 的 R0 是触发条目的原始 hs（神谕按 Q 选出的那条），其余版本 R0 就是最小 Q*
            local want_r0 = CUR_VER == "v16" and o.hs or o.q
            if R0 and want_r0 and math.abs(R0 - want_r0) > 0.02 then
                fail(R, string.format("FIRE id=%s 的 R0=%s，这一帧%s是 %.2f", id, f.f.R0,
                    CUR_VER == "v16" and "按 Q 选出的触发条目的原始 hs " or "最小 Q* ", want_r0))
            end
            local he0 = num(f.f.he0)
            if he0 and o.he and math.abs(he0 - o.he) > 0.02 then
                fail(R, string.format("FIRE id=%s 的 he0=%s，触发条目的 he 是 %.2f", id, f.f.he0, o.he))
            end
            if f.f.ent and o.entry and f.f.ent:upper() ~= o.entry:upper() then
                fail(R, string.format("FIRE id=%s 的 ent=%s，最小 Q 的条目是 %s（是不是取了 closest？）", id, f.f.ent, o.entry))
            end
        end
    end
    if exp.streak_n_min and max_n < exp.streak_n_min then
        fail(R, string.format("FIRE_END 的最大请求帧数 n=%d，预期 ≥%d（请求被拒后应每帧重试并合并成一次 FIRE）", max_n,
            exp.streak_n_min))
    end
    local nres = { catch = 0, nocatch = 0, recoil = 0 }
    for _, r in ipairs(res) do
        if (r.f.outcome or ""):match("^CATCH") then nres.catch = nres.catch + 1 elseif r.f.outcome == "NOCATCH" then
            nres.nocatch = nres.nocatch + 1 elseif r.f.outcome == "RECOIL" then nres.recoil = nres.recoil + 1 end
    end
    if exp.res_recoil and nres.recoil ~= exp.res_recoil then
        fail(R, string.format("RES RECOIL %d 次，预期 %d", nres.recoil, exp.res_recoil))
    end
    if CUR_VER == "v16" then
        for _, r in ipairs(res) do
            local oc = r.f.outcome
            if oc ~= "CATCH26" and oc ~= "CATCH27" and oc ~= "RECOIL" and oc ~= "NOCATCH" then
                fail(R, "RES 的 outcome=" .. tostring(oc) .. "，v1.6 只有 CATCH26 / CATCH27 / RECOIL / NOCATCH：" .. r.text:sub(1, 120))
                break
            end
        end
    end
    if exp.res_catch_min and nres.catch < exp.res_catch_min then
        fail(R, string.format("RES 接住 %d 次，预期至少 %d", nres.catch, exp.res_catch_min))
    end
    if exp.res_nocatch_min and nres.nocatch < exp.res_nocatch_min then
        fail(R, string.format("RES NOCATCH %d 次，预期至少 %d", nres.nocatch, exp.res_nocatch_min))
    end
    if w.t >= 61.0 and #lines(P, "AutoParryGS", "STAT") == 0 then
        fail(R, "rc 跑了 60 s 以上却没有 STAT 行（每 60 s 一行）")
    end
    if exp.vetoes_min and #lines(P, "AutoParryGS", "VETO") < exp.vetoes_min then
        fail(R, string.format("VETO 行 %d，预期至少 %d", #lines(P, "AutoParryGS", "VETO"), exp.vetoes_min))
    end
    if exp.no_requests_after then
        for _, q in ipairs(w.requests) do
            if q.t >= exp.no_requests_after then
                fail(R, string.format("rc 帧逻辑连续出错后应自停，但 t=%.3f 还在请求放刀", q.t))
                break
            end
        end
    end
    for _, wd in ipairs(exp.no_requests_between or {}) do
        for _, q in ipairs(w.requests) do
            if q.t >= wd[1] and q.t < wd[2] then
                fail(R, string.format("t=%.3f 请求了放刀，但 %.1f~%.1f s 自动放刀是关着的（菜单开关）", q.t, wd[1], wd[2]))
                break
            end
        end
    end
end

-- 轮换：只有真的进了 (2,23) 才前进；每 5 个一组是 {20,24,28,32,36} 的一个排列
local function check_rotation(R, P)
    local fires = lines(P, "AutoParryGS", "FIRE")
    local ends = {}
    for _, e in ipairs(lines(P, "AutoParryGS", "FIRE_END")) do ends[e.f.id or "?"] = e end
    local seq = {}
    for i, f in ipairs(fires) do
        local e = ends[f.f.id or "?"]
        local L = num(f.f.L)
        if e and e.f.entered == "1" then
            seq[#seq + 1] = L
        elseif e and fires[i + 1] and num(fires[i + 1].f.L) ~= L then
            fail(R, string.format("FIRE id=%s 没进 (2,23)，下一次放刀却换了档（%s → %s）", f.f.id, f.f.L, fires[i + 1].f.L))
        end
    end
    for g = 1, #seq, 5 do
        local seen = {}
        local n = 0
        for i = g, math.min(g + 4, #seq) do
            local L = seq[i]
            if seen[L] then fail(R, string.format("轮换第 %d 组里 L=%s 出现了两次", (g - 1) // 5 + 1, tostring(L))) end
            seen[L] = true
            n = n + 1
        end
        if n == 5 then
            for _, v in ipairs(ROTATION) do
                if not seen[v] then fail(R, string.format("轮换第 %d 组缺 L=%d", (g - 1) // 5 + 1, v)) end
            end
        end
    end
    local txt = {}
    for _, v in ipairs(seq) do txt[#txt + 1] = tostring(v) end
    info(R, "轮换序列（只算进了 (2,23) 的）：" .. table.concat(txt, ","))
end

-- 机关扫描：请求只在蓄力中、认机关和学习的前 3 次出招不放、SCAN 行合规、最后完成
local function check_scan(R, sc, w, G, P, rc_name)
    local mach = G.truth.machine
    local third_contact
    local n = 0
    for _, m in ipairs(mach) do
        if m.contact then
            n = n + 1
            if n == 3 then third_contact = m.contact end
        end
    end
    local bad_state, early = 0, 0
    for _, q in ipairs(w.requests) do
        if q.script == rc_name then
            if q.from ~= "(2,21)" and q.from ~= "(2,22)" then bad_state = bad_state + 1 end
            if not third_contact or q.t < third_contact then early = early + 1 end
        end
    end
    if bad_state > 0 then fail(R, string.format("扫描请求里有 %d 次主角不在蓄力中", bad_state)) end
    if early > 0 then fail(R, string.format("前 3 次机关出招（认机关 + 学 D_c）期间就请求了 %d 次", early)) end
    local scans = lines(P, "AutoParryGS", "SCAN")
    if #scans == 0 then fail(R, "扫描模式没有任何 SCAN 行") end
    local done = false
    local ok_n, void_n = 0, 0
    for _, s in ipairs(scans) do
        local ph = s.f.phase
        if ph ~= "learn" and ph ~= "fire" and ph ~= "done" then fail(R, "SCAN 的 phase=" .. tostring(ph) .. " 不合规") break end
        if ph == "done" then done = true end
        if ph == "fire" then
            local X = num(s.f.X)
            if not X or X < 0.2 or X > 1.05 then fail(R, "SCAN 的 X=" .. tostring(s.f.X) .. " 不在 0.2~1.05 s") break end
            if s.f.status == "OK" then ok_n = ok_n + 1 elseif s.f.status == "VOID" then void_n = void_n + 1
            else fail(R, "SCAN 的 status=" .. tostring(s.f.status) .. "，应为 OK/VOID") break end
        end
    end
    info(R, string.format("机关周期 %d 个，SCAN 有效 %d 个、作废 %d 个，rc 请求 %d 次", #mach, ok_n, void_n, #w.requests))
    if sc.expect.scan_done and not done then fail(R, "扫描没有完成（没有 phase=done 的 SCAN 行）") end
    if sc.expect.scan_learn_min then
        local n_learn = 0
        for _, s in ipairs(scans) do
            if s.f.phase == "learn" and s.f.status == "OK" then n_learn = n_learn + 1 end
        end
        if n_learn < sc.expect.scan_learn_min then
            fail(R, string.format("SCAN learn/OK 只有 %d 行，预期至少 %d（机关没认对？先打到主角的真怪不能当机关）", n_learn,
                sc.expect.scan_learn_min))
        end
    end
    if sc.expect.scan_done_reason then
        local reason
        for _, s in ipairs(scans) do if s.f.phase == "done" then reason = s.f.reason end end
        if reason ~= sc.expect.scan_done_reason then
            fail(R, string.format("扫描收尾 SCAN phase=done 的 reason=%s，预期 %s", tostring(reason), sc.expect.scan_done_reason))
        end
    end
    if #lines(P, "AutoParryGS", "STAT") == 0 and w.t >= 61.0 then
        fail(R, "rc 跑了 60 s 以上却没有 STAT 行（每 60 s 一行）")
    end
    -- 完成后自动关扫描：之后不该再有请求
    for _, s in ipairs(scans) do
        if s.f.phase == "done" then
            for _, q in ipairs(w.requests) do
                if q.t > s.t + 0.1 then
                    fail(R, string.format("扫描已完成（t=%.2f），t=%.2f 还在请求放刀（应自动关扫描）", s.t, q.t))
                    break
                end
            end
            break
        end
    end
end

-- 场景结束时 re.on_config_save 存下的配置（例如扫描途中结束时 scan 不能存成 true）
local function check_saved_config(R, sc, w)
    for name, want in pairs((sc.expect and sc.expect.saved_config) or {}) do
        local s = w:read_file(name .. ".json")
        local v = s and json.decode(s)
        if type(v) ~= "table" then
            fail(R, name .. ".json 没有在 re.on_config_save 里写出（或写坏了）")
        else
            for k, x in pairs(want) do
                if v[k] ~= x then
                    fail(R, string.format("re.on_config_save 存下的 %s.json 里 %s=%s，预期 %s", name, k, tostring(v[k]), tostring(x)))
                end
            end
        end
    end
end

-- ---------- 断言：探针 PT（结局互斥、接住优先） ----------

local function pt_class_kind(c)
    if not c or c == "" or c == "-" then return nil end
    if c:match("^CATCH") then return "catch" end
    if c:match("^WHIFF") or c == "INTERRUPTED" then return "whiff" end
    if c:match("^FAIL") then return "fail" end
    if c:match("^RECOIL") then return "recoil" end
    return nil
end

local function check_pt(R, sc, w, G, P)
    local pts = lines(P, "APCal", "PT")
    local attempts = G.truth.attempts
    local exp = sc.expect or {}
    if #pts ~= #attempts then
        fail(R, string.format("PT 行数 %d，模拟器里进 (2,23)/(2,24) %d 次（每次一行）", #pts, #attempts))
    end
    local ids = {}
    local counts = { catch = 0, whiff = 0, fail = 0, recoil = 0 }
    local used = {}
    for _, p in ipairs(pts) do
        local id = p.f.id or "?"
        if ids[id] then fail(R, "PT id 重复：" .. id) end
        ids[id] = true
        local cls = p.f.online_class
        local k = pt_class_kind(cls)
        if not k then
            fail(R, string.format("PT id=%s 的 online_class=%s 不是 CATCH*/RECOIL/FAIL_*/WHIFF*/INTERRUPTED 之一", id, tostring(cls)))
        else
            counts[k] = counts[k] + 1
        end
        if exp.pt_check ~= "count" then
            local ts = num(p.f.t_start) or num(p.f.t_obs)
            local att
            if ts then
                for _, a in ipairs(attempts) do
                    if not used[a.id] and math.abs(a.t_start + w.clock_base - ts) < 0.03 then
                        att = a
                        break
                    end
                end
            end
            if not att then
                fail(R, string.format("PT id=%s t_start=%s 对不上模拟器里任何一次 (2,23)", id, tostring(p.f.t_start)))
            else
                used[att.id] = true
                local truth
                if att.outcome == "parry" then
                    truth = "catch"
                elseif #att.contacts == 0 then
                    truth = "whiff"
                else
                    truth = "contact"
                end
                if truth == "catch" and k ~= "catch" then
                    fail(R, string.format("PT id=%s 结局 %s，但这次进了 (2,%s) 抵消成功（同帧身体接触也必须算接住）", id,
                        tostring(cls), tostring(att.hit_level)))
                elseif truth == "whiff" and k ~= "whiff" then
                    fail(R, string.format("PT id=%s 结局 %s，但这次从头到尾没有任何接触（应为 WHIFF）", id, tostring(cls)))
                elseif truth == "contact" and k == "catch" then
                    fail(R, string.format("PT id=%s 记成接住，但这次没有进 (2,25..27)", id))
                end
            end
        end
    end
    -- 预期结局次数是按「rc 会放刀」设计的；缺 rc 时（--allow-missing）只做逐次核对
    local want = HAS.rc and exp.pt or {}
    for k, n in pairs(want) do
        if counts[k] ~= n then
            fail(R, string.format("PT 结局 %s 有 %d 次，预期 %d 次", k, counts[k] or 0, n))
        end
    end
    info(R, string.format("PT %d 行：接住 %d、空放 %d、失败 %d、RECOIL %d", #pts, counts.catch, counts.whiff, counts.fail,
        counts.recoil))
    -- A1 空挥样本（P08：没有敌方接触、没有砍中、没有抵消事件、(2,23) 停 ≥3 s、已知怪物都在 10 m 外）
    if exp.pt_swing then
        local n = 0
        for _, p in ipairs(pts) do if p.f.swing == "1" then n = n + 1 end end
        if n ~= exp.pt_swing then
            fail(R, string.format("PT 里空挥样本 swing=1 有 %d 行，预期 %d 行（A1 空挥 HUD「空挥 n/3」靠它计数）", n, exp.pt_swing))
        end
    end
end

-- ---------- 断言：探针记全了没有（和模拟器真值逐类计数；用 JSON，日志可能被限频丢行） ----------

local function check_probe_counts(R, sc, w, G, P, recs)
    local by = {}
    local src = "JSON"
    if not recs or #recs == 0 then
        src = "日志"
        recs = {}
        for _, r in ipairs(P.list) do
            if r.tag == "APCal" then
                local x = { k = r.kind }
                for k, v in pairs(r.f) do x[k] = v end
                recs[#recs + 1] = x
            end
        end
    end
    for _, r in ipairs(recs) do
        by[r.k] = by[r.k] or {}
        local l = by[r.k]
        l[#l + 1] = r
    end
    local truth = G.truth
    -- CT：每次主玩家被敌方打中一行；弹体路径的那一次可记可不记（攻击者是弹体对象）
    local want = { BLADE = 0, BODY = 0 }
    local shell_n = 0
    for _, c in ipairs(truth.ct or {}) do
        if c.shell then shell_n = shell_n + 1 else want[c.cls] = (want[c.cls] or 0) + 1 end
    end
    local got = { BLADE = 0, BODY = 0, OTHER = 0 }
    for _, r in ipairs(by.CT or {}) do
        local c = tostring(r.cls)
        got[c] = (got[c] or 0) + 1
    end
    if got.BLADE ~= want.BLADE then
        fail(R, string.format("探针 CT（%s）刀上接触 BLADE %d 次，模拟器里 %d 次（DamageObj=it0000_0002_0 且层 ATTACK_PARRY_GET）", src,
            got.BLADE, want.BLADE))
    end
    if got.BODY < want.BODY or got.BODY > want.BODY + shell_n then
        fail(R, string.format("探针 CT（%s）身体接触 BODY %d 次，模拟器里 %d 次（另有弹体路径 %d 次）", src, got.BODY, want.BODY, shell_n))
    end
    local function cmp(kind, n_truth, what)
        local n = #(by[kind] or {})
        if n ~= n_truth then fail(R, string.format("探针 %s（%s）%d 条，模拟器里%s %d 次", kind, src, n, what, n_truth)) end
    end
    cmp("DMG", #(truth.dmg or {}), "伤害结算 evHit_Damage")
    cmp("PH", #(truth.ph or {}), "onParryHit")
    cmp("PS", #(truth.ps or {}), "onParrySuccess")
    cmp("EMHIT", #(truth.emhits or {}), "上捞斩砍中怪物")
    cmp("MSG", truth.messages or 0, "收到的 cMsgEmAttackAreaResult（含重发、含不打我的）")
    -- CONTRACT 4.2 的必有记录
    local st = { [1] = 0, [2] = 0 }
    for _, r in ipairs(by.SELFTEST or {}) do
        local s = tonumber(r.stage)
        if s then st[s] = (st[s] or 0) + 1 end
    end
    if st[1] == 0 then fail(R, "探针没有写 SELFTEST stage=1（加载时自检）") end
    local danger = truth.danger_msgs or 0
    if danger > 0 and st[2] == 0 then fail(R, "出现过打我的 DANGER，探针却没有写 SELFTEST stage=2（首次 DANGER 实物自检）") end
    if w.t >= 6.0 and #(by.PERF or {}) == 0 then fail(R, "探针没有写 PERF（每 5 s 一行）") end
    if danger > 0 and src == "JSON" and #(by.SER or {}) == 0 then
        fail(R, "出现过打我的 DANGER，探针 JSON 里却没有 SER 条目时间序列（离线重算 L 全靠它）")
    end
    local nd = truth.danger_attacks or 0
    local nep = #(by.EP or {})
    if nd > 0 and nep == 0 then
        fail(R, string.format("有 %d 招打我的 DANGER，探针一个 EP 回合都没写", nd))
    elseif nep < nd then
        warn(R, string.format("探针 EP 回合 %d 个，打我的 DANGER 攻击 %d 招", nep, nd))
    end
end

-- ---------- 补充断言（审查第 1 轮后加的） ----------

local function check_extra(R, sc, w, G, P, all_records)
    local exp = sc.expect or {}
    local recs = all_records and all_records.APCal
    -- rc 的每条错误都要进 JSON（上限 500）：最后一行 STAT 的 errors 和 JSON 里 ERR 的条数对得上
    if exp.rc_err_complete and HAS.rc and HAS.rc.json ~= false then
        local n_err, last_stat = 0, nil
        for _, r in ipairs((all_records and all_records.AutoParryGS) or {}) do
            if r.k == "ERR" then n_err = n_err + 1 end
            if r.k == "STAT" then last_stat = r end
        end
        if not last_stat then
            fail(R, "rc JSON 里没有 STAT（reset 时应补写一行）")
        elseif tonumber(last_stat.errors) ~= n_err then
            fail(R, string.format("rc 计了 %s 条错误（STAT），JSON 里只有 %d 条 ERR（限频时不能直接丢）", tostring(last_stat.errors), n_err))
        end
    end
    -- 被上捞斩打断的怪物：探针要在 EMHIT 之后 1.5 s 内记下它的受击动作（离线 INTERRUPTED 靠它）
    if exp.emstate_after_interrupt and HAS.probe then
        local by_em = {}
        for _, r in ipairs(recs or {}) do
            if r.k == "EMSTATE" and r.t then
                by_em[r.em] = by_em[r.em] or {}
                local l = by_em[r.em]
                l[#l + 1] = r
            end
        end
        local n_int = 0
        for _, a in ipairs(G.truth.attacks) do
            if a.interrupted then
                n_int = n_int + 1
                local M = G.monsters[a.em]
                local key = string.format("em%d#%d", M.emid, M.sysidx)
                local t0 = a.interrupted + w.clock_base
                local ok = false
                for _, r in ipairs(by_em[key] or {}) do
                    if r.t >= t0 - 0.002 and r.t <= t0 + 1.5 and tostring(r.act):find("Damage") then ok = true end
                end
                if not ok then
                    fail(R, string.format("攻击 %s 在 t=%.3f 被上捞斩打断，探针 1.5 s 内没有记下 %s 的受击动作 EMSTATE", a.id, t0, key))
                end
            end
        end
        if n_int == 0 then fail(R, "场景设计没起作用：没有被打断的攻击") end
    end
    -- 某时刻两个脚本是否持有某只怪的「打我」结果对象：改在持有观测里按句柄核对（check_holds）
end

-- ---------- 其它 ----------

local function check_misc(R, sc, w, P)
    local exp = sc.expect or {}
    for _, k in ipairs(exp.probe_kinds or {}) do
        if HAS.probe and #lines(P, "APCal", k) == 0 then fail(R, "探针没有写出 " .. k .. " 行") end
    end
    if exp.probe_kinds_after_err and HAS.probe then
        local first_err
        for _, r in ipairs(lines(P, "APCal", "ERR")) do
            first_err = first_err or r.t
        end
        if first_err then
            for _, k in ipairs(exp.probe_kinds_after_err) do
                local after = 0
                for _, r in ipairs(lines(P, "APCal", k)) do if r.t > first_err then after = after + 1 end end
                if after == 0 then fail(R, string.format("可选模块出错后探针没有继续写 %s（应只停该模块）", k)) end
            end
        end
    end
    -- rc1 标红时 HUD 整行换成出错提示；发布版没有 HUD，红色提示在菜单里（check_release 查）
    if exp.hud_red and HAS.rc and CUR_VER == "rc1" then
        local h = w.hud[HAS.rc.name]
        local found = false
        for _, e in ipairs(h and h.list or {}) do if e.text:find("出错", 1, true) then found = true end end
        if not found then warn(R, "rc 标红后 HUD 文字里没有「出错」（CONTRACT 3.6：整行换成「自动放刀 rc 出错，停下发日志」）") end
    end
    -- 模拟只驱动这些回调；登记在别的入口上的回调永远不会被调用，测试等于没覆盖
    local driven = { ["pre:UpdateBehavior"] = true, ["post:UpdateBehavior"] = true, ["pre:LateUpdateBehavior"] = true,
        ["post:LateUpdateBehavior"] = true, frame = true, draw_ui = true, reset = true, config_save = true }
    for _, kind in ipairs(w.cb_order) do
        if not driven[kind] then
            warn(R, "有脚本登记了 mock 不驱动的回调 " .. kind .. "（这部分代码没被测到）")
        end
    end
    if exp.hud_window then
        for _, s in ipairs(present) do
            if not w.hud_window[s.name] then
                fail(R, s.tag .. " 的 draw.text 不可用时没有退回 imgui.begin_window 窗口（CONTRACT 3.6 / P22）")
            end
        end
    end
    for _, s in ipairs(present) do
        local h = w.hud[s.name]
        -- 发布版删了 HUD（V15 第 3 节），只在菜单里显示状态：没画是对的，画了在 check_release 判失败
        local no_hud = (s.role == "rc" and (CUR_VER == "v15" or CUR_VER == "v16" or CUR_VER == "merged")) or s.role == "guard"
        if (not h or #h.list == 0) and not exp.hud_window and not no_hud then
            local m = w.menu[s.name]
            warn(R, s.tag .. " 整个场景没有用 draw.text 画过 HUD" .. ((m and #m > 0) and "（菜单有内容）" or ""))
        end
        if not w.menu[s.name] or #w.menu[s.name] == 0 then warn(R, s.tag .. " 没有在 re.on_draw_ui 里画菜单") end
    end
    -- UNMOCKED：不算失败，但列出来（可能是 mock 缺口，也可能是被测脚本把名字写错了）
    local um = {}
    for _, id in ipairs(w.note_order) do
        local n = w.notes[id]
        if n.kind:match("^UNMOCKED") or n.kind == "AUTOENUM" or n.kind == "HOOK_ON_UNMOCKED" or n.kind == "POST_NO_RETURN"
            or n.kind == "LABEL_NO_ID" or n.kind == "BAD_GLYPH" or n.kind == "VT_TYPE_MISMATCH" or n.kind == "BAD_PTR"
            or n.kind == "BAD_COMPONENT_TYPE" or n.kind == "PATH_FLATTENED" then
            local ss = {}
            for s in pairs(n.scripts) do ss[#ss + 1] = s end
            table.sort(ss)
            um[#um + 1] = string.format("%s %s ×%d [%s]", n.kind, n.key, n.count, table.concat(ss, ","))
        end
    end
    R.unmocked = um
    for _, line in ipairs(um) do
        if line:match("^POST_NO_RETURN") then
            warn(R, "post 钩子没有 return retval（REF 可能把返回值当成别的）：" .. line)
        elseif line:match("^BAD_GLYPH") then
            warn(R, "界面文字含字体里可能没有的字符（°、全角空格）：" .. line)
        end
    end
end

-- ---------- 发布版专有断言（v1.5.1：V15.md 第 2~6、9 节；v1.6：V16.md 第 2.5、2.7、4、6 节） ----------

-- 发布版 HDR 的版本号：分析脚本按版本取冻结参数（1.5 → L=26，1.5.1 → L=30，1.6 → 28 且 Q 口径），必须一字不差
local REL = {
    v15 = {
        ver = "1.5.1", cfg_ver = 2,
        -- 菜单（V15 第 6 节）：标题、启用、滑块和下面的小字、七项统计、调试日志、清零统计、写出数据；控件标签带 ##英文ID
        menu = { "自动放刀（实验）##AutoParryGS", "启用（实验）##", "提前量（帧，1/60 秒）##", "越小越常出抵消动作；太小会被先打到。默认 30",
            "放刀 ", "接住 ", "否决 ", "联机副本跳过 ", "fail-open ", "读取错误 ", "错误 ", "（红 ", " 黄 ",
            "调试日志##", "清零统计##", "写出数据##" },
        stat_default = { fb = 0, failopen = 0, replica = 0, readerr = 0 },
        stat_order = { "fires", "catches", "vetoes", "fb", "failopen", "errors", "red", "yellow", "readfail", "replica",
            "readerr" },
        -- grab_enum（v1.5.1）：加载时有抓取类型的名字读不到、跳过了，总写一行（不受 debug_log 控制，同 self_stop）
        dbg = { loaded = true, cfg_upgrade = true, track_full = true, read_fail = true, read_back = true,
            no_action = true, action_back = true, self_stop = true, grab_enum = true },
    },
    v16 = {
        ver = "1.6", cfg_ver = 3,
        -- 菜单（V16 第 2.7 节）：滑块改成「真实剩余帧」、小字说明已按怪物速度修正；统计行加 被弹 / 该接过滤跳过 /
        -- 读不准不放 / 速度读不到（统计行的具体排版不钉，只查这些词都在）
        menu = { "自动放刀（实验）##AutoParryGS", "启用（实验）##", "提前量（真实剩余帧，1/60 秒）##ap_lead",
            "已按怪物速度修正。越小越常出抵消动作；太小会被先打到。默认 28",
            "放刀", "接住", "被弹", "否决", "该接过滤跳过", "读不准不放", "速度读不到", "联机副本跳过", "fail-open", "读取错误",
            "错误 ", "（红 ", " 黄 ", "调试日志##", "清零统计##", "写出数据##" },
        stat_default = { fb = 0, failopen = 0, replica = 0, readerr = 0, recoils = 0, speedfail = 0, speedhold = 0,
            clockskip = 0, vetoq = 0, fclosed = 0, excl = 0, uview = 0, sidmis = 0 },
        stat_order = { "fires", "catches", "vetoes", "fb", "failopen", "errors", "red", "yellow", "readfail", "replica",
            "readerr", "recoils", "speedfail", "speedhold", "clockskip", "vetoq", "fclosed", "excl", "uview", "sidmis" },
        -- v1.6 新的调试事件：cfg_upgrade（迁移到 28）、speed_fail、sidmis（调试日志开着时）、guard_enum（加载时总写）
        dbg = { loaded = true, cfg_upgrade = true, track_full = true, read_fail = true, read_back = true,
            no_action = true, action_back = true, self_stop = true, grab_enum = true, guard_enum = true, speed_fail = true,
            sidmis = true },
    },
}
local RED_TEXT = "出错了：请把 re2_framework_log.txt 发给开发者，然后 Reset Scripts"
local MENU_MIN_TEXT = { "自动放刀（实验）##AutoParryGS", "状态：", "写出数据##", "错误 ui yellow" }
local ITEMS_TEXT = "读不出条目的预告不放刀"
local DBG_BURST_MAX = 10
-- v1.6 状态行（V16 第 2.5、2.7 节）：速度连续读不到、过滤字段读取出错、过滤用的枚举读不到。这几个模块报黄但都不停用读取，
-- 不能说「有可选模块停用，自动放刀照常」
local V16_STATUS = {
    speed_stop = "速度读不到，已停止自动放刀",
    speed_back = "已恢复",
    filter = "读不准的条目不放刀",
    filter_enum = "这些攻击一律不放刀",
}
local NOT_OFF_MODS = { items = true, speed = true, filter = true, filter_enum = true }

local function stat_ok(v, got)
    if got == nil then return false end
    if type(v) == "table" then return (not v.min or got >= v.min) and (not v.max or got <= v.max) end
    return got == v
end

local function stat_want_text(v)
    if type(v) ~= "table" then return tostring(v) end
    if v.min and v.max then return string.format("%d~%d", v.min, v.max) end
    return v.min and ("≥" .. v.min) or ("≤" .. tostring(v.max))
end

local function check_release(R, sc, w, G, P, all_records, fire_info)
    local rc = HAS.rc
    if not rc then return end
    local C = REL[CUR_VER]
    local v16 = CUR_VER == "v16"
    local exp = sc.expect or {}
    local tag = "AutoParryGS"
    -- HDR：字段同 rc，rotation=0、scan=0；lead / auto_parry 是加载、升级（迁移）、夹范围之后的配置。
    -- v1.6 追加 rule=E5c、filter=g1、cfg_ver=3、c_lo=0.50、c_hi=2.00（V16 第 6.1 节）
    local hdrs = lines(P, tag, "HDR")
    if #hdrs ~= 1 then fail(R, string.format("发布版写了 %d 行 HDR，应恰好 1 行（加载时）", #hdrs)) end
    local h = hdrs[1]
    if h then
        local want = {
            { "auto_parry", G.cfg0.auto_parry and "1" or "0" }, { "lead", tostring(G.cfg0.parry_lead) },
            { "rotation", "0" }, { "scan", "0" }, { "L_min", tostring(G.L_MIN) }, { "W_long", "60" }, { "H_veto", "90" },
            { "credit", "1.3" },
        }
        if v16 then
            for _, kv in ipairs({ { "rule", "E5c" }, { "filter", "g1" }, { "cfg_ver", "3" }, { "c_lo", "0.50" }, { "c_hi", "2.00" } }) do
                want[#want + 1] = kv
            end
        end
        for _, kv in ipairs(want) do
            if h.f[kv[1]] ~= kv[2] then
                fail(R, string.format("发布版的 HDR %s=%s，预期 %s", kv[1], tostring(h.f[kv[1]]), kv[2]))
            end
        end
        local ver = h.f.ver or ""
        if ver ~= C.ver then
            fail(R, "发布版的 HDR ver=" .. ver .. "，应为 " .. C.ver .. "（不含 rc：分析脚本据此认出版本；冻结的提前量按版本取，"
                .. "1.5 → 26、1.5.1 → 30、1.6 → 28 且是 Q 口径）")
        end
    end
    -- 配置升级 / 迁移：v1.5.1 读到没有 cfg_ver 的配置 → 30；v1.6 读到 cfg_ver 不是 ≥3 的数 → 28。都写一行 DBG cfg_upgrade
    -- （debug_log 开着时）；不升级就不写。HDR 的 lead 已按神谕的升级口径核对，这里钉住 DBG 只在升级时出现
    local n_up = 0
    for _, r in ipairs(lines(P, tag, "DBG")) do if r.f.ev == "cfg_upgrade" then n_up = n_up + 1 end end
    local want_up = (G.cfg_upgraded and G.cfg0.debug_log) and 1 or 0
    if n_up ~= want_up then
        fail(R, string.format("DBG cfg_upgrade %d 行，预期 %d 行（配置%s升级，debug_log %s）", n_up, want_up,
            G.cfg_upgraded and "要" or "不要", G.cfg0.debug_log and "开" or "关"))
    end
    -- 每行 cfg_upgrade 的 from 是配置文件里的原值、to 是升级后的值（V15 第 9 节澄清，V16 第 2.7 节同一口径）。from 按 rc 的
    -- DBG 写法：整数原样、非整数 %.1f（int_s），没有 parry_lead 键写 "-"，布尔 1/0，文本空白换成 _
    local seed = (sc.config or {}).AutoParryGS
    local raw = type(seed) == "table" and seed.parry_lead or nil
    local want_from
    if raw == nil then
        want_from = "-"
    elseif type(raw) == "number" then
        want_from = math.tointeger(raw) and tostring(math.tointeger(raw)) or string.format("%.1f", raw)
    elseif type(raw) == "boolean" then
        want_from = raw and "1" or "0"
    else
        want_from = (tostring(raw):gsub("%s", "_"))
    end
    local want_to = tostring(G.prof.upgrade and G.prof.upgrade.to)
    for _, r in ipairs(lines(P, tag, "DBG")) do
        if r.f.ev == "cfg_upgrade" and (r.f.from ~= want_from or r.f.to ~= want_to) then
            fail(R, string.format("DBG cfg_upgrade 的 from=%s to=%s，预期 from=%s（配置文件里的原值）to=%s：%s",
                tostring(r.f.from), tostring(r.f.to), want_from, want_to, r.text:sub(1, 140)))
        end
    end
    if #lines(P, tag, "SCAN") > 0 then fail(R, "发布版写了 SCAN 行（机关扫描已删，V15 第 3 节）") end
    -- CFG（V15 第 4 节）：菜单每次真的改了启用开关或提前量就写一行（总写，不受 debug_log 控制）；加载时、值没变时都不写
    local cfgs = lines(P, tag, "CFG")
    local want_c = G.cfg_changes
    if #cfgs ~= #want_c then
        fail(R, string.format("CFG 行 %d 条，菜单真的改了启用开关 / 提前量 %d 次（每次改动恰好一行，不改不写）", #cfgs, #want_c))
    end
    for i = 1, math.min(#cfgs, #want_c) do
        local c, wc = cfgs[i], want_c[i]
        local t = num(c.f.t)
        local want_t = w.clock_base + wc.t + (w.phase_offset.ui or 0)
        local wa = wc.auto_parry and "1" or "0"
        if c.f.auto_parry ~= wa or c.f.lead ~= tostring(wc.parry_lead) or not t or math.abs(t - want_t) > 0.02 then
            fail(R, string.format("第 %d 行 CFG 和菜单改动对不上：%s；预期 t≈%.4f auto_parry=%s lead=%d", i, c.text:sub(1, 120),
                want_t, wa, wc.parry_lead))
        end
    end
    -- STAT：最后一行（Reset 时补写）的计数和场景预期一致；errors / red / yellow 和 JSON 里的 ERR 条数一致（每条错误都进 JSON）。
    -- v1.6：新字段的默认预期取神谕（神谕可靠时：没有 oracle_skip / oracle_until、没清零统计），场景的 expect.stat 优先
    local recs = (all_records and all_records.AutoParryGS) or {}
    local last
    for _, r in ipairs(recs) do if r.k == "STAT" then last = r end end
    local t_clear = rc_clear_time(w, rc.name)
    if not last then
        fail(R, "发布版的 JSON 里没有 STAT（Reset 时应补写一行）")
    else
        local want = {}
        for k, v in pairs(C.stat_default) do want[k] = v end
        if v16 then
            local n_recoil = 0
            for _, a in ipairs(G.truth.attempts) do
                if a.origin == "request" and a.outcome == "parry" and a.hit_level == 25 then n_recoil = n_recoil + 1 end
            end
            want.recoils = n_recoil
            if oracle_reliable(sc, w, rc.name) then
                for _, k in ipairs({ "speedfail", "speedhold", "clockskip", "fclosed", "excl", "sidmis", "failopen" }) do
                    want[k] = G.ostat[k]
                end
                if fire_info then
                    want.vetoq, want.uview = fire_info.vq, fire_info.uview
                end
            else
                for _, k in ipairs({ "speedfail", "speedhold", "clockskip", "fclosed", "excl", "sidmis", "vetoq", "uview" }) do
                    want[k] = nil      -- 神谕不可靠的时段：只核对场景明写的
                end
            end
        end
        for k, v in pairs(exp.stat or {}) do want[k] = v end
        -- 按 STAT 的字段顺序核对；场景写了表外的键（多半是拼错）也照样核对，STAT 里没有这个字段就判失败
        local order, seen = {}, {}
        for _, k in ipairs(C.stat_order) do
            order[#order + 1] = k
            seen[k] = true
        end
        local extra = {}
        for k in pairs(want) do if not seen[k] then extra[#extra + 1] = k end end
        table.sort(extra)
        for _, k in ipairs(extra) do order[#order + 1] = k end
        for _, k in ipairs(order) do
            local v = want[k]
            if v ~= nil and not stat_ok(v, tonumber(last[k])) then
                fail(R, string.format("最后一行 STAT 的 %s=%s，预期 %s", k, tostring(last[k]), stat_want_text(v)))
            end
        end
        -- v1.6 的计数和记录行数自洽（V16 第 6.3 节的口径；清零统计之后不比）
        if v16 and not t_clear then
            local cnt = { fc = 0, ex = 0 }
            for _, s in ipairs(lines(P, tag, "SKIP")) do
                if s.f.why == "fc" then cnt.fc = cnt.fc + 1 elseif s.f.why == "pb" or s.f.why == "ug" then cnt.ex = cnt.ex + 1 end
            end
            local nvq = 0
            for _, f in ipairs(lines(P, tag, "FIRE")) do if f.f.vq == "1" then nvq = nvq + 1 end end
            local nrc = 0
            for _, r in ipairs(lines(P, tag, "RES")) do if r.f.outcome == "RECOIL" then nrc = nrc + 1 end end
            local pairs_ = { { "fclosed", cnt.fc, "SKIP why=fc" }, { "excl", cnt.ex, "SKIP why=pb|ug" },
                { "uview", #lines(P, tag, "UVIEW"), "UVIEW" }, { "vetoq", nvq, "FIRE vq=1" }, { "recoils", nrc, "RES RECOIL" } }
            for _, p in ipairs(pairs_) do
                if tonumber(last[p[1]]) ~= p[2] then
                    fail(R, string.format("STAT 的 %s=%s，日志里 %s 有 %d 行（口径应一致）", p[1], tostring(last[p[1]]), p[3], p[2]))
                end
            end
        end
        -- 「清零统计」之后 STAT 从 0 重新计：只和清零之后的 ERR 对账（日志行数仍按全部 ERR）
        local t_from = t_clear and (w.clock_base + t_clear + (w.phase_offset.ui or 0)) or -math.huge
        local n = { all = 0, red = 0, yellow = 0 }
        local n_since = { all = 0, red = 0, yellow = 0 }
        for _, r in ipairs(recs) do
            if r.k == "ERR" then
                n.all = n.all + 1
                if n[r.level] then n[r.level] = n[r.level] + 1 end
                if (tonumber(r.t) or math.huge) >= t_from then
                    n_since.all = n_since.all + 1
                    if n_since[r.level] then n_since[r.level] = n_since[r.level] + 1 end
                end
            end
        end
        local m = n_since
        if n.all < 500 and (tonumber(last.errors) ~= m.all or tonumber(last.red) ~= m.red or tonumber(last.yellow) ~= m.yellow) then
            fail(R, string.format("STAT 计了错误 %s（红 %s 黄 %s），JSON 里%s ERR %d 条（红 %d 黄 %d）：错误要逐条进 JSON",
                tostring(last.errors), tostring(last.red), tostring(last.yellow), t_clear and "清零统计之后" or "", m.all,
                m.red, m.yellow))
        end
        -- 日志只写前 20 条，排队按 1 行/秒补写，Reset 时把排队的一次写完（CONTRACT 2.1）：日志里恰好 min(总数, 20) 行。
        -- Reset 时最后一份 JSON 写失败（场景注入）：那份里的记录只在日志里，写失败本身的 ERR mod=json 也必须进日志
        local n_log = #lines(P, tag, "ERR")
        local reset_fail = 0
        for _, j in ipairs(w.json_writes) do
            if j.script == rc.name and j.injected and j.phase == "reset" then reset_fail = reset_fail + 1 end
        end
        if reset_fail > 0 then
            local n_json_err = 0
            for _, r in ipairs(lines(P, tag, "ERR")) do
                if r.f.mod == "json" and r.phase == "reset" then n_json_err = n_json_err + 1 end
            end
            if n_json_err < reset_fail then
                fail(R, string.format("Reset 时最后一份 JSON 写失败 %d 次，日志里 Reset 时的 ERR mod=json 只有 %d 行（收尾的错误不许丢）",
                    reset_fail, n_json_err))
            end
            if n_log < math.min(n.all, 20) + reset_fail then
                fail(R, string.format("日志里 ERR %d 行，少于 JSON 里的 %d 条（前 20 条）加 Reset 时写失败的 %d 条", n_log, n.all,
                    reset_fail))
            end
        elseif n_log ~= math.min(n.all, 20) then
            fail(R, string.format("日志里 ERR %d 行，JSON 里 %d 条：日志应恰好写前 %d 条（限频排队、Reset 时补完，不许丢）",
                n_log, n.all, math.min(n.all, 20)))
        end
    end
    -- 存配置：三个键（rc 的 lead_rotation / scan 随之消失）+ cfg_ver（v1.5.1 = 2、v1.6 = 3），值是场景结束时的配置
    local s = w:read_file("AutoParryGS.json")
    local v = s and json.decode(s)
    if type(v) ~= "table" then
        fail(R, "AutoParryGS.json 没有在 re.on_config_save 里写出（或写坏了）")
    else
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        if table.concat(keys, ",") ~= "auto_parry,cfg_ver,debug_log,parry_lead" then
            fail(R, "存下的 AutoParryGS.json 的键是 " .. table.concat(keys, ",")
                .. "，应只有 auto_parry、parry_lead、debug_log、cfg_ver")
        end
        if v.cfg_ver ~= C.cfg_ver then
            fail(R, "存下的 AutoParryGS.json 的 cfg_ver=" .. tostring(v.cfg_ver) .. "，应为 " .. C.cfg_ver
                .. "（下次加载据此判断提前量的含义、要不要迁移）")
        end
        local c = G.rc_cfg
        if v.auto_parry ~= c.auto_parry or v.parry_lead ~= c.parry_lead or v.debug_log ~= c.debug_log then
            fail(R, string.format("存下的配置 auto_parry=%s parry_lead=%s debug_log=%s，场景结束时应为 %s / %s / %s",
                tostring(v.auto_parry), tostring(v.parry_lead), tostring(v.debug_log), tostring(c.auto_parry),
                tostring(c.parry_lead), tostring(c.debug_log)))
        end
    end
    -- HUD 已删（V15 第 3 节）：状态只在菜单里
    local hh = w.hud[rc.name]
    if (hh and #hh.list > 0) or w.hud_window[rc.name] then
        fail(R, "发布版画了 HUD（draw.text / 浮动窗口），V15 第 3 节已删，状态只在 REF 菜单里显示")
    end
    -- 菜单（最后一次画的内容）。完整菜单出过错（ERR mod=ui）之后只画简化菜单：状态、「写出数据」、最近的错误
    local menu = table.concat(w.menu[rc.name] or {}, "\n")
    local seen_menu = w.menu_seen[rc.name] or {}
    local function seen_text(txt)
        for line in pairs(seen_menu) do if line:find(txt, 1, true) then return true end end
        return false
    end
    local err_mods = {}     -- 按 JSON 里的 ERR（日志只写前 20 条）：模块 → 条数；"yellow:模块" → 报过黄
    for _, r in ipairs(recs) do
        if r.k == "ERR" then
            err_mods[tostring(r.mod)] = (err_mods[tostring(r.mod)] or 0) + 1
            if r.level == "yellow" then err_mods["yellow:" .. tostring(r.mod)] = true end
        end
    end
    if err_mods.ui then
        for _, txt in ipairs(MENU_MIN_TEXT) do
            if not menu:find(txt, 1, true) then fail(R, "完整菜单出错后的简化菜单里没有「" .. txt .. "」") end
        end
        if menu:find("启用（实验）##", 1, true) then fail(R, "完整菜单出过错（ERR mod=ui），之后还在画完整菜单") end
    else
        for _, txt in ipairs(C.menu) do
            if not menu:find(txt, 1, true) then fail(R, "发布版菜单里没有「" .. txt .. "」") end
        end
    end
    -- 条目读取出错（items 报黄但不停用）：状态行要说读不出的预告不放刀
    if err_mods["yellow:items"] and not menu:find(ITEMS_TEXT, 1, true) then
        fail(R, "条目读取出过错（ERR mod=items），菜单状态行里没有「" .. ITEMS_TEXT .. "」")
    end
    -- 报黄但不停用的模块（items；v1.6 另有 speed / filter / filter_enum）不能套「有可选模块停用，自动放刀照常」
    local others = false
    for k in pairs(err_mods) do
        local m = type(k) == "string" and k:match("^yellow:(.+)$")
        if m and not (NOT_OFF_MODS[m] and (v16 or m == "items")) then others = true end
    end
    local any_not_off = false
    for m in pairs(NOT_OFF_MODS) do if err_mods["yellow:" .. m] and (v16 or m == "items") then any_not_off = true end end
    if any_not_off and not others and menu:find("自动放刀照常", 1, true) then
        fail(R, "只有读取出错但不停用的模块报过黄（读不准的不放刀），菜单却说「自动放刀照常」")
    end
    if v16 then
        -- V16 第 2.5、2.7 节的状态行（菜单每次重画，中途出现过的状态行按 menu_seen 查）
        if exp.menu_seen then
            for _, txt in ipairs(exp.menu_seen) do
                if not seen_text(txt) then fail(R, "菜单里从没出现过「" .. txt .. "」") end
            end
        end
        if exp.menu_final then
            for _, txt in ipairs(exp.menu_final) do
                if not menu:find(txt, 1, true) then fail(R, "场景结束时的菜单里没有「" .. txt .. "」") end
            end
        end
        if exp.menu_absent then
            for _, txt in ipairs(exp.menu_absent) do
                if seen_text(txt) then fail(R, "菜单里不该出现「" .. txt .. "」") end
            end
        end
        if err_mods["yellow:filter"] and not menu:find(V16_STATUS.filter, 1, true) then
            fail(R, "过滤字段读取出过错（ERR mod=filter），菜单状态行里没有「" .. V16_STATUS.filter .. "」")
        end
        if err_mods["yellow:filter_enum"] and not menu:find(V16_STATUS.filter_enum, 1, true) then
            fail(R, "过滤用的枚举读不到（ERR mod=filter_enum），菜单状态行里没有「" .. V16_STATUS.filter_enum .. "」")
        end
    end
    local has_red = #lines(P, tag, "RED") > 0
    if has_red and not menu:find(RED_TEXT, 1, true) then
        fail(R, "进了红状态，菜单里没有「" .. RED_TEXT .. "」")
    elseif not has_red and menu:find(RED_TEXT, 1, true) then
        fail(R, "没进红状态，菜单却显示了红色出错提示")
    end
    -- 界面文字：控件标签带 ##英文ID、避开字体里可能没有的字符（项目约定）
    for _, id in ipairs(w.note_order) do
        local nt = w.notes[id]
        if (nt.kind == "LABEL_NO_ID" or nt.kind == "BAD_GLYPH") and nt.scripts[rc.name] then
            fail(R, string.format("发布版的界面文字不合约定（%s）：%s", nt.kind == "LABEL_NO_ID" and "控件标签缺 ##英文ID"
                or "含字体里可能没有的字符", nt.key))
        end
    end
    -- DBG：只留关键事件、不许每帧刷
    local dbg = lines(P, tag, "DBG")
    local unknown = {}
    for _, r in ipairs(dbg) do
        local ev = r.f.ev or "?"
        if not C.dbg[ev] and not unknown[ev] then
            unknown[ev] = true
            warn(R, "发布版写了表外的 DBG 事件 ev=" .. ev .. "（V15 第 3 节：只保留关键事件）")
        end
    end
    local i0 = 1
    for i = 1, #dbg do
        while dbg[i].t - dbg[i0].t > 1.0 do i0 = i0 + 1 end
        if i - i0 + 1 > DBG_BURST_MAX then
            fail(R, string.format("发布版的 DBG 在 t=%.2f 附近 1 秒内写了 %d 行（V15 第 3 节：不许每帧刷）", dbg[i].t, i - i0 + 1))
            break
        end
    end
    if exp.dbg_max and #dbg > exp.dbg_max then
        fail(R, string.format("DBG 写了 %d 行，预期至多 %d 行（debug_log 关着时一行都不该写）", #dbg, exp.dbg_max))
    end
    for _, ev in ipairs(exp.dbg_events or {}) do
        local found = false
        for _, r in ipairs(dbg) do if r.f.ev == ev then found = true end end
        if not found then fail(R, "预期有一行 DBG ev=" .. ev) end
    end
    for _, ev in ipairs(exp.dbg_absent or {}) do
        for _, r in ipairs(dbg) do
            if r.f.ev == ev then
                fail(R, "不该有 DBG ev=" .. ev .. "：" .. r.text:sub(1, 120))
                break
            end
        end
    end
    -- 放刀模块只钩 receiveGameMessage 一个函数（V16 第 0、8.4 节：不钩新函数）
    for _, hr in ipairs(w.hook_regs) do
        if hr.script == rc.name and hr.key ~= "app.cMasterPlayerControllerEntity.receiveGameMessage(ace.cGameMessage)" then
            fail(R, "发布版钩了 receiveGameMessage 以外的函数：" .. hr.key)
        end
    end
    -- v1.6：v16_cache（V16 第 8.4 节第 9 条）——同一帧每只怪 findEnemy 只调一次；神谕跟踪着这只怪的结果的帧必须读（每帧都读 C）
    if v16 and exp.find_once then
        local over, miss = 0, 0
        for fr = 1, w.frame do
            local fc = G.find_calls[fr] or {}
            for idx, n in pairs(fc) do if n > 1 then over = over + 1 end end
            local o = G.oracle[fr]
            for _, idx in ipairs((o and o.tracked) or {}) do
                if not fc[idx] then miss = miss + 1 end
            end
        end
        if over > 0 then fail(R, string.format("有 %d 帧同一只怪 findEnemy_SystemIndex 调了不止一次（同一帧应按 SystemIndex 缓存）", over)) end
        if miss > 0 then fail(R, string.format("有 %d 个（帧, 怪）该读 C 却没读（结果在跟踪中就每帧都读，V16 第 2.2 节）", miss)) end
    end
end

-- ---------- 合并模式（docs/autoparry/MERGE.md 第 6 节） ----------

-- 合并版 HDR 的 host 字段：标明是哪个脚本写的放刀记录（MERGE 第 1.1 节：ver 仍是放刀规则的版本 1.6）
local MERGED_HOST = "AutoGuardGS-v1.5"
-- 菜单操作的别名（MERGE 第 6.2 节第 2 条）：菜单按「标签包含这段文字」匹配，合并后只写「启用」会先匹配到防御的启用开关，
-- 所以一律改成带 ID 的写法
local MERGED_UI_MATCH = { ["启用"] = "##ap_enabled", ["提前量"] = "##ap_lead", ["清零统计"] = "##reset_stats",
    ["调试日志"] = "##debug_log" }
local PARRY_RULE = { ver = "1.6", rule = "E5c", filter = "g1", c_lo = "0.50", c_hi = "2.00", L_min = "22", W_long = "60",
    H_veto = "90", credit = "1.3" }
local NCHARGE = { [5] = true, [6] = true, [7] = true, [11] = true }

local function round4(v) return math.floor(v * 10000 + 0.5) / 10000 end
-- 脚本在某个模拟时刻、某个阶段读到的 os.clock（日志里 %.4f 的写法）
local function clk4(w, t, phase) return string.format("%.4f", round4(w.clock_base + t + (w.phase_offset[phase] or 0.0))) end
local function finite_n(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function clamp_lead(v) return math.max(23, math.min(45, math.floor(v + 0.5))) end

-- 防御部分的配置：和 v1.4.2 的 load_config 同一口径（MERGE 第 3.2 节：已有 8 个键的读法一字不差）
local GUARD_DEFAULTS = { enabled = true, guard_type = 1, respect_armor = true, auto_tackle = true, infinite_charge = false,
    lock_health = false, debug_log = false }
local GUARD_KEYS8 = { "enabled", "guard_type", "guard_angle", "respect_armor", "auto_tackle", "infinite_charge",
    "lock_health", "debug_log" }
local function guard_cfg_from(tbl)
    local c = {}
    for k, v in pairs(GUARD_DEFAULTS) do c[k] = v end
    if type(tbl) ~= "table" then return c end
    for k, v in pairs(tbl) do
        if k == "guard_angle" then
            if type(v) == "number" then c.guard_angle = math.max(30.0, math.min(360.0, v)) end
        elseif k == "guard_type" then
            if v == 1 or v == 2 then c.guard_type = v end
        elseif GUARD_DEFAULTS[k] ~= nil and type(v) == type(GUARD_DEFAULTS[k]) then
            c[k] = v
        end
    end
    return c
end

-- 合并版加载后的放刀配置（MERGE 第 3.2、3.3 节）：AutoGuardGS.json 里有 auto_parry 或 parry_lead 任意一个键，就是合并版自己的
-- 配置、不看旧文件；两个都没有才从旧 AutoParryGS.json 迁移（auto_parry 是布尔就照搬；cfg_ver 是 ≥3 的数、parry_lead 是有限数
-- 才沿用提前量，否则 28）。返回 cfg、要不要在加载时写回（迁移、旧文件读出来是表、并且 AutoGuardGS.json 本身读出了表：
-- 文件不存在或读不出来时只在内存里迁，审查修订）
local function merged_parry_cfg(gtbl, old_tbl)
    local c = { auto_parry = true, parry_lead = 28 }
    if type(gtbl) == "table" and (gtbl.auto_parry ~= nil or gtbl.parry_lead ~= nil) then
        if type(gtbl.auto_parry) == "boolean" then c.auto_parry = gtbl.auto_parry end
        if finite_n(gtbl.parry_lead) then c.parry_lead = clamp_lead(gtbl.parry_lead) end
        return c, false
    end
    if type(old_tbl) == "table" then
        if type(old_tbl.auto_parry) == "boolean" then c.auto_parry = old_tbl.auto_parry end
        local cv = old_tbl.cfg_ver
        if type(cv) == "number" and cv >= 3 and finite_n(old_tbl.parry_lead) then c.parry_lead = clamp_lead(old_tbl.parry_lead) end
        return c, type(gtbl) == "table"
    end
    return c, false
end

-- 某个配置开关随时间的值：加载时的值，之后按菜单操作（被这个脚本处理的时刻）更新。返回 at(t, phase)：
-- 帧开头 / 钩子里（UI 阶段之前）看到的是上一次 UI 阶段之前的改动；Reset 阶段看到全部改动
local function cfg_timeline(w, script, init, match)
    local list = {}
    for _, a in ipairs(w.ui_actions) do
        if a.kind == "checkbox" and a.match and a.match:find(match, 1, true) and a.done and a.done[script] then
            list[#list + 1] = { t = a.done[script], v = a.value == true }
        end
    end
    table.sort(list, function(x, y) return x.t < y.t end)
    return function(t, phase)
        local v = init
        for _, c in ipairs(list) do
            if c.t < t - 1e-9 or (phase == "reset" and c.t <= t + 1e-9) then v = c.v end
        end
        return v
    end, list
end

-- 合并模式改写场景（别名，MERGE 第 6.2 节第 2 条）
local function merged_transform(sc, V, R)
    local function alias(tbl)
        if type(tbl) == "table" and tbl.AutoParryGS then
            tbl.AutoParryGS = nil
            tbl.AutoGuardGS = true
        end
    end
    for _, f in ipairs(sc.faults or {}) do alias(f.scripts) end
    for _, M in pairs(sc.monsters or {}) do for _, f in ipairs(M.speed_fault or {}) do alias(f.scripts) end end
    for _, A in ipairs(sc.attacks or {}) do for _, f in ipairs(A.speed_fault or {}) do alias(f.scripts) end end
    local ui = {}
    for _, a in ipairs(sc.ui or {}) do
        local keep = true
        if a.script == "AutoParryGS" then
            if a.match == "写出数据" then
                keep = false
                info(R, string.format("合并模式：丢掉菜单操作「写出数据」（t=%.2f；合并版不写 JSON，MERGE 第 6.2 节第 2 条）", a.t))
            else
                a.script = "AutoGuardGS"
                a.match = MERGED_UI_MATCH[a.match] or a.match
            end
        end
        if keep then ui[#ui + 1] = a end
    end
    sc.ui = ui
    for _, rp in ipairs(sc.expect.release_all_at or {}) do
        if rp.script == "AutoParryGS" then rp.script = "AutoGuardGS" end
    end
    local arm = sc.expect.add_ref_min
    if arm and arm.AutoParryGS then arm.AutoGuardGS, arm.AutoParryGS = arm.AutoParryGS, nil end
    sc.config = sc.config or {}
    -- 旧的 AutoParryGS.json 原样写（走迁移）；AutoGuardGS.json 只有这一组的调试日志开关，没有 auto_parry / parry_lead，
    -- 好让迁移路径一定被走到
    sc.config.AutoGuardGS = { debug_log = V.debug == true }
end

-- 主角动作文本 "(c,i)" → 数字
local function act_of(s)
    local c, i = tostring(s or ""):match("^%((%-?%d+),(%-?%d+)%)$")
    return tonumber(c), tonumber(i)
end
local function in_parry_family(s)
    local c, i = act_of(s)
    return c == 2 and i ~= nil and i >= 21 and i <= 29
end

-- 防御副作用轨迹（MERGE 第 6.5 节：6.2 第 4 条的表里除 (2,23) 请求之外的各项）：一行一个，带帧号、阶段、所在钩子
local function hook_short(k)
    if not k then return "" end
    return " " .. (k:match("%.([%w_]+)%(") or k)
end
local function guard_trace(w, script)
    local T = {}
    for _, e in ipairs(w.effects) do
        if e.script == script then
            local d
            if e.kind == "call" and e.name == "changeActionRequest" then
                local id = e.args[2] or ""
                local c, i = id:match("_Category=(%-?%d+)"), id:match("_Index=(%-?%d+)")
                if not (c == "2" and (i == "23" or i == "24")) then
                    d = string.format("request (%s,%s) layer=%s flag=%s", tostring(c), tostring(i), tostring(e.args[1]),
                        tostring(e.args[3]))
                end
            elseif e.kind == "call" and e.type == "ace.cSafeContinueFlagGroup" then
                d = e.name .. " " .. w:enum_name("app.HunterDef.STATUS_FLAG", tonumber(e.args[1]))
            elseif e.kind == "set_field" then
                d = "set " .. e.type:gsub("^app%.user_data%.", "") .. "." .. e.name .. "=" .. tostring(e.args[1])
            elseif e.kind == "skip_original" then
                d = "skip" .. hook_short(e.name)
            elseif e.kind == "call" then
                d = "call " .. e.type .. "." .. e.name .. "(" .. table.concat(e.args or {}, ",") .. ")"
            else
                d = e.kind .. " " .. tostring(e.name)
            end
            if d then
                T[#T + 1] = { frame = e.frame, t = e.t, phase = e.phase, hook = e.hook, stage = e.stage, act = e.act,
                    text = string.format("f%d %s%s%s %s", e.frame, e.phase, hook_short(e.hook), e.stage and ("/" .. e.stage) or "",
                        d) }
            end
        end
    end
    return T
end

-- 菜单（最后一次画的内容）里防御那一节的计数（v1.4.2 原样的两行，锁血开着时多一个「已拦下扣血」）
local function guard_counts(menu)
    local c = {}
    for _, l in ipairs(menu or {}) do
        c.guarded = c.guarded or tonumber(l:match("自动防御：(%d+) 次"))
        c.tackled = c.tackled or tonumber(l:match("自动肩撞：(%d+) 次"))
        c.already = c.already or tonumber(l:match("本来就在防御：(%d+) 次"))
        c.armor = c.armor or tonumber(l:match("跳过：霸体 (%d+) 次"))
        c.state = c.state or tonumber(l:match("不能举剑（翻滚、收刀、硬直等）(%d+) 次"))
        c.blocked = c.blocked or tonumber(l:match("已拦下扣血 (%d+) 次"))
    end
    return c
end

-- 放刀一节的计数（MERGE 第 5.1 节：放了 n 刀、接住 n 刀（26：n，27：n）、被弹开 n 次、没接住 n 次）
local function parry_counts(menu)
    for _, l in ipairs(menu or {}) do
        if l:find("放了", 1, true) and l:find("没接住", 1, true) then
            local c = {
                fires = tonumber(l:match("放了%s*(%d+)%s*刀")),
                -- 全角冒号是 3 个字节，不能放进 Lua 模式的字符类里
                c26 = tonumber(l:match("26%s*：%s*(%d+)") or l:match("26%s*:%s*(%d+)")),
                c27 = tonumber(l:match("27%s*：%s*(%d+)") or l:match("27%s*:%s*(%d+)")),
                recoil = tonumber(l:match("被弹开%s*(%d+)%s*次")),
                nocatch = tonumber(l:match("没接住%s*(%d+)%s*次")),
            }
            c.catch = tonumber(l:match("接住%s*(%d+)%s*刀"))
            c.line = l
            return c
        end
    end
    return nil
end

-- 放刀状态行归一化（MERGE 第 6.3 节）：去掉「版本 1.6  」前缀和「状态：」，去掉带数字的括号，拆成条目集合
local function status_items(line)
    if not line then return nil end
    local s = line:gsub("^.-状态：", "")
    -- 去掉带数字的全角括号（「（读取错误 3）」「（6 个预告没放刀）」「（黄 1）」）。全角括号是多字节字符，不能写进 Lua 模式的
    -- 字符类（[^（）] 会按字节排除，括号里的汉字可能正好含这些字节），这里按纯文本逐对找
    local out, pos = {}, 1
    while true do
        local a = s:find("（", pos, true)
        local b = a and s:find("）", a + 3, true)
        if not a or not b then
            out[#out + 1] = s:sub(pos)
            break
        end
        local inner = s:sub(a + 3, b - 1)
        out[#out + 1] = s:sub(pos, a - 1)
        if not inner:find("%d") then out[#out + 1] = s:sub(a, b + 2) end
        pos = b + 3
    end
    s = table.concat(out)
    local set, list = {}, {}
    for item in (s .. "；"):gmatch("(.-)；") do
        item = item:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" and not set[item] then
            set[item] = true
            list[#list + 1] = item
        end
    end
    table.sort(list)
    return table.concat(list, " | ")
end
local GUARD_STATUS_HINTS = { "已拦下扣血", "拿起大剑后生效", "NPC 支援猎人", "进入任务后生效" }
local function parry_status_line(menu, a0)
    for _, l in ipairs(menu or {}) do
        if a0 then
            if l:find("版本 1.6  状态：", 1, true) then return l end
        elseif l:match("^状态：") then
            local guard = false
            for _, h in ipairs(GUARD_STATUS_HINTS) do if l:find(h, 1, true) then guard = true end end
            if not guard then return l end
        end
    end
    return nil
end

-- 一次跑法的「轨迹」（MERGE 第 6.3 节的表）：请求序列、FIRE / RES、计数、RED、错误、状态行、引用记账
local function extract_trace(R, sc, w, G, P, all_records)
    local T = { req = {}, fire = {}, res = {}, fire_end = {}, red = {}, err = {}, ver = CUR_VER }
    local rc = HAS.rc
    if not rc then return T end
    for _, q in ipairs(w.requests) do
        if q.script == rc.name and q.cat == 2 and (q.idx == 23 or q.idx == 24) then
            T.req[#T.req + 1] = string.format("f%d t=%s (2,%d) %s", q.frame, clk4(w, q.t, q.phase), q.idx,
                q.accepted and "接受" or ("拒绝:" .. tostring(q.reason)))
        end
    end
    for _, r in ipairs(lines(P, "AutoParryGS", "FIRE")) do T.fire[r.f.id or "?"] = r end
    for _, r in ipairs(lines(P, "AutoParryGS", "RES")) do T.res[r.f.id or "?"] = r end
    for _, r in ipairs(lines(P, "AutoParryGS", "FIRE_END")) do T.fire_end[r.f.id or "?"] = r.f.entered end
    for _, r in ipairs(lines(P, "AutoParryGS", "RED")) do
        if r.f.mod ~= "json" then
            T.red[#T.red + 1] = string.format("t=%s mod=%s why=%s", tostring(r.f.t), tostring(r.f.mod), tostring(r.f.why))
        end
    end
    -- 错误：合并版 = 日志行（每次加载前 20 条出错时立刻写）的模拟时刻；A0 = JSON 里的 ERR（发生时刻是补写的 t）。
    -- A0 的最后一份 JSON 写失败时（v15_reset_json）JSON 缺尾巴，用日志行补上 mod / level（时刻不明，比的时候跳过时刻）
    if CUR_VER == "merged" then
        for _, r in ipairs(lines(P, "AutoParryGS", "ERR")) do
            T.err[#T.err + 1] = { mod = r.f.mod, level = r.f.level, t = clk4(w, r.t, r.phase) }
        end
    else
        for _, r in ipairs((all_records and all_records.AutoParryGS) or {}) do
            if r.k == "ERR" then
                T.err[#T.err + 1] = { mod = tostring(r.mod), level = tostring(r.level),
                    t = string.format("%.4f", round4(tonumber(r.t) or -1)) }
            end
        end
        local lg = lines(P, "AutoParryGS", "ERR")
        for i = #T.err + 1, #lg do T.err[i] = { mod = lg[i].f.mod, level = lg[i].f.level, t = "?" } end
    end
    -- 计数：合并版取场景结束时的菜单；A0 从记录推算（清零统计之后、Reset 之前的记录）
    local menu = w.menu[rc.name] or {}
    if CUR_VER == "merged" then
        T.counts = parry_counts(menu)
        T.status = status_items(parry_status_line(menu, false))
    else
        local t_clear = rc_clear_time(w, rc.name)
        local c = { fires = 0, c26 = 0, c27 = 0, recoil = 0, nocatch = 0 }
        for _, r in ipairs(lines(P, "AutoParryGS", "FIRE")) do
            if not t_clear or r.t > t_clear + 1e-9 then c.fires = c.fires + 1 end
        end
        for _, r in ipairs(lines(P, "AutoParryGS", "RES")) do
            if r.phase ~= "reset" and (not t_clear or r.t > t_clear + 1e-9) then
                local oc = r.f.outcome
                if oc == "CATCH26" then c.c26 = c.c26 + 1 elseif oc == "CATCH27" then c.c27 = c.c27 + 1
                elseif oc == "RECOIL" then c.recoil = c.recoil + 1 elseif oc == "NOCATCH" then c.nocatch = c.nocatch + 1 end
            end
        end
        c.catch = c.c26 + c.c27
        T.counts = c
        T.status = status_items(parry_status_line(menu, true))
    end
    local rcn = w.ref_counts[rc.name] or {}
    local dead = 0
    for _, v in ipairs(w.violations) do if v.kind == "DEAD_OBJECT" and v.script == rc.name then dead = dead + v.count end end
    T.refs = { manual = rcn.MANUAL_RELEASE or 0, over = rcn.OVER_RELEASE or 0, dead = dead }
    return T
end

-- B / C 对 A0 的逐项比较（MERGE 第 6.3 节）。返回差异列表（空 = 一致）
local FIRE_CMP = { "t", "L", "R0", "he0", "ent", "res", "em", "keep", "from", "C1", "Cf", "mf", "nchg", "dX", "A0", "Q0" }
local RES_CMP = { "t", "outcome", "dt", "to" }
local function compare_trace(A, X, label, full)
    local d = {}
    local function add(msg) d[#d + 1] = label .. "：" .. msg end
    -- 请求序列
    local n = math.max(#A.req, #X.req)
    local shown = 0
    for i = 1, n do
        if A.req[i] ~= X.req[i] then
            shown = shown + 1
            if shown <= 5 then add(string.format("请求序列第 %d 项：A0 %s ；%s %s", i, tostring(A.req[i]), label, tostring(X.req[i]))) end
        end
    end
    if shown > 5 then add(string.format("……请求序列另有 %d 项不同", shown - 5)) end
    if #A.req ~= #X.req then add(string.format("请求 %d 次，A0 %d 次", #X.req, #A.req)) end
    if full then
        -- FIRE / RES（只比 B：调试日志开着才写）
        local ids = {}
        for id in pairs(A.fire) do ids[#ids + 1] = id end
        for id in pairs(X.fire) do if not A.fire[id] then ids[#ids + 1] = id end end
        table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
        for _, id in ipairs(ids) do
            local a, x = A.fire[id], X.fire[id]
            if not a then add("FIRE id=" .. id .. " A0 没有")
            elseif not x then add("FIRE id=" .. id .. " 没写（A0 有）：" .. a.text:sub(1, 120))
            else
                for _, k in ipairs(FIRE_CMP) do
                    if a.f[k] ~= x.f[k] then add(string.format("FIRE id=%s 的 %s：A0 %s，%s %s", id, k, tostring(a.f[k]), label, tostring(x.f[k]))) end
                end
            end
            local ar, xr = A.res[id], X.res[id]
            if ar and not xr then add("RES id=" .. id .. " 没写（A0 有）：" .. ar.text:sub(1, 120))
            elseif xr and not ar then add("RES id=" .. id .. " A0 没有：" .. xr.text:sub(1, 120))
            elseif ar and xr then
                for _, k in ipairs(RES_CMP) do
                    if ar.f[k] ~= xr.f[k] then add(string.format("RES id=%s 的 %s：A0 %s，%s %s", id, k, tostring(ar.f[k]), label, tostring(xr.f[k]))) end
                end
                local want = A.fire_end[id]
                if xr.f.entered ~= want then
                    add(string.format("RES id=%s 的 entered=%s，A0 那一刀 FIRE_END 的 entered=%s", id, tostring(xr.f.entered), tostring(want)))
                end
            end
        end
    end
    -- 计数
    local ca, cx = A.counts or {}, X.counts
    if not cx then
        add("菜单里找不到放刀计数那一行（放了 n 刀 … 没接住 n 次）")
    else
        for _, k in ipairs({ "fires", "catch", "c26", "c27", "recoil", "nocatch" }) do
            if ca[k] ~= cx[k] then add(string.format("计数 %s：A0 推算 %s，%s 菜单 %s（%s）", k, tostring(ca[k]), label, tostring(cx[k]), cx.line or "")) end
        end
    end
    -- RED
    if table.concat(A.red, " / ") ~= table.concat(X.red, " / ") then
        add("RED：A0 [" .. table.concat(A.red, " / ") .. "]，" .. label .. " [" .. table.concat(X.red, " / ") .. "]")
    end
    -- 错误：去掉 json、cfg 两个模块后逐条比（合并版日志只有前 20 条，其中 cfg 占的位置不算）
    local a_err, x_err, x_cfg = {}, {}, 0
    for _, e in ipairs(A.err) do if e.mod ~= "json" and e.mod ~= "cfg" then a_err[#a_err + 1] = e end end
    for _, e in ipairs(X.err) do
        if e.mod == "cfg" then x_cfg = x_cfg + 1 elseif e.mod ~= "json" then x_err[#x_err + 1] = e end
    end
    local want_n = math.min(#a_err, 20 - x_cfg)
    if #x_err ~= want_n then add(string.format("错误 %d 条（不算 json / cfg），A0 前 %d 条", #x_err, want_n)) end
    for i = 1, math.min(#x_err, #a_err) do
        local a, x = a_err[i], x_err[i]
        if a.mod ~= x.mod or a.level ~= x.level or (a.t ~= "?" and a.t ~= x.t) then
            add(string.format("第 %d 条错误：A0 mod=%s level=%s t=%s，%s mod=%s level=%s t=%s", i, a.mod, a.level, a.t, label, x.mod, x.level, x.t))
            break
        end
    end
    -- 状态行
    if A.status ~= X.status then add("状态行：A0「" .. tostring(A.status) .. "」，" .. label .. "「" .. tostring(X.status) .. "」") end
    -- 引用记账：三组都是 0
    for _, k in ipairs({ "manual", "over", "dead" }) do
        if (X.refs or {})[k] ~= 0 then add("引用记账 " .. k .. "=" .. tostring((X.refs or {})[k])) end
    end
    return d
end

-- ---------- 合并版 / 归档 v1.4.2 每次跑都查的断言（MERGE 第 6.2 节第 4 条） ----------

local RED_TEXT_M = "出错了：请把 re2_framework_log.txt 发给开发者，然后 Reset Scripts"

-- 日志：[AutoParryGS] 只有 HDR、FIRE、RES、ERR、RED，字段按 4.2；HDR 每次加载至多一行、在第一行别的 [AutoParryGS] 行之前；
-- 调试日志关着的时段没有 FIRE / RES；ERR 每次加载不超过 20 行；[AutoGuardGS] 行不解析，只查 FMT_ERR
local function check_logs_merged(R, sc, w, G, P, ctx)
    for i, l in ipairs(P.fmt_err) do
        if i > 5 then break end
        fail(R, "日志里有 FMT_ERR（string.format 出错）: " .. l.text)
    end
    if not HAS.rc then
        -- 归档的 v1.4.2：不写放刀记录
        for _, l in ipairs(w.logs) do
            if l.text:find("[AutoParryGS]", 1, true) then
                fail(R, "防御参照组（v1.4.2 单独加载）写了 [AutoParryGS] 行：" .. l.text:sub(1, 120))
                break
            end
        end
        return
    end
    local recs = {}
    for _, r in ipairs(P.list) do if r.tag == "AutoParryGS" then recs[#recs + 1] = r end end
    if #P.unstructured > 0 then
        fail(R, string.format("%d 行 [AutoParryGS] 不是「[TAG] KIND k=v」格式，例如：%s", #P.unstructured,
            P.unstructured[1].text:sub(1, 120)))
    end
    local seen = {}
    local function once(key, msg)
        if not seen[key] then
            seen[key] = true
            fail(R, msg)
        end
    end
    local BOOLS = { HDR = { "auto_parry" }, RES = { "entered" } }
    for _, r in ipairs(recs) do
        local spec = MERGED_KINDS[r.kind]
        if not spec then
            once("kind" .. r.kind, "合并版写了 [AutoParryGS] " .. r.kind .. " 行（只许 HDR、FIRE、RES、ERR、RED，MERGE 第 4.1 节）："
                .. r.text:sub(1, 140))
        else
            if r.bad then once("bad" .. r.kind, "[AutoParryGS] " .. r.kind .. " 有不是 k=v 的片段「" .. r.bad .. "」：" .. r.text:sub(1, 140)) end
            if table.concat(r.order, " ") ~= table.concat(spec, " ") then
                once("order" .. r.kind, string.format("[AutoParryGS] %s 的字段是「%s」，MERGE 第 4.2 节是「%s」", r.kind,
                    table.concat(r.order, " "), table.concat(spec, " ")))
            end
            for _, b in ipairs(BOOLS[r.kind] or {}) do
                local v = r.f[b]
                if v and v ~= "0" and v ~= "1" and v ~= "-" then once("bool" .. r.kind .. b, string.format("[AutoParryGS] %s 的 %s=%s，布尔要写 1/0", r.kind, b, v)) end
            end
            if r.f.t and not tonumber(r.f.t) and r.f.t ~= "-" then once("t" .. r.kind, "[AutoParryGS] " .. r.kind .. " 的 t 不是数字：" .. r.text:sub(1, 120)) end
        end
    end
    local hdrs = lines(P, "AutoParryGS", "HDR")
    if #hdrs > 1 then fail(R, string.format("每次加载 HDR 至多一行（第一次写放刀记录之前补写），实际 %d 行", #hdrs)) end
    local first_other
    for i, r in ipairs(recs) do
        if r.kind ~= "HDR" then
            first_other = i
            break
        end
    end
    if first_other then
        if #hdrs == 0 then
            fail(R, "有别的 [AutoParryGS] 行却没有 HDR（分析脚本按最近的 HDR 划 session，MERGE 第 4.1 节）")
        elseif recs[1].kind ~= "HDR" then
            fail(R, "HDR 不在第一行别的 [AutoParryGS] 行之前：" .. recs[1].text:sub(1, 120))
        end
    end
    -- 调试日志的开关随时间：关着的时段不许有 FIRE / RES；加载时就开着的话 HDR 在加载那一刻写
    local bad_dbg = 0
    for _, r in ipairs(recs) do
        if (r.kind == "FIRE" or r.kind == "RES") and not ctx.debug_at(r.t, r.phase) then
            bad_dbg = bad_dbg + 1
            if bad_dbg == 1 then fail(R, string.format("调试日志关着（t=%.2f）却写了 %s：%s", r.t, r.kind, r.text:sub(1, 120))) end
        end
    end
    if ctx.debug_at(0.0, "load") then
        if #hdrs == 0 then fail(R, "调试日志加载时就开着，却没有在加载时写 HDR（MERGE 第 4.1 节）")
        elseif hdrs[1].phase ~= "load" then fail(R, "调试日志加载时就开着，HDR 却不是加载时写的（t=" .. hdrs[1].t .. "）") end
    end
    local nerr = #lines(P, "AutoParryGS", "ERR")
    if nerr > 20 then fail(R, string.format("[AutoParryGS] ERR %d 行，每次加载最多 20 行（MERGE 第 2.1 节）", nerr)) end
    local h = hdrs[1]
    if h then
        for k, v in pairs(PARRY_RULE) do
            if h.f[k] ~= v then fail(R, string.format("合并版 HDR 的 %s=%s，应为 %s（放刀规则仍记 1.6，MERGE 第 1.1、4.2 节）", k, tostring(h.f[k]), v)) end
        end
        if h.f.host ~= MERGED_HOST then fail(R, "合并版 HDR 的 host=" .. tostring(h.f.host) .. "，应为 " .. MERGED_HOST) end
        if not tonumber(h.f.session or "") then fail(R, "合并版 HDR 的 session 不是数字：" .. tostring(h.f.session)) end
        local want = {}
        for _, n in ipairs({ "CATCH", "CATCH_ZAKO", "CATCH_SLINGER" }) do
            if w.missing["field:app.HitDef.DAMAGE_TYPE." .. n] then want[#want + 1] = n end
        end
        for _, n in ipairs({ "UNABLE_GUARD", "SKILL_GUARD", "SKILL_GUARD_ALL_RANGE" }) do
            if w.missing["field:app.Hit.GUARD_TYPE." .. n] then want[#want + 1] = n end
        end
        local got = {}
        for x in tostring(h.f.enum_skip or ""):gmatch("[^,]+") do if x ~= "-" then got[#got + 1] = x end end
        table.sort(want)
        table.sort(got)
        if table.concat(got, ",") ~= table.concat(want, ",") then
            fail(R, string.format("HDR 的 enum_skip=%s，加载时没读到的抓取名 / 黑名单名是 %s（都读到写 -）", tostring(h.f.enum_skip),
                #want > 0 and table.concat(want, ",") or "-"))
        end
        local ap, L = ctx.parry_at(h.t, h.phase)
        if h.f.auto_parry ~= (ap and "1" or "0") or h.f.lead ~= tostring(L) then
            fail(R, string.format("HDR 的 auto_parry=%s lead=%s，写 HDR 那一刻的配置是 %s / %d（MERGE 第 4.1 节）", tostring(h.f.auto_parry),
                tostring(h.f.lead), ap and "1" or "0", L))
        end
    end
    -- 日志量：放刀记录只剩关键事件（同 v1.5 起的发布版，平均 ≤5 行/秒）
    local n = #recs
    local dur = math.max(1.0, w.t)
    if n / dur > 5.0 then fail(R, string.format("[AutoParryGS] 日志平均 %.2f 行/秒，超过 5 行/秒", n / dur)) end
    info(R, string.format("[AutoParryGS] %d 行（HDR %d、FIRE %d、RES %d、ERR %d、RED %d）", n, #hdrs, #lines(P, "AutoParryGS", "FIRE"),
        #lines(P, "AutoParryGS", "RES"), nerr, #lines(P, "AutoParryGS", "RED")))
end

-- 钩子：合并版恰好 5 个（v1.4.2 恰好 4 个），每个只钩一次；场景声明 hooks_partial（初始化失败）时只要求是子集
local function check_hooks_merged(R, sc, w)
    local s = HAS.rc or HAS.guard
    if not s then return end
    local want = HAS.rc and MERGED_HOOKS or GUARD_HOOKS
    local allowed, got, n = {}, {}, {}
    for _, k in ipairs(want) do allowed[k] = true end
    for _, h in ipairs(w.hook_regs) do
        if h.script == s.name then
            n[h.key] = (n[h.key] or 0) + 1
            if not allowed[h.key] then fail(R, s.name .. " 钩了白名单以外的函数：" .. h.key) end
            got[h.key] = true
        end
    end
    for k, c in pairs(n) do if c > 1 then fail(R, string.format("%s 把 %s 钩了 %d 次", s.name, k, c)) end end
    if not (sc.mexpect and sc.mexpect.hooks_partial) then
        for _, k in ipairs(want) do
            if not got[k] then fail(R, s.name .. " 没有钩 " .. k .. "（" .. (HAS.rc and "合并版恰好 5 个" or "v1.4.2 恰好 4 个") .. "）") end
        end
    end
end

-- 副作用白名单（MERGE 第 6.2 节第 4 条的表），按调用参数归属到放刀或防御；探针一个都不许有；同一帧最多一个 changeActionRequest
local function check_effects_merged(R, sc, w, G, ctx)
    local s = HAS.rc or HAS.guard
    local probe = HAS.probe and HAS.probe.name
    local bad, order = {}, {}
    local function nope(e, why)
        if not bad[why] then
            bad[why] = { e = e, n = 0 }
            order[#order + 1] = why
        end
        bad[why].n = bad[why].n + 1
    end
    local per_frame = {}
    -- 无限蓄力「该不该生效」随帧的变化：开关开、主角在、拿大剑（v1.4.2 的帧回调原样）。_OverheatTime 只在它变的那一帧、Reset 时改
    local function desired(fr)
        local o = G.oracle[fr]
        if not o then return false end
        return ctx.inf_at(o.t, "pre") and o.present ~= false and (o.wtype or 0) == 0
    end
    for _, e in ipairs(w.effects) do
        if probe and e.script == probe then
            nope(e, string.format("探针有副作用调用 %s %s.%s", e.kind, e.type, e.name))
        elseif s and e.script == s.name then
            local snap = G.oracle[e.frame]
            local scat, sidx = snap and snap.cat, snap and snap.idx
            if e.kind == "call" and e.type == "app.HunterCharacter" and e.name == "changeActionRequest" then
                per_frame[e.frame] = (per_frame[e.frame] or 0) + 1
                local id = e.args[2] or ""
                local c, i = tonumber(id:match("_Category=(%-?%d+)")), tonumber(id:match("_Index=(%-?%d+)"))
                if e.phase ~= "pre" or e.hook then
                    nope(e, "changeActionRequest 不在帧开头（pre-UpdateBehavior）")
                elseif e.args[1] ~= "0" or e.args[3] ~= "false" then
                    nope(e, "changeActionRequest 的参数不是 (0, ID, false)：" .. table.concat(e.args, ","))
                elseif c == 2 and i == 23 then
                    if not HAS.rc then nope(e, "防御参照组请求了 (2,23)") end
                    if not (scat == 2 and (sidx == 21 or sidx == 22)) then
                        nope(e, "请求 (2,23) 时帧开头的快照不在 (2,21)/(2,22)")
                    end
                elseif c == 2 and (i == 15 or i == 17) then
                    local pending = false
                    for _, h in ipairs(G.truth.body_hits or {}) do
                        local hc, hi = act_of(h.act)
                        if hc == 2 and NCHARGE[hi] and h.t < e.t + 1e-9 and h.t >= e.t - 0.35 then pending = true end
                    end
                    if not (scat == 2 and NCHARGE[sidx]) then
                        nope(e, "请求肩撞时帧开头的快照不在普通蓄力 (2,5)/(2,6)/(2,7)/(2,11)")
                    elseif not pending then
                        nope(e, "请求肩撞，可之前 0.35 s 内没有蓄力中挨打（没有肩撞请求在等）")
                    end
                else
                    nope(e, string.format("请求了白名单以外的动作 (%s,%s)", tostring(c), tostring(i)))
                end
            elseif e.kind == "call" and e.type == "ace.cSafeContinueFlagGroup" and (e.name == "on" or e.name == "off") then
                local fname = w:enum_name("app.HunterDef.STATUS_FLAG", tonumber(e.args[1]))
                if e.name == "on" then
                    if fname ~= "GUARD" and fname ~= "TECHNICAL_GUARD" then
                        nope(e, "强开了防御以外的状态标志 " .. fname)
                    elseif not (e.hook == HK_PRE and e.stage == "pre") then
                        nope(e, "FlagGroup.on 不在受击前置钩子里")
                    end
                elseif not ((e.phase == "pre" and not e.hook) or e.phase == "reset" or (e.hook == HK_DMG and e.stage == "post")
                    or (e.hook == HK_PRE and e.stage == "pre")) then
                    nope(e, "FlagGroup.off 不在受击后置钩子 / 帧开头 / Reset 里")
                end
            elseif e.kind == "set_field" and e.type == "app.user_data.Wp00ActionParam"
                and (e.name == "_GuardDegree" or e.name == "_AimGuardDegree") then
                if not ((e.phase == "pre" and not e.hook) or e.phase == "reset" or (e.hook == HK_DMG and e.stage == "post")
                    or (e.hook == HK_PRE and e.stage == "pre")) then
                    nope(e, "防御角度不在受击钩子 / 帧开头 / Reset 里改")
                elseif e.hook == HK_PRE and e.stage == "pre" and in_parry_family(e.act) then
                    -- v1.4.1：抵消动作族里不改写（按钩子那一刻现读的动作判断，不是帧开头的快照）
                    nope(e, "受击时主角在抵消动作族 (2,21)~(2,29)（" .. tostring(e.act) .. "），却改写了防御角度")
                end
            elseif e.kind == "set_field" and e.type == "app.user_data.Wp00ActionParam.cCharge" and e.name == "_OverheatTime" then
                if e.phase == "reset" then
                    -- Reset 时还原：允许
                elseif not (e.phase == "pre" and not e.hook) then
                    nope(e, "_OverheatTime 不在帧开头 / Reset 里改")
                elseif desired(e.frame) == desired(e.frame - 1) then
                    nope(e, "_OverheatTime 在无限蓄力「该不该生效」没变的帧里被改（只在开关切换、主角消失、换武器、Reset 时改）")
                end
            elseif e.kind == "call" and e.type == "app.cHealthManager" and e.name == "set_Health" then
                if not ctx.lock_at(e.t, e.phase) then nope(e, "锁血关着却调了 set_Health") end
            elseif e.kind == "skip_original" then
                if e.name ~= HK_REQ and e.name ~= HK_RED then
                    nope(e, "钩子跳过了锁血以外的原函数 " .. tostring(e.name))
                elseif not ctx.lock_at(e.t, e.phase) then
                    nope(e, "锁血关着却跳过了 " .. tostring(e.name))
                elseif not (G.master_healths or {})[e.target] then
                    nope(e, "锁血跳过了不是主玩家的扣血（" .. tostring(e.target) .. "，同场 NPC 的照常扣）")
                end
            else
                nope(e, string.format("白名单以外的副作用 %s %s.%s", e.kind, e.type, e.name))
            end
        elseif e.script:sub(1, 5) == "hook@" then
            nope(e, "钩子参数被改写：" .. tostring(e.name))
        end
    end
    for _, why in ipairs(order) do
        local b = bad[why]
        local e = b.e
        fail(R, string.format("%s（%d 次，首次 t=%.3f f%d %s%s，参数 %s）", why, b.n, e.t, e.frame, e.phase,
            e.hook and (" " .. hook_short(e.hook) .. "/" .. tostring(e.stage)) or "", table.concat(e.args or {}, ",")))
    end
    local over = 0
    for fr, n in pairs(per_frame) do if n > 1 then over = over + 1 end end
    if over > 0 then fail(R, string.format("有 %d 帧同一帧发了不止一个 changeActionRequest（MERGE 第 1.4 节：同一帧最多一个）", over)) end
end

-- 文件（MERGE 第 6.2 节第 4 条「文件」、第 3 节）
local function check_files_merged(R, sc, w, G, ctx)
    local s = HAS.rc or HAS.guard
    if not s then return end
    for _, j in ipairs(w.json_writes) do
        if j.script == s.name and j.path:match("^AutoParryGS_") then
            fail(R, "写了放刀数据文件 " .. j.path .. "（合并版不写 JSON，MERGE 第 2.1 节）")
            break
        end
    end
    for _, f in ipairs(list_dir(w.out_dir)) do
        if f:match("^AutoParryGS_%d+_%d+%.json$") then
            fail(R, "输出目录里有放刀数据文件 " .. f)
            break
        end
    end
    local seed = R.seed_text["AutoParryGS.json"]
    local now = w:read_file("AutoParryGS.json")
    if seed and now ~= seed then fail(R, "旧配置 AutoParryGS.json 的内容变了（只读、不改、不删，回滚时 v1.6 还要读，MERGE 第 3.3 节）") end
    if not seed and now then fail(R, "写出了 AutoParryGS.json（合并版只有 AutoGuardGS.json 一个配置文件）") end
    for _, j in ipairs(w.json_writes) do
        if j.path == "AutoParryGS.json" then
            fail(R, s.name .. " 写了 AutoParryGS.json")
            break
        end
    end
    if not HAS.rc then return end
    -- 这次加载读 AutoGuardGS.json 抛错：加载时、存配置时都不许写它（内存里是默认值，写了就盖掉原文件；审查修订）
    if ctx.cfg_unreadable then
        for _, j in ipairs(w.json_writes) do
            if j.script == s.name and j.path == "AutoGuardGS.json" then
                fail(R, string.format("读 AutoGuardGS.json 抛错的这次加载写了它（阶段 %s）：会拿默认值盖掉原文件", tostring(j.phase)))
                break
            end
        end
        return
    end
    -- 加载时写回：只在迁移时（AutoGuardGS.json 读出了表、没有放刀的两个键，旧文件读出来是表）
    local loads = {}
    for _, j in ipairs(w.json_writes) do
        if j.script == s.name and j.path == "AutoGuardGS.json" and j.phase == "load" then loads[#loads + 1] = j end
    end
    local function keys_of(v)
        local ks = {}
        for k in pairs(v) do ks[#ks + 1] = tostring(k) end
        table.sort(ks)
        return table.concat(ks, ",")
    end
    local function want_keys(gc)
        local ks = { "auto_parry", "parry_lead" }
        for _, k in ipairs(GUARD_KEYS8) do if gc[k] ~= nil then ks[#ks + 1] = k end end
        table.sort(ks)
        return table.concat(ks, ",")
    end
    if ctx.migrate then
        if #loads ~= 1 then
            fail(R, string.format("从旧 AutoParryGS.json 迁移后应在加载时写回 AutoGuardGS.json 恰好一次，实际 %d 次（MERGE 第 3.3 节第 5 步）", #loads))
        elseif loads[1].text then
            local v = json.decode(loads[1].text)
            if type(v) ~= "table" then
                fail(R, "加载时写回的 AutoGuardGS.json 读不出来")
            else
                if v.cfg_ver ~= nil then fail(R, "加载时写回的 AutoGuardGS.json 带 cfg_ver（合并版不存 cfg_ver，MERGE 第 3.1 节）") end
                if v.auto_parry ~= ctx.pcfg.auto_parry or v.parry_lead ~= ctx.pcfg.parry_lead then
                    fail(R, string.format("加载时写回的 auto_parry=%s parry_lead=%s，迁移的有效值是 %s / %d（同 v1.6 读旧文件）",
                        tostring(v.auto_parry), tostring(v.parry_lead), tostring(ctx.pcfg.auto_parry), ctx.pcfg.parry_lead))
                end
                if keys_of(v) ~= want_keys(ctx.gcfg0) then
                    fail(R, "加载时写回的 AutoGuardGS.json 的键是 " .. keys_of(v) .. "，应为 " .. want_keys(ctx.gcfg0) .. "（完整的配置表）")
                end
            end
        end
    elseif #loads > 0 then
        fail(R, "加载时不该写（AutoGuardGS.json 已有放刀的键、它本身读不出表，或没有旧文件、旧文件读不出表），却写了 AutoGuardGS.json")
    end
    -- 存配置：v1.4.2 的 8 个键（guard_angle 为 nil 时没有）加 auto_parry、parry_lead，不写 cfg_ver（MERGE 第 3.4 节）
    local saved
    for _, j in ipairs(w.json_writes) do
        if j.script == s.name and j.path == "AutoGuardGS.json" and j.phase == "reset" and j.text then saved = j end
    end
    if not saved then
        fail(R, "re.on_config_save 没有写出 AutoGuardGS.json")
    else
        local v = json.decode(saved.text)
        if type(v) ~= "table" then
            fail(R, "存下的 AutoGuardGS.json 读不出来")
        else
            local gend = ctx.gcfg_end
            if keys_of(v) ~= want_keys(gend) then fail(R, "存下的 AutoGuardGS.json 的键是 " .. keys_of(v) .. "，应为 " .. want_keys(gend)) end
            local pc = G.rc_cfg
            if v.auto_parry ~= pc.auto_parry or v.parry_lead ~= pc.parry_lead then
                fail(R, string.format("存下的 auto_parry=%s parry_lead=%s，场景结束时应为 %s / %d", tostring(v.auto_parry),
                    tostring(v.parry_lead), tostring(pc.auto_parry), pc.parry_lead))
            end
            for _, k in ipairs(GUARD_KEYS8) do
                if v[k] ~= gend[k] then fail(R, string.format("存下的 %s=%s，应为 %s（v1.4.2 的键原样写回）", k, tostring(v[k]), tostring(gend[k]))) end
            end
        end
    end
end

-- 菜单（MERGE 第 5 节）：只有一个树节点 ##AutoGuardGS；放刀一节在里面（出过 ui 错之后只剩状态行和红字）；
-- 红字只在进了红状态时出现；界面文字带 ##、没有 ° 和全角空格
local function check_ui_merged(R, sc, w, P)
    local s = HAS.rc or HAS.guard
    if not s then return end
    for _, id in ipairs(w.note_order) do
        local nt = w.notes[id]
        if (nt.kind == "LABEL_NO_ID" or nt.kind == "BAD_GLYPH") and nt.scripts[s.name] then
            fail(R, string.format("界面文字不合约定（%s）：%s", nt.kind == "LABEL_NO_ID" and "控件标签缺 ##英文ID" or "含字体里可能没有的字符", nt.key))
        end
    end
    local menu = w.menu[s.name] or {}
    local trees = 0
    for _, l in ipairs(menu) do
        if l:sub(1, 4) == "[+] " then
            trees = trees + 1
            if not l:find("##AutoGuardGS", 1, true) then fail(R, "菜单里有别的树节点：" .. l) end
        end
    end
    if trees ~= 1 then fail(R, string.format("菜单里树节点 %d 个，应只有「大剑自动防御 …##AutoGuardGS」一个", trees)) end
    if not HAS.rc then return end
    local text = table.concat(menu, "\n")
    local ui_err = false
    for _, r in ipairs(lines(P, "AutoParryGS", "ERR")) do if r.f.mod == "ui" then ui_err = true end end
    if ui_err then
        if text:find("##ap_enabled", 1, true) or text:find("##ap_lead", 1, true) then
            fail(R, "放刀一节出过 ui 错（ERR mod=ui）之后还在画完整的一节（应只剩状态行和红字，MERGE 第 5.3 节）")
        end
        if not parry_status_line(menu, false) then fail(R, "放刀一节出错降级后没有状态行") end
    elseif not (sc.mexpect and sc.mexpect.no_parry_menu) then
        for _, id in ipairs({ "##ap_enabled", "##ap_lead", "##reset_stats", "##debug_log" }) do
            if not text:find(id, 1, true) then fail(R, "菜单里没有控件 " .. id .. "（MERGE 第 5.1 节）") end
        end
        if not parry_status_line(menu, false) then fail(R, "菜单里没有放刀的状态行（「状态：…」）") end
        if not parry_counts(menu) then fail(R, "菜单里没有放刀计数那一行（放了 n 刀 … 没接住 n 次）") end
    end
    for _, bad in ipairs({ "##AutoParryGS", "##ap_debug", "##ap_reset", "##ap_dump" }) do
        if text:find(bad, 1, true) then fail(R, "菜单里还有 v1.6 的控件 " .. bad .. "（MERGE 第 2.6 节：删掉或改用共用的）") end
    end
    local has_red = #lines(P, "AutoParryGS", "RED") > 0
    if has_red and not text:find(RED_TEXT_M, 1, true) then
        fail(R, "进了红状态，菜单里没有「" .. RED_TEXT_M .. "」")
    elseif not has_red and text:find(RED_TEXT_M, 1, true) then
        fail(R, "没进红状态，菜单却显示了红色出错提示")
    end
end

-- ---------- 跑一个场景 ----------

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deep_copy(v) end
    return c
end

-- 测试脚本自己生成的变体（V16 第 8.4 节第 42 条「另由测试脚本生成一份去掉 add_ref 的 v1.6 副本」；MERGE 第 6.5 节
-- merge_ref_local_noaddref 对合并版同样做）：strip_add_ref = 把 X:add_ref() 换成 X:get_address()（同样是调用、没有引用副作用），
-- 写进场景输出目录。合并版源码里 r:add_ref() 必须恰好出现一次（只有消息钩子登记预告时那一处），否则生成失败、场景判失败。
-- 合并版是一棵模块树（入口 + 同名目录里的模块和共享库，docs/ARCHITECTURE.md）：整棵树复制进 <输出>/<名字>_<变体>/，
-- 每个文件都做同样的替换，「恰好一次」按整棵树数
local function make_variant(s, sc, out_dir)
    if not sc.rc_transform then return s end
    if sc.rc_transform ~= "strip_add_ref" then return nil, "不认识的变体 " .. tostring(sc.rc_transform) end
    local function strip(src)
        local out, c1 = src:gsub("([%w_%.]+):add_ref%(%)", "%1:get_address()")
        local c2
        out, c2 = out:gsub("pcall%(([%w_%.]+)%.add_ref,%s*([%w_%.]+)%)", "pcall(%1.get_address, %2)")
        local _, n_r = src:gsub("%f[%w_]r:add_ref%(%)", "")
        return out, c1 + c2, n_r
    end
    local root = s.path:match("^(.*)[/\\][^/\\]*$") or "."
    local entry = s.path:match("([^/\\]+)$")
    local files = { entry }
    if s.ver == "merged" then
        local mod_dir = entry:gsub("%.lua$", "")
        for _, f in ipairs(list_tree(root .. "/" .. mod_dir)) do files[#files + 1] = mod_dir .. "/" .. f end
    end
    local vroot = out_dir .. "/" .. s.name .. "_" .. sc.rc_transform
    local n, n_r = 0, 0
    for _, rel in ipairs(files) do
        local src = read_text(root .. "/" .. rel)
        if not src then return nil, "读不到 " .. root .. "/" .. rel end
        local out = src
        if rel:match("%.lua$") then
            local c, cr
            out, c, cr = strip(src)
            n, n_r = n + c, n_r + cr
        end
        local dst = vroot .. "/" .. rel
        mkdir_p(dst:match("^(.*)/[^/]*$"))
        if not write_text(dst, out) then return nil, "写不出 " .. dst end
    end
    if n == 0 then return nil, "被测脚本里没找到 add_ref 调用，生成不了去掉 add_ref 的副本" end
    if s.ver == "merged" and (n_r ~= 1 or n ~= 1) then
        return nil, string.format("合并版源码里 r:add_ref() 应恰好出现一次（实际 r:add_ref() %d 处、add_ref 调用共 %d 处）", n_r, n)
    end
    local path = vroot .. "/" .. entry
    local v = {}
    for k, x in pairs(s) do v[k] = x end
    v.path, v.variant, v.variant_n = path, sc.rc_transform, n
    return v
end

-- 合并版 / v1.4.2 这次跑的配置模型（MERGE 第 3 节）：加载时防御的 8 个键、放刀的两个键、要不要迁移
local function merged_cfg_model(sc, R)
    local cfgs = sc.config or {}
    local raw = sc.config_raw or {}
    local gseed = cfgs.AutoGuardGS
    if raw.AutoGuardGS then gseed = json.decode(raw.AutoGuardGS) end
    local oseed = cfgs.AutoParryGS
    if raw.AutoParryGS then oseed = json.decode(raw.AutoParryGS) end
    -- 旧文件读盘抛错（场景注入 json.load_file 故障）：按「没有旧文件」处理（MERGE 第 3.3 节第 1 步）。
    -- AutoGuardGS.json 读盘抛错：防御用默认值、放刀照常从旧文件迁移（只在内存里），这次加载一个字节都不写（审查修订）
    local unreadable = false
    for _, f in ipairs(sc.faults or {}) do
        if f.key == "json.load_file" and (not f.path or ("AutoParryGS.json"):find(f.path)) then oseed = nil end
        if f.key == "json.load_file" and (not f.path or ("AutoGuardGS.json"):find(f.path)) then
            gseed, unreadable = nil, true
        end
    end
    local pcfg, migrate = merged_parry_cfg(type(gseed) == "table" and gseed or nil, type(oseed) == "table" and oseed or nil)
    local mx = sc.mexpect or {}
    if mx.migrate ~= nil then migrate = mx.migrate end
    return { gcfg0 = guard_cfg_from(type(gseed) == "table" and gseed or nil), pcfg = pcfg, migrate = migrate,
        cfg_unreadable = unreadable }
end

-- 场景结束时防御部分的配置（存配置要原样写回）：加载时的值 + 菜单操作
local function guard_cfg_end(w, script, gc0)
    local c = deep_copy(gc0)
    local acts = {}
    for _, a in ipairs(w.ui_actions) do
        if a.done and a.done[script] then acts[#acts + 1] = a end
    end
    table.sort(acts, function(x, y) return x.done[script] < y.done[script] end)
    for _, a in ipairs(acts) do
        local m = a.match or ""
        for _, k in ipairs({ "enabled", "respect_armor", "auto_tackle", "infinite_charge", "lock_health", "debug_log" }) do
            if a.kind == "checkbox" and m:find("##" .. k, 1, true) and not m:find("##ap_", 1, true) then c[k] = a.value == true end
        end
        if a.kind == "combo" and m:find("##guard_type", 1, true) then c.guard_type = a.value end
        if a.kind == "slider" and m:find("##guard_angle", 1, true) then c.guard_angle = a.value end
        if a.kind == "button" and m:find("##angle_default", 1, true) then c.guard_angle = nil end
    end
    return c
end

-- V = 这一次的跑法：
--   { kind = "a0" }                             场景原来的跑法（rc_ver 选的放刀模块 + 探针）
--   { kind = "merged", debug = 布尔, subdir = …, transform = true }
--                                               合并脚本（+ 场景原来的探针）；transform = 按别名改写 v16 场景（MERGE 6.2）
--   { kind = "guard", subdir = "guard_ref" }    归档的 v1.4.2 单独加载（防御场景的参照组 G-ref）
--   另可带：probe（覆盖场景的 probe_ver）、config / config_raw（覆盖种子文件）、faults_add（追加故障）、ui（替换菜单操作）、
--   drop_ui（去掉菜单操作）、rc_transform（覆盖场景的变体）、keep = true（留下 world / 模拟器 / 日志给新场景的检查用）
local function run_scenario(sc0, V)
    V = V or { kind = "a0" }
    local sc = deep_copy(sc0)
    sc.expect = sc.expect or {}
    if opts.smoke then
        for _, k in ipairs(sc.smoke_drop or {}) do sc.expect[k] = nil end
    end
    local R = new_result(sc)
    R.variant = V
    R.label = V.subdir or "A0"
    if V.kind == "merged" and V.transform then merged_transform(sc, V, R) end
    if V.config then
        sc.config = sc.config or {}
        for k, v in pairs(V.config) do sc.config[k] = deep_copy(v) end
    end
    if V.config_raw then
        sc.config_raw = sc.config_raw or {}
        for k, v in pairs(V.config_raw) do sc.config_raw[k] = v end
    end
    for _, f in ipairs(V.faults_add or {}) do
        sc.faults = sc.faults or {}
        sc.faults[#sc.faults + 1] = deep_copy(f)
    end
    if V.drop_ui then sc.ui = {} end
    if V.ui then sc.ui = deep_copy(V.ui) end
    for k, v in pairs(V.expect or {}) do sc.expect[k] = deep_copy(v) end
    if V.rc_transform ~= nil then sc.rc_transform = V.rc_transform or nil end
    -- 这个场景载入哪个放刀模块、按哪个版本的口径断言（--smoke 时冒烟 rc 一律按 rc1）
    if V.kind == "merged" then
        CUR_VER = "merged"
    elseif V.kind == "guard" then
        CUR_VER = "v142"
    else
        CUR_VER = opts.smoke and "rc1" or (sc.rc_ver or opts.default_ver or "v16")
    end
    R.ver = CUR_VER
    local out_dir = opts.out .. "/" .. sc.name .. (V.subdir and ("/" .. V.subdir) or "")
    mkdir_p(out_dir)
    for _, f in ipairs(list_dir(out_dir)) do os.remove(out_dir .. "/" .. f) end
    present, HAS = {}, {}
    local probe = nil
    local pv = sc.probe_ver
    if V.probe ~= nil then pv = V.probe end
    if pv ~= false then probe = PROBE_SCRIPTS[pv or "cur"] end
    local rcs
    if V.kind == "merged" then
        rcs = RC_SCRIPTS.merged
    elseif V.kind == "guard" then
        rcs = GUARD_SCRIPTS.v142
    else
        rcs = RC_SCRIPTS[CUR_VER]
    end
    if rcs and file_exists(rcs.path) and not opts.smoke then
        local v, err = make_variant(rcs, sc, out_dir)
        if not v then
            fail(R, "生成被测脚本的变体失败：" .. tostring(err))
            R.out_dir = out_dir
            return R
        end
        rcs = v
        if v.variant then info(R, string.format("被测放刀脚本用的是测试生成的变体 %s（改了 %d 处）：%s", v.variant, v.variant_n, v.path)) end
    end
    local list = {}
    for _, s in ipairs({ probe or false, rcs or false }) do     -- 占位 false：ipairs 遇到 nil 就停
        if s and file_exists(s.path) then list[#list + 1] = s end
    end
    -- REF 按文件名字母序加载 autorun 里的脚本（MERGE 第 1.4 节，日志时间戳实测）：AutoGuardGS 在 AutoParryCalib 之前，
    -- AutoParryCalib 在 AutoParryGS 之前。帧回调、钩子按注册先后执行
    table.sort(list, function(a, b) return a.name < b.name end)
    for _, s in ipairs(list) do
        present[#present + 1] = s
        HAS[s.role] = s
    end
    KINDS_BY_TAG.AutoParryGS = RC_KINDS_BY_VER[CUR_VER]
    local prof = Sim.PROFILES[(CUR_VER == "merged" or CUR_VER == "v142") and "v16" or CUR_VER]
    -- 引用记账模型（V16 第 8.1 节）：冒烟脚本和 rc1 会手动 release，用旧的按脚本计数；其余用 REF 的真实语义
    local ref_model = opts.ref_model or sc.ref_model or (opts.smoke and "legacy") or prof.ref_model or "real"
    -- 合并版：放刀所在的脚本名（读速度、findEnemy 计数、按脚本的故障都认它）、加载后的放刀配置（神谕按它算 L 和开关）
    sc.rc_script = (HAS.rc and HAS.rc.name) or "AutoParryGS"
    local mctx
    if CUR_VER == "merged" or CUR_VER == "v142" then
        mctx = merged_cfg_model(sc, R)
        if CUR_VER == "merged" then
            sc.oracle_cfg = { auto_parry = mctx.pcfg.auto_parry, parry_lead = mctx.pcfg.parry_lead,
                debug_log = mctx.gcfg0.debug_log }
        else
            sc.oracle_cfg = { auto_parry = false, parry_lead = 28, debug_log = mctx.gcfg0.debug_log }
        end
    end

    local w = mock.new_world({ out_dir = out_dir, faults = sc.faults, dt = sc.dt or (1 / 90), ref_model = ref_model })
    w.allowed_hooks = ALLOWED_HOOKS
    -- 种子文件（= reframework/data 里已有的配置）。冒烟 rc 按 rc 的配置格式读、没有 lead_rotation 键时默认轮换：
    -- v15 格式的配置在 --smoke 时补上 lead_rotation=false、scan=false，让它和场景的固定 L 一致
    if opts.smoke and sc.config and type(sc.config.AutoParryGS) == "table" then
        local c = sc.config.AutoParryGS      -- sc 是场景的深拷贝，改它不影响别的场景
        if c.lead_rotation == nil then c.lead_rotation = false end
        if c.scan == nil then c.scan = false end
    end
    R.seed_text = {}
    for name, tbl in pairs(sc.config or {}) do
        if not (sc.config_raw and sc.config_raw[name]) then
            local s = json.encode(tbl, 4)
            w:write_file(name .. ".json", s)
            R.seed_text[name .. ".json"] = s
        end
    end
    -- 原样写的种子（不是 JSON 的坏文件，MERGE 第 3.5 节第 7 条）
    R.raw_seed = {}
    for name, text in pairs(sc.config_raw or {}) do
        w:write_file(name .. ".json", text)
        R.seed_text[name .. ".json"] = text
        R.raw_seed[name .. ".json"] = true
    end
    for _, a in ipairs(sc.ui or {}) do w.ui_actions[#w.ui_actions + 1] = deep_copy(a) end

    local okc, G = pcall(Sim.new, w, sc, prof)
    if not okc then
        fail(R, "场景构建失败（mock 自身的问题）：" .. tostring(G))
        R.out_dir = out_dir
        return R
    end
    -- 副作用记录时带上这一刻主角的动作（合并版的白名单要按「钩子里现读的动作」判断，MERGE 第 6.7 节变异）
    w.effect_annotate = function() return { act = string.format("(%d,%d)", G.act.cat, G.act.idx) } end
    -- 菜单操作改了 rc 的启用开关 / 提前量（场景的 ui 操作带 cfg_key）：被测脚本在 UI 阶段读到这次操作之后，
    -- 神谕从下一帧起按新配置算，v15 的 CFG 行也按它核对
    local function sync_ui_cfg()
        if not HAS.rc then return end
        for _, a in ipairs(w.ui_actions) do
            if a.cfg_key and not a.cfg_applied and a.done and a.done[HAS.rc.name] then
                a.cfg_applied = true
                G:apply_ui_cfg(a.cfg_key, a.value)
            end
        end
    end

    local t_real0 = os.clock()
    -- 场景运行期间停掉自动 GC：回收只在持有观测要的帧末做（ho_frame_end），句柄回收时刻完全可复现
    collectgarbage("stop")
    for _, s in ipairs(present) do
        local ok, err = w:load_script(s.name, s.path, s.tag)
        if not ok then fail(R, string.format("%s 加载失败：%s", s.name, tostring(err))) end
    end
    local HO = new_holds(w, G, sc)
    ho_init(HO)

    local hitches = {}
    for _, h in ipairs(sc.hitches or {}) do hitches[#hitches + 1] = { at = h.at, dt = h.dt } end
    table.sort(hitches, function(a, b) return a.at < b.at end)
    local base_dt = sc.dt or (1 / 90)
    local ui_every = sc.ui_every or 9
    local stop_at
    local log_scan = 1
    local cost = {}
    local cost_max = {}
    local frames = 0
    local function draw_ui()
        w.phase = "ui"
        w.menu = {}
        w:run_cbs("draw_ui", true)
        sync_ui_cfg()
    end
    local ok_loop, loop_err = pcall(function()
        while w.t < sc.duration and (not stop_at or w.t < stop_at) do
            local dt = base_dt
            if hitches[1] and w.t + base_dt >= hitches[1].at then
                dt = table.remove(hitches, 1).dt
            end
            w.dt = dt
            w.t = w.t + dt
            w.frame = w.frame + 1
            frames = frames + 1
            w.frame_cost = {}
            w.phase = "pre"
            G:pre_frame()
            w:run_cbs("pre:UpdateBehavior")
            w.phase = "update"
            G:update()
            w:run_cbs("post:UpdateBehavior")
            w.phase = "hit"
            G:hit()
            w.phase = "late"
            w:run_cbs("pre:LateUpdateBehavior")
            w:run_cbs("post:LateUpdateBehavior")
            w.phase = "frame"
            w:run_cbs("frame", true)
            local ui_due = (w.frame % ui_every == 0)
            if not ui_due then
                for _, a in ipairs(w.ui_actions) do
                    if w.t >= a.t and not a.done then ui_due = true end
                end
            end
            -- 场景要在某一帧结算到一半就结束（Reset 打断一次挨打的结算，MERGE 第 6.5 节 merge_reset_restore）：这一帧之后
            -- 不再画菜单、不再有帧开头，直接存配置、Reset
            local ending = sc.end_at and w.t >= sc.end_at - 1e-9
            if ui_due and not ending then draw_ui() end
            w.phase = "gc"
            ho_frame_end(HO, opts.gc_every_frame)
            for s, c in pairs(w.frame_cost) do
                cost[s] = (cost[s] or 0) + c
                if c > (cost_max[s] or 0) then cost_max[s] = c end
            end
            if sc.stop_on_log and not stop_at then
                for i = log_scan, #w.logs do
                    if w.logs[i].text:find(sc.stop_on_log) then
                        stop_at = w.t + (sc.stop_tail or 5.0)
                        break
                    end
                end
                log_scan = #w.logs + 1
            end
            if ending then break end
        end
        -- 最后再画一次菜单：合并版的计数取「场景结束时的菜单」（MERGE 第 6.3 节），要包括最后几帧的结局
        if not sc.end_at then draw_ui() end
    end)
    if not ok_loop then fail(R, "模拟循环出错（mock 自身的问题）：" .. tostring(loop_err)) end
    -- 场景结束：保存配置、Reset Scripts（两个脚本都要在这里写出 JSON），然后丢弃脚本环境、强制回收（V16 第 8.2 节第 2 条：
    -- Lua 状态关闭时 REF 的回收会自动 release）
    w.phase = "reset"
    w:run_cbs("config_save")
    w:run_cbs("reset")
    w:drop_scripts()
    collectgarbage("restart")
    R.real_s = os.clock() - t_real0
    R.frames = frames
    R.sim_s = w.t

    local P = parse_logs(w)
    local all_records
    if CUR_VER == "merged" or CUR_VER == "v142" then
        local sname = (HAS.rc or HAS.guard or {}).name or "AutoGuardGS"
        mctx.debug_at = cfg_timeline(w, sname, mctx.gcfg0.debug_log, "##debug_log")
        mctx.inf_at = cfg_timeline(w, sname, mctx.gcfg0.infinite_charge, "##infinite_charge")
        mctx.lock_at = cfg_timeline(w, sname, mctx.gcfg0.lock_health, "##lock_health")
        mctx.gcfg_end = guard_cfg_end(w, sname, mctx.gcfg0)
        mctx.parry_at = function(t, phase)
            local ap, L = G.cfg0.auto_parry, G.cfg0.parry_lead
            for _, c in ipairs(G.cfg_changes) do
                if c.t < t - 1e-9 or phase == "reset" then ap, L = c.auto_parry, c.parry_lead end
            end
            return ap, L
        end
        check_logs_merged(R, sc, w, G, P, mctx)
        -- 由 v16 场景改写来的跑法：放刀的 ERR / RED 和 A0 逐项比（等价测试），这里只查探针的；配置读写的错误（cfg）A0 没有可比的，
        -- 一律不许出现。新场景：按场景自己的声明查
        if sc0.merged_only then
            check_err(R, sc, P)
        else
            check_err(R, sc, P, { APCal = true })
            for _, r in ipairs(lines(P, "AutoParryGS", "ERR")) do
                if r.f.mod == "cfg" then
                    fail(R, "意外的 ERR mod=cfg（配置读写出错）：" .. r.text:sub(1, 160))
                    break
                end
            end
        end
        check_violations(R, sc, w)
        check_effects_merged(R, sc, w, G, mctx)
        check_refs(R, w, sc, HO, G)
        check_holds(R, w, G, sc, P, HO)
        check_hooks_merged(R, sc, w)
        all_records = check_json(R, sc, w, P)
        check_files_merged(R, sc, w, G, mctx)
        check_ui_merged(R, sc, w, P)
        if HAS.probe and sc.expect.probe_checks ~= false then
            check_pt(R, sc, w, G, P)
            check_probe_counts(R, sc, w, G, P, all_records and all_records.APCal)
        end
        check_extra(R, sc, w, G, P, all_records)
        check_misc(R, sc, w, P)
        R.gtrace = guard_trace(w, sname)
        R.gcounts = guard_counts(w.menu[sname])
    else
        check_logs(R, sc, w, P)
        check_err(R, sc, P)
        check_violations(R, sc, w)
        check_effects(R, w)
        check_refs(R, w, sc, HO, G)
        check_holds(R, w, G, sc, P, HO)
        check_hooks(R, w)
        all_records = check_json(R, sc, w, P)
        check_json_idle(R, w, G, P)
        local fire_info
        if HAS.rc and CUR_VER == "v16" and (sc.expect.rc or "oracle") == "oracle" then
            local nvq, nu = check_v16_fire(R, sc, w, G, P, HAS.rc.name)
            fire_info = { vq = nvq, uview = nu }
            check_v16_skip(R, sc, w, G, P)
        end
        if CUR_VER == "v15" or CUR_VER == "v16" then check_release(R, sc, w, G, P, all_records, fire_info) end
        if HAS.rc then
            local rcn = HAS.rc.name
            local mode = sc.expect.rc or "oracle"
            if mode == "oracle" or mode == "oracle_rotation" then
                check_rc_oracle(R, sc, w, G, P, rcn, mode)
                check_rc_records(R, sc, w, G, P, rcn)
                if mode == "oracle_rotation" then check_rotation(R, P) end
            elseif mode == "scan" then
                check_scan(R, sc, w, G, P, rcn)
            elseif mode == "none" and #w.requests > 0 then
                fail(R, string.format("这个场景 rc 不该请求放刀，实际 %d 次", #w.requests))
            end
        end
        -- 负对照里探针中途停止记录或读到坏对象，测量计数对不上是预期的（expect.probe_checks = false）
        if HAS.probe and sc.expect.probe_checks ~= false then
            check_pt(R, sc, w, G, P)
            check_probe_counts(R, sc, w, G, P, all_records and all_records.APCal)
        end
        check_extra(R, sc, w, G, P, all_records)
        check_misc(R, sc, w, P)
        check_saved_config(R, sc, w)
    end
    R.trace = extract_trace(R, sc, w, G, P, all_records)
    for s, c in pairs(cost) do
        info(R, string.format("%s 每帧 Lua 耗时（mock 下，含 mock 开销）平均 %.3f ms，最大 %.3f ms", s, c * 1000 / math.max(1, frames),
            (cost_max[s] or 0) * 1000))
    end
    if V.keep then
        R.w, R.G, R.P, R.mctx = w, G, P, mctx
        -- Reset 之后共享参数的值（还原路径的核对，MERGE 第 6.5 节 merge_reset_restore、guard_infinite_charge）
        local wp = G.wp_param
        local f = rawget(wp, "__f")
        R.final = { guard_deg = f._GuardDegree, aim_deg = f._AimGuardDegree, overheat = {}, hp = G.hp,
            forced = (function() local n = 0 for _ in pairs(G.H.forced) do n = n + 1 end return n end)() }
        for _, n in ipairs({ "_ChargeParam", "_ChargeParam_Strong", "_ChargeParam_Spirit", "_ChargeParam_Parry",
            "_ChargeParam_Fly", "_ChargeParam_Sliding", "_ChargeParam_BattleRide" }) do
            R.final.overheat[n] = rawget(f[n], "__f")._OverheatTime
        end
    end

    -- ---------- 输出 ----------
    local logbuf = {}
    for _, l in ipairs(w.logs) do
        logbuf[#logbuf + 1] = string.format("[%s] [REFramework] [%s] %s", l.ts, l.level, l.text)
    end
    write_text(out_dir .. "/ref.log", table.concat(logbuf, "\n") .. "\n")
    local truth = G:truth_table()
    truth.requests = {}
    for _, q in ipairs(w.requests) do
        truth.requests[#truth.requests + 1] = { t = q.t + w.clock_base, frame = q.frame, accepted = q.accepted,
            reason = q.reason, from = q.from, script = q.script }
    end
    truth.scenario = sc.name
    truth.clock_base = w.clock_base
    local tj = json.encode(truth, 1)
    write_text(out_dir .. "/mock_truth.json", tj or "{}")
    local hud = {}
    for s, h in pairs(w.hud) do
        for _, e in ipairs(h.list) do hud[#hud + 1] = string.format("%s t=%.2f %s", s, e.t, e.text) end
    end
    table.sort(hud)
    write_text(out_dir .. "/hud.txt", table.concat(hud, "\n") .. "\n")
    local menu = {}
    for s, m in pairs(w.menu) do
        menu[#menu + 1] = "== " .. s
        for _, l in ipairs(m) do menu[#menu + 1] = "  " .. l end
    end
    write_text(out_dir .. "/menu.txt", table.concat(menu, "\n") .. "\n")
    local sum = { "场景 " .. sc.name .. "：" .. (sc.desc or ""),
        "放刀模块版本口径：" .. CUR_VER .. (opts.smoke and "（冒烟）" or "") .. "；跑法：" .. R.label,
        string.format("帧数 %d，模拟 %.2f s，实际耗时 %.2f s", frames, w.t, R.real_s),
        "被测脚本：" .. (function()
            local t = {}
            for _, s in ipairs(present) do t[#t + 1] = s.path end
            return table.concat(t, " ; ")
        end)(), "" }
    sum[#sum + 1] = #R.fails == 0 and "结果：通过" or ("结果：失败 " .. #R.fails .. " 项")
    for _, f in ipairs(R.fails) do sum[#sum + 1] = "  ✗ " .. f end
    sum[#sum + 1] = ""
    sum[#sum + 1] = "警告 " .. #R.warns .. " 项"
    for _, f in ipairs(R.warns) do sum[#sum + 1] = "  ! " .. f end
    sum[#sum + 1] = ""
    sum[#sum + 1] = "信息"
    for _, f in ipairs(R.infos) do sum[#sum + 1] = "  · " .. f end
    sum[#sum + 1] = ""
    sum[#sum + 1] = "UNMOCKED 等观察项（mock 没模拟到的接口；也可能是被测脚本把名字写错了）"
    for _, f in ipairs(R.unmocked or {}) do sum[#sum + 1] = "  ? " .. f end
    sum[#sum + 1] = ""
    sum[#sum + 1] = "动作请求（changeActionRequest）"
    for _, q in ipairs(w.requests) do
        sum[#sum + 1] = string.format("  t=%s f%d %s→(%s,%s) %s accepted=%s %s", fmt_t(q.t + w.clock_base), q.frame, q.from,
            tostring(q.cat), tostring(q.idx), tostring(q.script), tostring(q.accepted), q.reason or "")
    end
    if R.gtrace then
        sum[#sum + 1] = ""
        sum[#sum + 1] = "防御副作用轨迹（MERGE 第 6.5 节）"
        for _, e in ipairs(R.gtrace) do sum[#sum + 1] = "  " .. e.text end
    end
    sum[#sum + 1] = ""
    sum[#sum + 1] = "模拟器真值：放刀尝试"
    for _, a in ipairs(G.truth.attempts) do
        sum[#sum + 1] = string.format("  #%d t_start=%s %s from=%s 结果=%s 刀上=%d 身体=%d", a.id, fmt_t(a.t_start + w.clock_base),
            a.origin, a.from, a.outcome, a.blade, a.body)
    end
    write_text(out_dir .. "/summary.txt", table.concat(sum, "\n") .. "\n")
    R.out_dir = out_dir
    return R
end

-- ---------- 合并模式的新场景（MERGE 第 6.5 节）：场景的 runs 列出要跑的跑法，mexpect 是跨跑法的期望 ----------

local function trace_texts(R, no_frame)
    local out = {}
    for _, e in ipairs(R.gtrace or {}) do
        out[#out + 1] = no_frame and e.text:gsub("^f%d+ ", "") or e.text
    end
    return out
end

-- 比两个跑法的轨迹前先规范化：同一帧、同一阶段、同一钩子里连续几次写同一个类型的字段（「set 类型.字段=值」），
-- 组内按文字排序。为什么：参照组 v1.4.2 还原防御角度时用 pairs 遍历 { _GuardDegree, _AimGuardDegree }，Lua 5.4 的字符串
-- 哈希种子每次启动随机，pairs 的顺序每次运行都可能不同（两次全量运行实测顺序相反）；合并版按后进先出还原（lib/patch）。
-- 两个字段互不相干，写的先后不影响结果，组内顺序不算差异
local function normalize_sets(list)
    local out, i = {}, 1
    local function key(s) return s:match("^(.- set [%w_%.]-)%.[%w_]+=") end
    while i <= #list do
        local k = key(list[i])
        local j = i
        while k and j + 1 <= #list and key(list[j + 1]) == k do j = j + 1 end
        local group = {}
        for x = i, j do group[#group + 1] = list[x] end
        table.sort(group)
        for _, s in ipairs(group) do out[#out + 1] = s end
        i = j + 1
    end
    return out
end

-- 按顺序找一串模式（Lua 模式，按轨迹行匹配）；返回缺的那一条
local function seq_find(list, pats)
    local i = 1
    for _, p in ipairs(pats or {}) do
        local found = false
        while i <= #list do
            local hit = list[i]:find(p)
            i = i + 1
            if hit then
                found = true
                break
            end
        end
        if not found then return p end
    end
    return nil
end

local function menu_text(R)
    local s = HAS and R.w and (R.w.menu[(R.mname or "AutoGuardGS")] or {}) or {}
    return table.concat(s, "\n")
end

local function check_merged_only(sc, runs)
    local F = new_result(sc)
    local mx = sc.mexpect or {}
    local function get(key)
        local R = runs[key]
        if not R then fail(F, "缺跑法 " .. tostring(key)) end
        return R
    end
    -- 两个跑法的防御副作用轨迹、防御计数逐项相同（G-ref 对合并版，MERGE 第 6.5 节「防御功能」）
    for _, pair in ipairs(mx.same_guard or {}) do
        local a, b = get(pair[1]), get(pair[2])
        if a and b then
            local ta, tb = normalize_sets(trace_texts(a)), normalize_sets(trace_texts(b))
            local n = math.max(#ta, #tb)
            local shown = 0
            for i = 1, n do
                if ta[i] ~= tb[i] then
                    shown = shown + 1
                    if shown <= 4 then fail(F, string.format("防御副作用轨迹第 %d 项：%s「%s」，%s「%s」", i, pair[1], tostring(ta[i]), pair[2], tostring(tb[i]))) end
                end
            end
            if shown > 4 then fail(F, string.format("……防御副作用轨迹另有 %d 项不同", shown - 4)) end
            for _, k in ipairs({ "guarded", "tackled", "already", "armor", "state", "blocked" }) do
                if (a.gcounts or {})[k] ~= (b.gcounts or {})[k] then
                    fail(F, string.format("防御计数 %s：%s %s，%s %s", k, pair[1], tostring((a.gcounts or {})[k]), pair[2], tostring((b.gcounts or {})[k])))
                end
            end
            info(F, string.format("防御副作用轨迹 %s 对 %s：%d 项", pair[1], pair[2], #ta))
        end
    end
    -- (2,23) 请求序列逐项相同（放刀不受防御打扰 / 调试日志开关不改决策）
    for _, grp in ipairs(mx.same_req or {}) do
        local base = get(grp[1])
        for i = 2, #grp do
            local x = get(grp[i])
            if base and x then
                local a, b = base.trace.req, x.trace.req
                if table.concat(a, "\n") ~= table.concat(b, "\n") then
                    local k = 1
                    while a[k] == b[k] do k = k + 1 end
                    fail(F, string.format("(2,23) 请求序列 %s 和 %s 不同（第 %d 项：%s ；%s；共 %d / %d 项）", grp[1], grp[i], k,
                        tostring(a[k]), tostring(b[k]), #a, #b))
                else
                    info(F, string.format("(2,23) 请求序列 %s = %s（%d 项）", grp[1], grp[i], #a))
                end
            end
        end
    end
    -- 放刀的错误（mod、level、发生时刻）逐条相同（去掉 json、cfg 两个模块，口径同逐刀等价测试的「错误」一行）
    for _, pair in ipairs(mx.same_err or {}) do
        local a, b = get(pair[1]), get(pair[2])
        if a and b then
            local function rows(R)
                local out = {}
                for _, e in ipairs(R.trace.err or {}) do
                    if e.mod ~= "json" and e.mod ~= "cfg" then out[#out + 1] = string.format("%s/%s@%s", e.mod, e.level, e.t) end
                end
                return out
            end
            local ra, rb = rows(a), rows(b)
            if table.concat(ra, " ") ~= table.concat(rb, " ") then
                fail(F, string.format("错误（mod/level@时刻）：%s [%s]，%s [%s]", pair[1], table.concat(ra, " "), pair[2], table.concat(rb, " ")))
            elseif #ra == 0 then
                fail(F, "两个跑法都没有错误（场景设计没起作用）")
            end
        end
    end
    -- FIRE 的 t / Q0 和参照组相同（按 t 对齐；id 可以不同，比如 A0 是 v1.6 单独跑）
    for _, pair in ipairs(mx.same_fire or {}) do
        local a, b = get(pair[1]), get(pair[2])
        if a and b then
            local fa, fb = {}, {}
            for _, r in pairs(a.trace.fire) do fa[#fa + 1] = (r.f.t or "?") .. " Q0=" .. tostring(r.f.Q0) .. " ent=" .. tostring(r.f.ent) end
            for _, r in pairs(b.trace.fire) do fb[#fb + 1] = (r.f.t or "?") .. " Q0=" .. tostring(r.f.Q0) .. " ent=" .. tostring(r.f.ent) end
            table.sort(fa)
            table.sort(fb)
            if table.concat(fa, "; ") ~= table.concat(fb, "; ") then
                fail(F, string.format("FIRE 的时刻 / Q0：%s [%s]，%s [%s]", pair[1], table.concat(fa, "; "), pair[2], table.concat(fb, "; ")))
            end
        end
    end
    -- 某个跑法的防御轨迹里按顺序出现 / 不许出现的行（Lua 模式，不含帧号）
    for _, e in ipairs(mx.trace or {}) do
        local R = get(e.run)
        if R then
            local tt = trace_texts(R, true)
            local miss = seq_find(tt, e.has)
            if miss then fail(F, string.format("%s 的防御副作用轨迹里没有按顺序出现「%s」（轨迹见 summary.txt）", e.run, miss)) end
            for _, p in ipairs(e.absent or {}) do
                for _, line in ipairs(tt) do
                    if line:find(p) then
                        fail(F, string.format("%s 的防御副作用轨迹里不该有「%s」：%s", e.run, p, line))
                        break
                    end
                end
            end
            if e.count then
                for p, want in pairs(e.count) do
                    local n = 0
                    for _, line in ipairs(tt) do if line:find(p) then n = n + 1 end end
                    if n ~= want then fail(F, string.format("%s 的防御副作用轨迹里「%s」%d 次，预期 %d 次", e.run, p, n, want)) end
                end
            end
        end
    end
    -- 防御计数（菜单）
    for run, want in pairs(mx.gcounts or {}) do
        local R = get(run)
        if R then
            for k, v in pairs(want) do
                if (R.gcounts or {})[k] ~= v then fail(F, string.format("%s 的防御计数 %s=%s，预期 %s", run, k, tostring((R.gcounts or {})[k]), tostring(v))) end
            end
        end
    end
    -- 放刀计数（菜单）
    for run, want in pairs(mx.pcounts or {}) do
        local R = get(run)
        local c = R and R.trace and R.trace.counts or {}
        for k, v in pairs(want) do
            if c[k] ~= v then fail(F, string.format("%s 的放刀计数 %s=%s，预期 %s", run, k, tostring(c[k]), tostring(v))) end
        end
    end
    -- 日志：某个跑法的日志里要有 / 不许有的行（Lua 模式）；时刻范围 { from, to } 可选
    for _, e in ipairs(mx.log or {}) do
        local R = get(e.run)
        if R and R.w then
            local function hits(p)
                local n = 0
                for _, l in ipairs(R.w.logs) do
                    if (not e.from or l.t >= e.from) and (not e.to or l.t < e.to) and l.text:find(p) then n = n + 1 end
                end
                return n
            end
            for _, p in ipairs(e.has or {}) do
                if hits(p) == 0 then fail(F, string.format("%s 的日志里%s没有「%s」", e.run, e.from and string.format("（%.1f~%s s）", e.from, tostring(e.to)) or "", p)) end
            end
            for _, p in ipairs(e.absent or {}) do
                local n = hits(p)
                if n > 0 then fail(F, string.format("%s 的日志里%s不该有「%s」（%d 行）", e.run, e.from and string.format("（%.1f~%s s）", e.from, tostring(e.to)) or "", p, n)) end
            end
            for p, want in pairs(e.count or {}) do
                local n = hits(p)
                if n ~= want then fail(F, string.format("%s 的日志里「%s」%d 行，预期 %d 行", e.run, p, n, want)) end
            end
            if e.only then
                -- 只许出现这些模式之一（其余的 [AutoGuardGS] / [AutoParryGS] 行都不许有）
                for _, l in ipairs(R.w.logs) do
                    local tag = l.text:match("^%[([%w_]+)%]")
                    if tag == "AutoGuardGS" or tag == "AutoParryGS" then
                        local ok = false
                        for _, p in ipairs(e.only) do if l.text:find(p) then ok = true end end
                        if not ok then
                            fail(F, string.format("%s 的日志里不该有这一行：%s", e.run, l.text:sub(1, 140)))
                            break
                        end
                    end
                end
            end
        end
    end
    -- 菜单：最后一次画的 / 出现过的文字
    for _, e in ipairs(mx.menu or {}) do
        local R = get(e.run)
        if R and R.w then
            local final = table.concat(R.w.menu[e.script or "AutoGuardGS"] or {}, "\n")
            local seen = R.w.menu_seen[e.script or "AutoGuardGS"] or {}
            local function seen_has(p)
                for l in pairs(seen) do if l:find(p, 1, true) then return true end end
                return false
            end
            for _, p in ipairs(e.final or {}) do
                if not final:find(p, 1, true) then fail(F, string.format("%s 场景结束时的菜单里没有「%s」", e.run, p)) end
            end
            for _, p in ipairs(e.final_absent or {}) do
                if final:find(p, 1, true) then fail(F, string.format("%s 场景结束时的菜单里不该有「%s」", e.run, p)) end
            end
            for _, p in ipairs(e.seen or {}) do
                if not seen_has(p) then fail(F, string.format("%s 的菜单里从没出现过「%s」", e.run, p)) end
            end
            for _, p in ipairs(e.never or {}) do
                if seen_has(p) then fail(F, string.format("%s 的菜单里不该出现「%s」", e.run, p)) end
            end
        end
    end
    -- Reset 之后共享参数的值、血量
    for run, want in pairs(mx.final or {}) do
        local R = get(run)
        local fin = R and R.final or {}
        for k, v in pairs(want) do
            if k == "overheat" then
                for n, ov in pairs(v) do
                    local got = fin.overheat and fin.overheat[n]
                    if not got or math.abs(got - ov) > 1e-3 then fail(F, string.format("%s 结束后 %s._OverheatTime=%s，应为 %s", run, n, tostring(got), tostring(ov))) end
                end
            elseif type(v) == "number" then
                if not fin[k] or math.abs(fin[k] - v) > 1e-3 then fail(F, string.format("%s 结束后 %s=%s，应为 %s", run, k, tostring(fin[k]), tostring(v))) end
            elseif fin[k] ~= v then
                fail(F, string.format("%s 结束后 %s=%s，应为 %s", run, k, tostring(fin[k]), tostring(v)))
            end
        end
    end
    -- 配置迁移：每个跑法的放刀配置（菜单的开关和滑块、调试日志开着时 HDR 的 lead）
    for run, want in pairs(mx.parry_cfg or {}) do
        local R = get(run)
        if R and R.w then
            local menu = R.w.menu.AutoGuardGS or {}
            local lead, ap
            for _, l in ipairs(menu) do
                lead = lead or tonumber(l:match("##ap_lead = (%-?[%d%.]+)"))
                if l:find("##ap_enabled", 1, true) then ap = l:sub(1, 3) == "[x]" end
            end
            if want.lead and lead ~= want.lead then fail(F, string.format("%s 菜单里提前量=%s，预期 %d", run, tostring(lead), want.lead)) end
            if want.auto_parry ~= nil and ap ~= want.auto_parry then
                fail(F, string.format("%s 菜单里自动放刀开关=%s，预期 %s", run, tostring(ap), tostring(want.auto_parry)))
            end
            local h = lines(R.P, "AutoParryGS", "HDR")[1]
            if want.lead and h and h.f.lead ~= tostring(want.lead) then fail(F, string.format("%s 的 HDR lead=%s，预期 %d", run, tostring(h.f.lead), want.lead)) end
            if want.fires ~= nil and #R.trace.req > 0 ~= want.fires then
                fail(F, string.format("%s %s放刀（请求 %d 次）", run, want.fires and "应该" or "不该", #R.trace.req))
            end
            if want.load_write ~= nil then
                local n = 0
                for _, j in ipairs(R.w.json_writes) do
                    if j.path == "AutoGuardGS.json" and j.phase == "load" then n = n + 1 end
                end
                if (n > 0) ~= want.load_write then
                    fail(F, string.format("%s 加载时%s写 AutoGuardGS.json（实际 %d 次）", run, want.load_write and "应该" or "不该", n))
                end
            end
            if want.old_read ~= nil then
                local n = 0
                for _, j in ipairs(R.w.json_reads or {}) do if j.path == "AutoParryGS.json" then n = n + 1 end end
                if (n > 0) ~= want.old_read then
                    fail(F, string.format("%s %s读旧的 AutoParryGS.json（实际 %d 次）", run, want.old_read and "应该" or "不该", n))
                end
            end
        end
    end
    -- 存下的 AutoGuardGS.json 里防御的 8 个键：两个跑法逐个相同（v1.4.2 读同一个文件，MERGE 第 3.5 节第 10 条）
    for _, pair in ipairs(mx.same_saved8 or {}) do
        local a, b = get(pair[1]), get(pair[2])
        if a and b then
            local function saved(R)
                local s
                for _, j in ipairs(R.w.json_writes) do
                    if j.path == "AutoGuardGS.json" and j.phase == "reset" and j.text then s = j.text end
                end
                return s and json.decode(s) or {}
            end
            local va, vb = saved(a), saved(b)
            for _, k in ipairs(GUARD_KEYS8) do
                if va[k] ~= vb[k] then fail(F, string.format("存下的 %s：%s %s，%s %s", k, pair[1], tostring(va[k]), pair[2], tostring(vb[k]))) end
            end
            -- 菜单里防御一节的控件状态也逐个相同（读出来的值一样）
            local function gmenu(R)
                local out = {}
                for _, l in ipairs(R.w.menu.AutoGuardGS or {}) do
                    for _, id in ipairs({ "##enabled", "##guard_type", "##respect_armor", "##auto_tackle", "##guard_angle",
                        "##infinite_charge", "##lock_health", "##debug_log" }) do
                        if l:find(id, 1, true) then
                            local st = l:match("^%[(.)%]") or l:match("= (.-)$") or "?"
                            out[id] = st
                        end
                    end
                end
                return out
            end
            local ma, mb = gmenu(a), gmenu(b)
            for _, id in ipairs({ "##enabled", "##guard_type", "##respect_armor", "##auto_tackle", "##guard_angle",
                "##infinite_charge", "##lock_health", "##debug_log" }) do
                if ma[id] ~= mb[id] then fail(F, string.format("菜单 %s：%s「%s」，%s「%s」", id, pair[1], tostring(ma[id]), pair[2], tostring(mb[id]))) end
            end
        end
    end
    -- 调试日志中途打开：FIRE 的 id 和全程开着的跑法按时刻对齐必须相同（next_id 不看调试日志开没开，MERGE 第 2.5 节）
    for _, pair in ipairs(mx.same_fire_ids or {}) do
        local a, b = get(pair[1]), get(pair[2])
        if a and b then
            local by_t = {}
            for id, r in pairs(a.trace.fire) do by_t[r.f.t or "?"] = id end
            local n = 0
            for id, r in pairs(b.trace.fire) do
                n = n + 1
                if by_t[r.f.t or "?"] ~= id then
                    fail(F, string.format("%s 的 FIRE t=%s id=%s，%s 同一时刻的 id=%s（next_id 要每次放刀都递增）", pair[2], tostring(r.f.t), id,
                        pair[1], tostring(by_t[r.f.t or "?"])))
                    break
                end
            end
            if n == 0 then fail(F, pair[2] .. " 一行 FIRE 都没有（场景设计没起作用）") end
            local rid = {}
            for id, r in pairs(b.trace.res) do
                if not b.trace.fire[id] and not (a.trace.fire[id]) then rid[#rid + 1] = id end
            end
            if #rid > 0 then fail(F, pair[2] .. " 有 RES 对不上任何一刀：id=" .. table.concat(rid, ",")) end
        end
    end
    return F
end

-- ---------- 主程序 ----------

local selected = {}
if #opts.names == 0 then
    selected = SCENARIOS
else
    local by = {}
    for _, s in ipairs(SCENARIOS) do by[s.name] = s end
    for _, n in ipairs(opts.names) do
        if not by[n] then
            io.stderr:write("没有这个场景：" .. n .. "（--list 看全部）\n")
            os.exit(2)
        end
        selected[#selected + 1] = by[n]
    end
end

-- 冒烟脚本（tools/mock/smoke）只为验证 mock 本身，没实现正式脚本的全部功能（空挥计数、停止记录、
-- 扫描收尾与存配置）：场景标了 smoke = false 的，--smoke 时跳过；合并模式的新场景也跳过
if opts.smoke then
    local keep, skipped = {}, {}
    for _, sc in ipairs(selected) do
        if sc.smoke == false or sc.merged_only then skipped[#skipped + 1] = sc.name else keep[#keep + 1] = sc end
    end
    selected = keep
    if #skipped > 0 then print("--smoke 跳过只测正式脚本功能的场景：" .. table.concat(skipped, " ")) end
end
-- 不带 --merged：只跑参照组（144 个场景原样跑 A0），合并模式的新场景跳过
if not opts.merged then
    local keep, skipped = {}, {}
    for _, sc in ipairs(selected) do
        if sc.merged_only then skipped[#skipped + 1] = sc.name else keep[#keep + 1] = sc end
    end
    selected = keep
    if #skipped > 0 and #opts.names > 0 then print("不带 --merged，跳过合并模式的新场景：" .. table.concat(skipped, " ")) end
end

-- 这个场景要不要在合并模式下和 A0 逐刀比（MERGE 第 6.3 节「哪些场景比」）：v16 场景，减去两个引用负对照
local function comparable(sc)
    return opts.merged and not sc.merged_only and (sc.rc_ver or "v16") == "v16" and sc.merged_equiv ~= false
end

-- 被测脚本齐不齐：探针 + 选中场景要用到的放刀模块版本（合并模式另要合并脚本和归档的 v1.4.2）
local needed, missing, missing_seen = { PROBE_SCRIPT }, {}, {}
do
    local vers, pvers = {}, {}
    local need_guard = false
    for _, sc in ipairs(selected) do
        if not sc.merged_only then vers[opts.smoke and "rc1" or (sc.rc_ver or opts.default_ver or "v16")] = true end
        if sc.probe_ver and not opts.smoke then pvers[sc.probe_ver] = true end
        for _, V in ipairs(sc.runs or {}) do
            if V.kind == "guard" then need_guard = true end
            if V.kind == "a0" then vers.v16 = true end
            if V.probe then pvers[V.probe] = true end
        end
    end
    for _, v in ipairs({ "v16", "v15", "rc1" }) do
        if vers[v] and not (opts.smoke and v ~= "rc1") then needed[#needed + 1] = RC_SCRIPTS[v] end
    end
    if opts.merged and not opts.smoke then
        needed[#needed + 1] = RC_SCRIPTS.merged
        if need_guard then needed[#needed + 1] = GUARD_SCRIPTS.v142 end
    end
    for pv in pairs(pvers) do if PROBE_SCRIPTS[pv] and pv ~= "cur" then needed[#needed + 1] = PROBE_SCRIPTS[pv] end end
end
local n_present = 0
for _, s in ipairs(needed) do
    if file_exists(s.path) then
        n_present = n_present + 1
    elseif not missing_seen[s.path] then
        missing_seen[s.path] = true
        missing[#missing + 1] = s
    end
end
if #missing > 0 then
    for _, s in ipairs(missing) do
        io.stderr:write(string.format("缺少被测脚本：%s（%s）\n", s.path,
            s.role == "rc" and ("放刀模块 " .. tostring(s.ver)) or (s.role == "guard" and "防御参照组 v1.4.2" or "测量探针")))
    end
    if not opts.allow_missing or n_present == 0 then
        io.stderr:write("被测脚本还没写好时可以先用 --smoke 验证 mock 本身，或加 --allow-missing 只跑现有的那个。\n")
        os.exit(2)
    end
end

mkdir_p(opts.out)
print(string.format("被测脚本：%s", (function()
    local t = {}
    for _, s in ipairs(needed) do
        if file_exists(s.path) then t[#t + 1] = s.path .. (s.ver and ("（" .. s.ver .. " 场景）") or "") end
    end
    return table.concat(t, " ; ")
end)()))
local total_fail = 0
local results = {}
local n_equiv, n_equiv_bad = 0, 0
local function show(R, name)
    local mark = #R.fails == 0 and "✓" or "✗"
    print(string.format("%s %-34s %-6s 帧 %6d  模拟 %7.2f s  耗时 %5.2f s  失败 %d  警告 %d  UNMOCKED %d", mark, name,
        R.ver or "?", R.frames or 0, R.sim_s or 0, R.real_s or 0, #R.fails, #R.warns, #(R.unmocked or {})))
    local limit = opts.verbose and 1000 or 6
    for i, f in ipairs(R.fails) do
        if i > limit then
            print(string.format("    ……另有 %d 项，见 %s/summary.txt", #R.fails - limit, R.out_dir or "?"))
            break
        end
        print("    ✗ " .. f)
    end
    if opts.verbose then
        for _, f in ipairs(R.warns) do print("    ! " .. f) end
    end
end
for _, sc in ipairs(selected) do
    local bad = false
    if sc.merged_only then
        local runs = {}
        for _, V0 in ipairs(sc.runs or { { key = "merged", kind = "merged", debug = true } }) do
            local V = deep_copy(V0)
            V.subdir = V.key
            V.keep = true
            local R = run_scenario(sc, V)
            R.mname = (V.kind == "guard" or V.kind == "merged") and "AutoGuardGS" or "AutoParryGS"
            runs[V.key] = R
            results[#results + 1] = R
            show(R, sc.name .. "/" .. V.key)
            if #R.fails > 0 then bad = true end
        end
        local F = check_merged_only(sc, runs)
        local lines_ = { "场景 " .. sc.name .. "：跨跑法的检查（MERGE 第 6.5 节）", "" }
        for _, f in ipairs(F.fails) do lines_[#lines_ + 1] = "  ✗ " .. f end
        for _, f in ipairs(F.infos) do lines_[#lines_ + 1] = "  · " .. f end
        lines_[#lines_ + 1] = #F.fails == 0 and "结果：通过" or ("结果：失败 " .. #F.fails .. " 项")
        write_text(opts.out .. "/" .. sc.name .. "/checks.txt", table.concat(lines_, "\n") .. "\n")
        F.ver, F.frames, F.sim_s, F.real_s = "检查", 0, 0, 0
        F.out_dir = opts.out .. "/" .. sc.name
        show(F, sc.name .. "/检查")
        if #F.fails > 0 then bad = true end
        for _, R in pairs(runs) do R.w, R.G, R.P = nil, nil, nil end
    else
        local A = run_scenario(sc, { kind = "a0" })
        results[#results + 1] = A
        show(A, sc.name)
        if #A.fails > 0 then bad = true end
        if comparable(sc) then
            local B = run_scenario(sc, { kind = "merged", debug = true, subdir = "merged_on", transform = true })
            show(B, sc.name .. "/merged_on")
            local C = run_scenario(sc, { kind = "merged", debug = false, subdir = "merged_off", transform = true })
            show(C, sc.name .. "/merged_off")
            if #B.fails > 0 or #C.fails > 0 then bad = true end
            local dB = compare_trace(A.trace, B.trace, "B（merged_on）", true)
            local dC = compare_trace(A.trace, C.trace, "C（merged_off）", false)
            n_equiv = n_equiv + 1
            local out = { "场景 " .. sc.name .. "：逐刀等价（MERGE 第 6.3 节）",
                string.format("A0 请求 %d 次、FIRE %d 行；B 请求 %d 次、FIRE %d 行；C 请求 %d 次", #A.trace.req,
                    (function() local n = 0 for _ in pairs(A.trace.fire) do n = n + 1 end return n end)(), #B.trace.req,
                    (function() local n = 0 for _ in pairs(B.trace.fire) do n = n + 1 end return n end)(), #C.trace.req),
                "A0 计数：" .. (A.trace.counts and string.format("放了 %d 接住 %d（26：%d，27：%d）被弹开 %d 没接住 %d", A.trace.counts.fires,
                    A.trace.counts.catch, A.trace.counts.c26, A.trace.counts.c27, A.trace.counts.recoil, A.trace.counts.nocatch) or "-"),
                "A0 状态行：" .. tostring(A.trace.status),
                string.format("A0 的 RED %d 行、错误 %d 条（比前 20 条的 mod / level / 发生时刻，json、cfg 两个模块不比）；B 的 RES %d 行",
                    #A.trace.red, #A.trace.err, (function() local n = 0 for _ in pairs(B.trace.res) do n = n + 1 end return n end)()),
                "比较项：请求序列（帧、时刻、(2,23)/(2,24)、接受与否）；B 的 FIRE 16 个字段、RES 的 t/outcome/dt/to 逐字比、entered 对 A0 的"
                    .. " FIRE_END；计数（菜单 ↔ A0 记录推算）；RED；错误；状态行（归一化）；引用记账（三组都是 0）", "" }
            for _, d in ipairs(dB) do out[#out + 1] = "  ✗ " .. d end
            for _, d in ipairs(dC) do out[#out + 1] = "  ✗ " .. d end
            out[#out + 1] = (#dB + #dC == 0) and "结果：B、C 对 A0 0 差异" or string.format("结果：差异 %d 项", #dB + #dC)
            write_text(opts.out .. "/" .. sc.name .. "/equiv.txt", table.concat(out, "\n") .. "\n")
            if #dB + #dC > 0 then
                bad = true
                n_equiv_bad = n_equiv_bad + 1
                print(string.format("✗ %-34s 逐刀等价：差异 %d 项（%s/equiv.txt）", sc.name .. "/等价", #dB + #dC, opts.out .. "/" .. sc.name))
                local all = {}
                for _, d in ipairs(dB) do all[#all + 1] = d end
                for _, d in ipairs(dC) do all[#all + 1] = d end
                for i, d in ipairs(all) do
                    if i > (opts.verbose and 1000 or 6) then break end
                    print("    ✗ " .. d)
                end
            else
                print(string.format("✓ %-34s 逐刀等价：B、C 对 A0 0 差异", sc.name .. "/等价"))
            end
            results[#results + 1] = B
            results[#results + 1] = C
        end
    end
    if bad then total_fail = total_fail + 1 end
end
local um_all = {}
for _, R in ipairs(results) do
    for _, u in ipairs(R.unmocked or {}) do
        local key = u:gsub(" ×%d+", "")
        um_all[key] = true
    end
end
local um_list = {}
for k in pairs(um_all) do um_list[#um_list + 1] = k end
table.sort(um_list)
if #um_list > 0 then
    print(string.format("观察项（UNMOCKED 等，去重 %d 条，明细见各场景 summary.txt）：", #um_list))
    for i, u in ipairs(um_list) do
        if i > 12 and not opts.verbose then
            print("    ……")
            break
        end
        print("    ? " .. u)
    end
end
if #missing > 0 then
    print("注意：缺少被测脚本 " .. (function()
        local t = {}
        for _, s in ipairs(missing) do t[#t + 1] = s.path end
        return table.concat(t, " ; ")
    end)() .. "，它的断言都跳过了，只跑了现有的脚本")
end
if opts.merged then
    print(string.format("逐刀等价：%d 个场景比了 B、C 两组，%d 个有差异", n_equiv, n_equiv_bad))
end
print(string.format("%d 个场景，%d 个失败。输出：%s", #selected, total_fail, opts.out))
os.exit(total_fail == 0 and 0 or 1)

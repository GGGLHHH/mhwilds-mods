-- lib/wilds/weapon：武器类型与武器动作参数。
--
-- 武器动作参数（app.user_data.WpXXActionParam）是**所有同种武器共用**的一份，包括 NPC 支援猎人：改了要用 lib/patch 记原值、
-- 按项目约定三处兜底还原。
local LIB = ((...) or error("lib 模块要用 require 载入")):gsub("wilds%.[^.]+$", "")
local ref = require(LIB .. "ref")

local M = {}

local TYPE_ENUM = "app.WeaponDef.TYPE"

-- app.WeaponDef.TYPE 的值，键是游戏自己的枚举名。数值全部实测（2026-10-19 探针 probes/WeaponTypeProbe.lua 读枚举全表）。
-- 注意游戏的内部命名：LONG_SWORD 是**大剑**，太刀叫 TACHI（拿大剑读到 0、换太刀读到 3，实测）。
-- 中文名里只有大剑、太刀是对着实物核对过的，其余按枚举名推断，做那种武器时先拿起来核对一次
M.TYPE = {
    LONG_SWORD = 0,     -- 大剑 Wp00（实测）
    SHORT_SWORD = 1,    -- 片手剑（推断）
    TWIN_SWORD = 2,     -- 双剑（推断）
    TACHI = 3,          -- 太刀（实测）
    HAMMER = 4,         -- 大锤（推断）
    WHISTLE = 5,        -- 狩猎笛（推断）
    LANCE = 6,          -- 长枪（推断）
    GUN_LANCE = 7,      -- 铳枪（推断）
    SLASH_AXE = 8,      -- 斩击斧（推断）
    CHARGE_AXE = 9,     -- 充能斧（推断）
    ROD = 10,           -- 操虫棍（推断）
    BOW = 11,           -- 弓（推断）
    HEAVY_BOWGUN = 12,  -- 重弩（推断）
    LIGHT_BOWGUN = 13,  -- 轻弩（推断）
}

-- 按游戏的枚举名取武器类型的值（例如大剑在枚举里的名字）；拿不到抛错。初始化时取一次
function M.type_value(enum_name) return ref.enum_value(TYPE_ENUM, enum_name) end

-- 武器类型的值 → 游戏的枚举名（调试显示用）；拿不到返回 nil。每次调用都遍历枚举，别放进每帧的热路径
function M.type_name(v)
    local ok, by_value = pcall(ref.enum_map, TYPE_ENUM)
    return ok and by_value[v] or nil
end

-- 这种武器的动作参数（大剑是 Wp00ActionParam：防御角度、蓄力过热时间等）。
-- PlayerManager 或 Catalog 暂时为 nil 时返回 nil：标题画面、读盘时 PlayerManager 已在而 Catalog 未建（推测）
function M.action_param(wtype)
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local cat = pm and pm:call("get_Catalog")
    return cat and cat:call("getWeaponActionParam(app.WeaponDef.TYPE)", wtype)
end

return M

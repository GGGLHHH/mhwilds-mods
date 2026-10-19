-- lib/wilds/enemy：怪物。
local M = {}

-- 攻击来源是不是怪物（小怪也算）。T_CharacterBase 传 sdk.typeof("app.CharacterBase")，初始化时取一次
function M.is_enemy(game_object, T_CharacterBase)
    if not game_object then return false end
    local chara = game_object:call("getComponent(System.Type)", T_CharacterBase)
    return chara ~= nil and chara:get_type_definition():is_a("app.EnemyCharacter")
end

-- 按 SystemIndex（攻击预告里的 EmSystemIndex）找怪物本体 app.EnemyCharacter；链上任一环为 nil 返回 nil。
-- 路径 2026-10-11 MCP 核对：EnemyManager:findEnemy_SystemIndex(Int32) → app.cEnemyManageInfo → get_Character()
function M.by_system_index(idx)
    local mgr = sdk.get_managed_singleton("app.EnemyManager")
    if not mgr then return nil end
    local info = mgr:call("findEnemy_SystemIndex(System.Int32)", idx)
    if not info then return nil end
    return info:call("get_Character")
end

return M

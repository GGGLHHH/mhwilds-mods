-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 GGG <1635656638@qq.com>
-- lib/wilds/player：主玩家（本机猎人）与它的当前动作。所有武器通用。
--
-- 路径（NOTES「角色与动作」）：app.PlayerManager:getMasterPlayer() → cPlayerManageInfo
--   :get_Character() → app.HunterCharacter；:get_BaseActionController() → ace.cActionController；
--   动作 ID = ace.ACTION_ID { _Category, _Index }
local M = {}

function M.master()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    return pm and pm:call("getMasterPlayer")
end

function M.hunter()
    local p = M.master()
    return p and p:call("get_Character")
end

-- 帧开头的快照：hunter, 地址, 武器类型, 动作分类, 动作编号。调用顺序固定：主角 → 地址 → 武器 → 动作控制器 → 动作 ID。
-- 没有主角只返回 nil；动作 ID 读不到时后两个为 nil。同一帧里多个部件共用一份快照，别各读各的
function M.snapshot()
    local hunter = M.hunter()
    if not hunter then return nil end
    local addr = hunter:get_address()
    local wtype = hunter:call("get_WeaponType")
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl and ctrl:call("get_CurrentActionID")
    if not id then return hunter, addr, wtype end
    return hunter, addr, wtype, id:get_field("_Category"), id:get_field("_Index")
end

-- 现读当前动作（钩子里用：受击结算在帧中途，动作可能已经和帧开头的快照不同）。读不到会抛错
function M.current_action(hunter)
    local id = hunter:call("get_BaseActionController"):call("get_CurrentActionID")
    return id:get_field("_Category"), id:get_field("_Index")
end

-- 调试用：当前动作的简短名字，例如 "(1,14) cIdle"
function M.action_text(hunter)
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl:call("get_CurrentActionID")
    local act = ctrl:call("get_CurrentAction")
    local name = act and act:get_type_definition():get_full_name() or "?"
    name = name:gsub("app%.Wp%d%dAction%.", ""):gsub("app%.PlayerCommonAction%.", "")
    return string.format("(%d,%d) %s", id:get_field("_Category"), id:get_field("_Index"), name)
end

return M

-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 GGG <1635656638@qq.com>
-- lib/patch：共享参数的临时改写。先记原值再改，还原时按记录写回。
--
-- 为什么要它：游戏的 user_data 参数（武器动作参数等）往往所有角色共用，包括 NPC 支援猎人，改了不还原就是永久改了游戏。
-- 项目约定改共享参数必须有还原路径，结算后、每帧开头、re.on_script_reset 三处兜底（CLAUDE.md）。这个模块只管「记原值、写回」，
-- 什么时候还原由调用方在这三处调 restore / restore_each。
--
-- 用法：
--   local angle = patch.new()
--   if angle:begin() then angle:set(param, "_GuardDegree", 360.0) end   -- begin 返回 false = 上次的还没还原，别再记一次原值
--   ...
--   angle:restore()        -- 严格：写回抛错就停下，记录留着，下次再还原
--   angle:restore_each()   -- 宽松：每项单独 pcall，写不回的放弃，记录一律清掉
local Patch = {}
Patch.__index = Patch

local M = {}

function M.new() return setmetatable({ items = nil }, Patch) end

-- 开始一次改写。已经改过还没还原时返回 false（例如同一帧连续触发）：这时再记原值，就会把改过的值当成原值
function Patch:begin()
    if self.items then return false end
    self.items = {}
    return true
end

function Patch:active() return self.items ~= nil end
function Patch:count() return self.items and #self.items or 0 end

-- 记下 obj.field 的原值再改成 value。先记后改：改到一半抛错，已经记下的那几项照样能还原
function Patch:set(obj, field, value)
    local items = self.items
    if not items then
        items = {}
        self.items = items
    end
    items[#items + 1] = { obj = obj, field = field, value = obj:get_field(field) }
    obj:set_field(field, value)
end

-- 还原按后进先出（和改的顺序相反）：同一个字段改过两次时，最后写回的才是真正的原值
function Patch:restore()
    local items = self.items
    if not items then return end
    for i = #items, 1, -1 do
        local it = items[i]
        it.obj:set_field(it.field, it.value)
    end
    self.items = nil
end

function Patch:restore_each()
    local items = self.items
    if not items then return end
    for i = #items, 1, -1 do
        local it = items[i]
        pcall(function() it.obj:set_field(it.field, it.value) end)
    end
    self.items = nil
end

return M

-- lib/wilds/action：请求猎人切动作。所有武器通用。
--
-- 关键规律（NOTES「改状态 vs 改动作」，实测）：改动作必须在帧开头（re.on_pre_application_entry("UpdateBehavior")）
-- 调 changeActionRequest，让动作控制器走正常的进入流程；被拒绝就每帧重试。
--   ✗ changeActionImmediate 在受击结算中途硬切：动作对象换了，动画和霸体没跟上
--   ✗ 从 MCP 的 HTTP 线程调用会被拒（不在主线程）
local M = {}

M.LAYER_BASE = 0
M.REQUEST_SIG = "changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)"

-- 造一个 ace.ACTION_ID 值类型（{ _Category, _Index }）。可以在初始化时造好反复用
function M.id(cat, idx)
    local id = ValueType.new(sdk.find_type_definition("ace.ACTION_ID"))
    id:set_field("_Category", cat)
    id:set_field("_Index", idx)
    return id
end

-- 在基础层请求切到 id；返回游戏是否接受（被拒时下一帧再试）
function M.request(hunter, id)
    return hunter:call(M.REQUEST_SIG, M.LAYER_BASE, id, false)
end

return M

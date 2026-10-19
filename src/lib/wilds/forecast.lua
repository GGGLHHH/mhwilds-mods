-- lib/wilds/forecast：怪物攻击预告（本来给 NPC AI 用的 cMsgEmAttackAreaResult）的读取。只读，不跨帧持有任何对象。
--
-- 机制和实测结论见 NOTES「攻击预告」「倒数怎么生成」：
--   - 怪物每切一次动作，就给目标猎人发一条消息；在 cMasterPlayerControllerEntity.receiveGameMessage 里截取。每个结果对象
--     只发一条消息，之后内容由接收端每帧更新，要跨帧持有结果对象（只 add_ref、不手动 release，见 NOTES「引用记账」）
--   - 结果 AttackAreaResult 的 get_DetectedDataList() 每段攻击一条 DetectedData：ResultType、HitStartRemainFrame /
--     HitEndRemainFrame（System.Single，1/60 s，按怪物 1 倍速的名义帧、接收端按真实时间倒数）、ShellIndex、AttackParam
--   - 怪物按 CoreState 倍速推进，C > 1 时攻击比倒数早到；按真实时间换算见 AutoGuardGS/parry.lua 的 E5c
local M = {}

M.MSG_TYPE = "app.game_message.cMsgEmAttackAreaResult"

-- 结果的全部条目：{ d = DetectedData, key = 条目地址, rt = ResultType, hs, he }。列表为 nil 返回空表；
-- 数据形态不对（个数不是整数、条目为 nil、剩余帧不是数）抛错
function M.read_items(r)
    local list = r:call("get_DetectedDataList")
    if not list then return {} end
    local n = math.tointeger(list:call("get_Count"))
    if not n then error("get_Count is not an integer") end
    local out = {}
    for i = 0, n - 1 do
        local d = list:call("get_Item", i)
        if not d then error("get_Item returned nil") end
        local hs, he = d:call("get_HitStartRemainFrame"), d:call("get_HitEndRemainFrame")
        if type(hs) ~= "number" or type(he) ~= "number" then error("remain frame is not a number") end
        out[#out + 1] = { d = d, key = d:get_address(), rt = d:call("get_ResultType"), hs = hs, he = he }
    end
    return out
end

-- 这段攻击是不是弹体：ShellIndex 是 Nullable<Int32>，有值就是。REF 的返回形态三种都认：nil、拆箱成数字、
-- 带 _HasValue 的值类型；别的形态抛错
function M.has_shell(d)
    local v = d:call("get_ShellIndex")
    if v == nil then return false end
    if type(v) == "number" then return true end
    if type(v) ~= "userdata" then error("ShellIndex returned " .. type(v)) end
    local hv = v:get_field("_HasValue")
    if type(hv) ~= "boolean" then error("ShellIndex._HasValue=" .. tostring(hv)) end
    return hv
end

-- 发消息的怪物在本机是不是主控（联机副本为 false）。发送者 get_SendGameObject 就是怪物本体（第 1 轮 435/435，实测）。
-- T_ENEMY 传 sdk.typeof("app.EnemyCharacter")。链上哪一环是 nil 返回 nil（调用方按主机处理）；返回值不是布尔就抛错
function M.read_master(msg, T_ENEMY)
    local go = msg:call("get_SendGameObject")
    local enemy = go and go:call("getComponent(System.Type)", T_ENEMY)
    local holder = enemy and enemy:get_field("_Context")
    if not holder then return nil end
    local m = holder:call("get_IsMaster")
    if type(m) ~= "boolean" then error("get_IsMaster returned " .. tostring(m)) end
    return m
end

return M

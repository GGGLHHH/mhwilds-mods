-- lib/ui：REF 菜单（imgui）的出错隔离。
--
-- imgui 的树节点必须配对 tree_pop，画到一半抛错不 pop 会让整个 REF 菜单的栈错乱，所以菜单一律包在 U.tree 里。
-- 菜单分块用 U.part 画：一块出错只把这一块换成一行提示，不连累别的块；retry 秒后再试一次（出错多半是瞬时的，切场景、读盘；
-- 永久降级就要 Reset 才能再看到这块控件，而一直出错时也不至于每帧画一遍出错的代码）。
--
-- 用法：
--   local U = ui.new({ on_error = function(err) L.warn_err("ui", err) end })
--   re.on_draw_ui(function()
--       U.tree("我的 Mod v1.0##MyMod", function()
--           U.part("main", draw_main)
--           imgui.separator()
--           U.part("stats", draw_stats)
--       end)
--   end)
local M = {}

M.COLOR = { RED = 0xFF4040FF, GRAY = 0xFFA0A0A0 }   -- imgui 颜色是 ABGR

-- opts.on_error(err)：出错时调用；opts.retry：出错后多少秒内只画提示，默认 2
function M.new(opts)
    local on_error, retry = opts.on_error, opts.retry or 2.0
    local bad = {}   -- [块名] = 出错的时刻
    local U = {}

    function U.part(name, fn)
        local t = bad[name]
        if t and os.clock() - t < retry then
            imgui.text("（菜单出错，见日志 re2_framework_log.txt）")
            return
        end
        bad[name] = nil
        local ok, err = pcall(fn)
        if not ok then
            bad[name] = os.clock()
            on_error(err)
        end
    end

    -- 树节点：label 里用 "##ID" 固定 imgui 的内部 ID（中文标签改了也不会和别的控件撞 ID）
    function U.tree(label, fn)
        local ok, opened = pcall(imgui.tree_node, label)
        if not ok then
            on_error(opened)
            return
        end
        if not opened then return end
        local ok2, err = pcall(fn)
        if not ok2 then on_error(err) end
        imgui.tree_pop()        -- 出错也要配对 tree_pop
    end
    return U
end

return M

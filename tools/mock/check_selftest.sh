#!/usr/bin/env bash
# tools/mock/check_selftest.sh：tools/check.sh 的自测（审查修订：「不许手动扣引用」那一项原来漏了几种写法）。
# 只用临时目录：在里面写几份最小的脚本（check.sh 对 src/ 下全部文件和 AutoParryCalib.lua 查引用记账），逐条核对：
#   1. 手动扣引用的各种写法都要判失败：x:release()、x.release(x)、pcall(x.release, x)、x["release"](x)、local f = x['release']、
#      x : release ()、force_release()、x:add_ref_permanent()
#   2. 不该误判：release_all_tracks()、local function release_all_tracks()、写在注释里的 x:release()、x.released = 1
#   3. 字形检查：src/ 下的代码里有 °（U+00B0）判失败，只在注释里有不算
#   4. require 的命名空间：src/lib/ 里写死模块名、mod 里 require 别的 mod 的模块判失败；相对前缀、自己命名空间的不误判
# 用法：bash tools/mock/check_selftest.sh [--keep]   （--keep 留下临时目录）
#      CHECK=路径 可指定被测的 check.sh（变异测试用：比如换回旧的正则，这里必须报失败）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHECK="${CHECK:-$REPO/tools/check.sh}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/check_selftest.XXXXXX")"
FAILS=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; FAILS=$((FAILS + 1)); }

# 被测的 check.sh 拷进临时「仓库」的 tools/ 下（它会 cd 到自己的上一级目录），被检查的文件用绝对路径传
mkdir -p "$TMP/repo/tools"
cp "$CHECK" "$TMP/repo/tools/check.sh"

n=0
# $1 = 期望（fail / pass），$2 = 说明，$3 = 相对临时目录的文件路径，其余 = 文件内容（每个参数一行）
case_lua() {
    local want="$1" what="$2" rel="$3"
    shift 3
    n=$((n + 1))
    local f="$TMP/c$n/$rel"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$@" > "$f"
    bash "$TMP/repo/tools/check.sh" "$f" > "$TMP/out$n.txt" 2>&1
    local rc=$?
    if [ "$want" = "fail" ] && [ $rc -ne 0 ] && grep -q "手动扣引用\|字体里可能没有\|命名空间" "$TMP/out$n.txt"; then
        ok "判失败：$what"
    elif [ "$want" = "pass" ] && [ $rc -eq 0 ]; then
        ok "不误判：$what"
    else
        bad "$what（期望 $want，退出码 $rc）：$(tr '\n' ' ' < "$TMP/out$n.txt" | cut -c1-200)"
    fi
}

echo "1. 手动扣引用的写法"
case_lua fail 'x:release()' src/AutoGuardGS.lua 'local r = {}' 'r:release()'
case_lua fail 'x.release(x)' src/AutoGuardGS.lua 'local r = {}' 'r.release(r)'
case_lua fail 'pcall(x.release, x)' src/AutoGuardGS.lua 'local r = {}' 'pcall(r.release, r)'
case_lua fail 'x["release"](x)' src/AutoGuardGS.lua 'local r = {}' 'r["release"](r)'
case_lua fail "local f = x['release']" src/AutoGuardGS.lua 'local r = {}' "local f = r['release']" 'f(r)'
case_lua fail 'x : release ()' src/AutoGuardGS.lua 'local r = {}' 'r : release ()'
case_lua fail 'force_release()' src/AutoGuardGS.lua 'local function force_release() end' 'force_release()'
case_lua fail 'x:add_ref_permanent()' src/AutoGuardGS.lua 'local r = {}' 'r:add_ref_permanent()'
case_lua fail '探针里的 x.release(x)' probes/AutoParryCalib.lua 'local r = {}' 'r.release(r)'

echo "2. 不该误判"
case_lua pass 'release_all_tracks()' src/AutoGuardGS.lua 'local function release_all_tracks() end' 'release_all_tracks()'
case_lua pass '注释里的 x:release()' src/AutoGuardGS.lua 'local r = {}' 'r.x = 1   -- 不调 r:release()，等 REF 回收'
case_lua pass 'x.released = 1' src/AutoGuardGS.lua 'local r = {}' 'r.released = 1'
case_lua pass '别的文件名不查引用记账' probes/OtherProbe.lua 'local r = {}' 'r:release()'

case_lua fail 'mod 子模块里的 x:release()' src/mods/ModA/reframework/autorun/ModA/part.lua 'local r = {}' 'r:release()'

echo "3. 字形"
case_lua fail 'src/ 代码里的 °' src/AutoGuardGS.lua 'local s = "35°"' 'return s'
case_lua pass '注释里的 °' src/AutoGuardGS.lua 'local s = "35"   -- 左右各 35°' 'return s'

echo "4. require 的命名空间"
case_lua fail '库里写死模块名' src/lib/x.lua 'local u = require("util")' 'return u'
case_lua fail '库里写死模块名（不带括号）' src/lib/wilds/y.lua "local u = require 'MyMod.lib.util'" 'return u'
case_lua pass '库里用相对前缀' src/lib/x.lua 'local LIB = ((...) or "x."):gsub("[^.]+$", "")' 'local u = require(LIB .. "util")' 'return u'
case_lua pass '注释里的 require("x")' src/lib/x.lua 'local u = 1   -- 不写 require("util")' 'return u'
case_lua fail 'mod 里 require 别的 mod' src/mods/ModA/reframework/autorun/ModA.lua 'local x = require("ModB.lib.util")' 'return x'
case_lua fail 'mod 里 require 不带命名空间的名字' src/mods/ModA/reframework/autorun/ModA/part.lua 'local x = require("util")' 'return x'
case_lua pass 'mod 里 require 自己的模块' src/mods/ModA/reframework/autorun/ModA.lua 'local x = require("ModA.lib.util")' 'local y = require("ModA.part")' 'return x, y'
case_lua pass '模板里 require 自己的模块' templates/ModT/reframework/autorun/ModT.lua 'local x = require("ModT.lib.util")' 'return x'

if [ $KEEP -eq 1 ]; then
    echo "临时目录留着：$TMP"
else
    rm -rf "$TMP"
fi
if [ $FAILS -eq 0 ]; then
    echo "check.sh 自测：$n 条全部通过"
    exit 0
fi
echo "check.sh 自测：$FAILS 条失败（共 $n 条）"
exit 1

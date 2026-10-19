#!/usr/bin/env bash
# 一键全测（改完库、改完 mod、改完工具都跑这个；提交前必须全过）。从快到慢：
#   1. tools/check.sh                 语法、意外的全局变量、引用记账、字形、require 命名空间
#   2. tools/test/lib_test.lua        共享库单元测试
#   3. tools/build.sh                 组装 build/<Mod>/（mock 测的就是这份，和部署、发布的是同一份）
#   4. 模板冒烟                        组装 templates/ModTemplate，用假 REF 载入跑几秒
#   5. check.sh、deploy.sh 的自测     只用临时目录，不碰游戏目录
#   6. mock 合并模式（约 4 分钟）       183 个场景；放刀逐刀和归档的 v1.6 比，防御的副作用轨迹和归档的 v1.4.2 比
# 用法：tools/test.sh [--quick]    --quick 跳过第 6 步
set -u
cd "$(dirname "$0")/.."
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
LUA="${LUA:-lua}"

fail=0
step() { echo; echo "== $1"; }
run() {   # $1 = 说明，其余 = 命令
    local what="$1"
    shift
    if "$@"; then echo "-- $what：通过"; else echo "-- $what：失败"; fail=1; fi
}

step "1/6 静态检查"
run "check.sh" bash tools/check.sh
step "2/6 共享库单元测试"
run "lib_test" "$LUA" tools/test/lib_test.lua
step "3/6 组装"
run "build.sh" bash tools/build.sh
step "4/6 模板冒烟"
run "组装模板" env MODS_DIR=templates BUILD_DIR=tools/mock/out/template_build bash tools/build.sh ModTemplate
run "template_smoke" "$LUA" tools/test/template_smoke.lua \
    tools/mock/out/template_build/ModTemplate/reframework/autorun/ModTemplate.lua
step "5/6 工具自测"
run "check_selftest" bash tools/mock/check_selftest.sh
run "deploy_selftest" bash tools/mock/deploy_selftest.sh
if [ $QUICK -eq 0 ]; then
    step "6/6 mock 合并模式"
    run "mock --merged" "$LUA" tools/mock/run.lua --merged
else
    step "6/6 mock 合并模式：--quick 跳过"
fi

echo
if [ $fail -eq 0 ]; then echo "全部通过"; else echo "有失败，见上面标「失败」的步骤"; fi
exit $fail

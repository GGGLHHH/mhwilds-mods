#!/usr/bin/env bash
# tools/mock/deploy_selftest.sh：tools/deploy.sh 的废弃清单自测（docs/autoparry/MERGE.md 第 6.7、7.1 节）。
# 只用临时目录：把 deploy.sh、check.sh 和 src/ 拷进一个临时「仓库」，MHWILDS_DIR 指向临时搭的假游戏目录，逐条核对：
#   1. 游戏 autorun 里有旧的 AutoParryGS.lua → 挪进 reframework/autorun_disabled/（内容不变，不删除），新文件照常复制，别的文件不碰
#   2. 再跑一次 → 什么都不挪
#   3. autorun_disabled/ 里已有同名文件 → 新挪的文件名加时间戳，旧的不覆盖
#   4. 清单里的文件也在 src/ 里 → 报错退出，一个文件都不复制
#   5. 挪动失败（autorun_disabled 是个文件、建不了目录）→ 报错退出，一个文件都不复制，旧脚本原样留在 autorun
#   6. --dry-run → 列出要挪、要复制的，什么都不改
# 用法：bash tools/mock/deploy_selftest.sh [--keep]   （--keep 留下临时目录，路径打印出来）
#      DEPLOY=路径 可指定被测的 deploy.sh（变异测试用：比如把挪动改成删除，这里必须报失败）
# 绝不碰真的游戏目录：MHWILDS_DIR 一律指向临时目录。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEPLOY="${DEPLOY:-$REPO/tools/deploy.sh}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy_selftest.XXXXXX")"
case "$TMP" in
    *MonsterHunterWilds*) echo "临时目录不对：$TMP" >&2; exit 2 ;;
esac
FAILS=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; FAILS=$((FAILS + 1)); }

# 临时仓库：被测的 deploy.sh、check.sh、src/
mk_repo() {
    local r="$1"
    mkdir -p "$r/tools"
    cp "$DEPLOY" "$r/tools/deploy.sh"
    cp "$REPO/tools/check.sh" "$r/tools/check.sh"
    cp -r "$REPO/src" "$r/src"
}
# 假游戏目录：REF 在、autorun 里有旧放刀脚本、别的 mod 和探针、一份旧的 AutoGuardGS.lua
mk_game() {
    local g="$1"
    mkdir -p "$g/reframework/autorun" "$g/reframework/data"
    printf -- '-- old standalone AutoParryGS v1.6\n' > "$g/reframework/autorun/AutoParryGS.lua"
    printf -- '-- old AutoGuardGS v1.4.2\n' > "$g/reframework/autorun/AutoGuardGS.lua"
    printf -- '-- other mod\n' > "$g/reframework/autorun/HitboxViewer.lua"
    printf -- '-- probe\n' > "$g/reframework/autorun/AttackTimingProbe.lua"
    printf '{"auto_parry":true,"parry_lead":28,"cfg_ver":3}' > "$g/reframework/data/AutoParryGS.json"
}
run_deploy() {   # $1 = 仓库，$2 = 游戏目录，其余是 deploy 的参数；输出进 $TMP/out.txt，返回退出码
    local r="$1" g="$2"
    shift 2
    MHWILDS_DIR="$g" bash "$r/tools/deploy.sh" "$@" > "$TMP/out.txt" 2>&1
}
same() { cmp -s "$1" "$2"; }

R="$TMP/repo"
G="$TMP/game"
mk_repo "$R"
mk_game "$G"
NEW="$R/src/reframework/autorun/AutoGuardGS.lua"
if [ -e "$R/src/reframework/autorun/AutoParryGS.lua" ]; then
    echo "src/ 里还有 AutoParryGS.lua：合并没做完（MERGE 第 6.8 节第 1 条），下面第 1 条会按「清单和 src 冲突」失败"
fi

echo "1. 旧的 AutoParryGS.lua 挪进 autorun_disabled，新文件复制，别的不碰"
run_deploy "$R" "$G"; rc=$?
if [ $rc -eq 0 ]; then ok "退出码 0"; else bad "退出码 $rc：$(tail -3 "$TMP/out.txt")"; fi
[ ! -e "$G/reframework/autorun/AutoParryGS.lua" ] && ok "autorun 里没有 AutoParryGS.lua 了" || bad "autorun 里还有 AutoParryGS.lua"
if [ -f "$G/reframework/autorun_disabled/AutoParryGS.lua" ] \
    && grep -q "old standalone AutoParryGS" "$G/reframework/autorun_disabled/AutoParryGS.lua"; then
    ok "挪到了 autorun_disabled/AutoParryGS.lua，内容不变（没删）"
else
    bad "autorun_disabled/AutoParryGS.lua 不在或内容变了"
fi
same "$NEW" "$G/reframework/autorun/AutoGuardGS.lua" && ok "AutoGuardGS.lua 已更新" || bad "AutoGuardGS.lua 没更新"
grep -q "other mod" "$G/reframework/autorun/HitboxViewer.lua" && grep -q "probe" "$G/reframework/autorun/AttackTimingProbe.lua" \
    && ok "别的 mod、探针原样" || bad "别的 mod 或探针被动了"
grep -q "cfg_ver" "$G/reframework/data/AutoParryGS.json" && ok "data 目录的旧配置原样" || bad "data 目录被动了"
grep -q "↷ reframework/autorun/AutoParryGS.lua → reframework/autorun_disabled/AutoParryGS.lua" "$TMP/out.txt" \
    && ok "输出里有 ↷ 那一行" || bad "输出里没有 ↷ 那一行：$(cat "$TMP/out.txt" | tail -5)"
grep -q "撤下了 1 个废弃文件" "$TMP/out.txt" && ok "汇总：撤下了 1 个废弃文件" || bad "汇总不对：$(tail -1 "$TMP/out.txt")"

echo "2. 再跑一次：什么都不挪"
cp "$G/reframework/autorun_disabled/AutoParryGS.lua" "$TMP/disabled_before"
run_deploy "$R" "$G"; rc=$?
[ $rc -eq 0 ] && ok "退出码 0" || bad "退出码 $rc"
! grep -q "↷" "$TMP/out.txt" && ok "没有挪任何文件" || bad "又挪了文件：$(grep "↷" "$TMP/out.txt")"
same "$TMP/disabled_before" "$G/reframework/autorun_disabled/AutoParryGS.lua" && ok "autorun_disabled 里的文件不变" \
    || bad "autorun_disabled 里的文件变了"
[ "$(ls "$G/reframework/autorun_disabled" | wc -l)" -eq 1 ] && ok "autorun_disabled 里只有 1 个文件" || bad "autorun_disabled 里多了文件"

echo "3. autorun_disabled 里已有同名文件：新挪的加时间戳，旧的不覆盖"
printf -- '-- second old copy\n' > "$G/reframework/autorun/AutoParryGS.lua"
run_deploy "$R" "$G"; rc=$?
[ $rc -eq 0 ] && ok "退出码 0" || bad "退出码 $rc"
same "$TMP/disabled_before" "$G/reframework/autorun_disabled/AutoParryGS.lua" && ok "原来那份没被覆盖" || bad "原来那份被覆盖了"
stamped=$(ls "$G/reframework/autorun_disabled" | grep -E '^AutoParryGS\.[0-9]{8}-[0-9]{6}(-[0-9]+)?\.lua$' || true)
if [ -n "$stamped" ] && grep -q "second old copy" "$G/reframework/autorun_disabled/$stamped"; then
    ok "新挪的叫 $stamped"
else
    bad "没有带时间戳的新文件：$(ls "$G/reframework/autorun_disabled")"
fi
[ ! -e "$G/reframework/autorun/AutoParryGS.lua" ] && ok "autorun 里又清掉了" || bad "autorun 里还在"

echo "4. 清单里的文件也在 src/ 里：报错退出，一个文件都不复制"
R4="$TMP/repo4"
G4="$TMP/game4"
mk_repo "$R4"
mk_game "$G4"
printf -- '-- accidentally kept\n' > "$R4/src/reframework/autorun/AutoParryGS.lua"
run_deploy "$R4" "$G4"; rc=$?
[ $rc -ne 0 ] && ok "退出码 $rc（非 0）" || bad "退出码 0（应当报错）"
grep -q "old AutoGuardGS v1.4.2" "$G4/reframework/autorun/AutoGuardGS.lua" && ok "AutoGuardGS.lua 没被复制" \
    || bad "AutoGuardGS.lua 被复制了"
grep -q "old standalone AutoParryGS" "$G4/reframework/autorun/AutoParryGS.lua" && ok "旧的 AutoParryGS.lua 没被动" \
    || bad "旧的 AutoParryGS.lua 被动了"
grep -q "也在 src/ 里" "$TMP/out.txt" && ok "报错写明「也在 src/ 里」" || bad "报错原因不对：$(tail -2 "$TMP/out.txt")"

echo "5. 挪动失败（autorun_disabled 是个文件，建不了目录）：报错退出，一个文件都不复制"
G5="$TMP/game5"
mk_game "$G5"
printf 'not a dir' > "$G5/reframework/autorun_disabled"
run_deploy "$R" "$G5"; rc=$?
[ $rc -ne 0 ] && ok "退出码 $rc（非 0）" || bad "退出码 0（应当报错）"
grep -q "old standalone AutoParryGS" "$G5/reframework/autorun/AutoParryGS.lua" && ok "旧脚本原样留在 autorun" \
    || bad "旧脚本不见了"
grep -q "old AutoGuardGS v1.4.2" "$G5/reframework/autorun/AutoGuardGS.lua" && ok "AutoGuardGS.lua 没被复制（不会新旧同时在 autorun）" \
    || bad "AutoGuardGS.lua 被复制了"

echo "6. --dry-run：照样检查，列出要挪、要复制的，什么都不改"
G6="$TMP/game6"
mk_game "$G6"
run_deploy "$R" "$G6" --dry-run; rc=$?
[ $rc -eq 0 ] && ok "退出码 0" || bad "退出码 $rc"
grep -q "↷ reframework/autorun/AutoParryGS.lua" "$TMP/out.txt" && grep -q "→ reframework/autorun/AutoGuardGS.lua" "$TMP/out.txt" \
    && ok "列出了要挪、要复制的" || bad "没列全：$(cat "$TMP/out.txt" | tail -5)"
grep -q "old standalone AutoParryGS" "$G6/reframework/autorun/AutoParryGS.lua" && [ ! -e "$G6/reframework/autorun_disabled" ] \
    && grep -q "old AutoGuardGS v1.4.2" "$G6/reframework/autorun/AutoGuardGS.lua" && ok "什么都没改" || bad "--dry-run 改了东西"

if [ $KEEP -eq 1 ]; then echo "临时目录留着：$TMP"; else rm -rf "$TMP"; fi
if [ $FAILS -eq 0 ]; then
    echo "deploy.sh 自测：全部通过"
    exit 0
fi
echo "deploy.sh 自测：$FAILS 项失败"
exit 1

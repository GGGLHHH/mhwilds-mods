#!/usr/bin/env bash
# 检查所有 Lua 脚本：
#   1. 语法（luac -p）
#   2. 意外的全局变量访问——抓拼写错误和漏写的 local。
#      Lua 里用到未定义的变量不报错、只当 nil，要到游戏里运行才出问题，所以提前查。
#   3. AutoGuardGS.lua（放刀逻辑并入它，AutoGuardGS v1.5，docs/autoparry/MERGE.md）/ AutoParryCalib.lua 里不许有手动扣引用的
#      调用（V16 第 5 节）。
#   4. src/ 下的脚本，代码里（不算注释）不许有字体里可能没有的字符：°（U+00B0）、全角空格（U+3000）（MERGE 第 6.7 节；
#      菜单文字里出现就是方框。注释不查：头注释里写过「35°」）。
# 用法：tools/check.sh [文件...]   不带参数时检查 src/ 和 probes/ 下的全部 .lua（tools/archive/ 的归档版不在默认范围）
set -u
cd "$(dirname "$0")/.."

LUAC="${LUAC:-$(command -v luac 2>/dev/null || echo /c/Users/Administrator/AppData/Local/Programs/Lua/bin/luac.exe)}"
if [ ! -x "$LUAC" ]; then
    echo "找不到 luac（可用 LUAC 环境变量指定路径）" >&2
    exit 2
fi

# REFramework 提供的全局 API + 用到的 Lua 标准库
ALLOWED=" sdk re imgui log json ValueType draw fs pairs ipairs pcall tostring tonumber string math table type error select next print os setmetatable getmetatable rawget rawset rawequal rawlen assert "

# 第 3 项：手动扣引用的写法。x:release(、x.release(、把 .release 当函数传出去（pcall(x.release, x)）、x["release"] / x['release']，
# 点、冒号、括号前后都可以有空白；另有 force_release、add_ref_permanent。不会误中 release_all_tracks 这类名字（release 前面
# 不是点或冒号，后面也不是括号或逗号）。原来的写法漏了 r.release(r)、r["release"](r)、r : release()（审查修订，
# 自测 tools/mock/check_selftest.sh）
REF_BAD_RE="[.:][[:space:]]*release[[:space:]]*[(,)]|\[[[:space:]]*[\"']release[\"'][[:space:]]*\]|force_release|add_ref_permanent"

if [ $# -gt 0 ]; then
    files=("$@")
else
    mapfile -t files < <(find src probes -name '*.lua' | sort)
fi

fail=0
for f in "${files[@]}"; do
    if ! out=$("$LUAC" -p "$f" 2>&1); then
        echo "✗ $f 语法错误：$out"
        fail=1
        continue
    fi
    bad=""
    while read -r name; do
        case "$ALLOWED" in *" $name "*) ;; *) bad="$bad $name" ;; esac
    done < <("$LUAC" -l -l -p "$f" | grep -oE '(GET|SET)TABUP.*_ENV "[A-Za-z_][A-Za-z0-9_]*"' | grep -oE '"[^"]+"' | tr -d '"' | sort -u)
    # 3. 引用记账（docs/autoparry/V16.md 第 5、11 节）：放刀逻辑和探针跨帧持有游戏对象时只 add_ref、不手动 release——
    #    REF 按地址给整个 Lua 状态记一份引用，谁先手动扣，同时持有的另一个脚本就拿着悬空指针（2c 实测）。
    #    查法见上面的 REF_BAD_RE；注释不算。
    #    合并后放刀逻辑在 AutoGuardGS.lua 里（它自己的状态还原函数叫 restore_hit_state，不会撞上）
    refbad=""
    case "$(basename "$f")" in
        AutoGuardGS.lua|AutoParryCalib.lua)
            refbad=$(sed -E 's/--.*$//' "$f" | grep -nE "$REF_BAD_RE" || true)
            ;;
    esac
    # 4. 字形：只查 src/ 下的正式脚本（探针的调试文字不进菜单约定），去掉注释后查
    glyph=""
    case "$f" in
        src/*|./src/*|*/src/*)
            glyph=$(sed -E 's/--.*$//' "$f" | grep -n -e '°' -e '　' || true)
            ;;
    esac
    if [ -n "$bad" ]; then
        echo "✗ $f 意外的全局变量：$bad"
        fail=1
    elif [ -n "$refbad" ]; then
        echo "✗ $f 有手动扣引用的调用（V16 第 5 节：只 add_ref、不 release）："
        echo "$refbad" | sed 's/^/    /'
        fail=1
    elif [ -n "$glyph" ]; then
        echo "✗ $f 代码里有字体里可能没有的字符（° 或全角空格，菜单里会显示成方框）："
        echo "$glyph" | sed 's/^/    /'
        fail=1
    else
        echo "✓ $f"
    fi
done
exit $fail

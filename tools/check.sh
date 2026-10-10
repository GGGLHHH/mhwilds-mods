#!/usr/bin/env bash
# 检查所有 Lua 脚本：
#   1. 语法（luac -p）
#   2. 意外的全局变量访问——抓拼写错误和漏写的 local。
#      Lua 里用到未定义的变量不报错、只当 nil，要到游戏里运行才出问题，所以提前查。
# 用法：tools/check.sh [文件...]   不带参数时检查 src/ 和 probes/ 下的全部 .lua
set -u
cd "$(dirname "$0")/.."

LUAC="${LUAC:-$(command -v luac 2>/dev/null || echo /c/Users/Administrator/AppData/Local/Programs/Lua/bin/luac.exe)}"
if [ ! -x "$LUAC" ]; then
    echo "找不到 luac（可用 LUAC 环境变量指定路径）" >&2
    exit 2
fi

# REFramework 提供的全局 API + 用到的 Lua 标准库
ALLOWED=" sdk re imgui log json ValueType draw fs pairs ipairs pcall tostring tonumber string math table type error select next print os "

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
    if [ -n "$bad" ]; then
        echo "✗ $f 意外的全局变量：$bad"
        fail=1
    else
        echo "✓ $f"
    fi
done
exit $fail

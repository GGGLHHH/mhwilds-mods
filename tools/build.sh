#!/usr/bin/env bash
# 组装可以装进游戏的 mod：build/<Mod>/ = src/mods/<Mod>/ 原样 + 共享库 src/lib/ 复制进 reframework/autorun/<Mod>/lib/。
#
# 为什么每个 mod 各带一份库（docs/ARCHITECTURE.md「库怎么分发」）：mod 会单独发给别人，REF 所有脚本又共用一个 Lua 状态、
# 一个 package.loaded。要是大家都装进同一个 autorun/lib/，先装的旧版本会被后装的覆盖、或者先加载的那份被所有 mod 共用；
# 放进各自的 <Mod>/lib/，模块名就是 "<Mod>.lib.xxx"，互不干扰。库内部用相对前缀互相 require，挂在哪个名字下都能用。
#
# 用法：tools/build.sh [--zip] [Mod...]   不写 Mod 时组装 src/mods/ 下的全部 mod
#   --zip：另外打成 dist/<Mod>-<版本>.zip（解压到游戏根目录即可；版本取入口脚本里的 local VERSION = "..."，没有就不带版本）
# build/、dist/ 都是生成的（已 gitignore），每次重建前会清掉 build/<Mod>/。
# 环境变量 MODS_DIR（默认 src/mods）、BUILD_DIR（默认 build）：tools/test.sh 用它们组装 templates/ 里的模板做冒烟测试
set -eu
cd "$(dirname "$0")/.."
MODS_DIR="${MODS_DIR:-src/mods}"
BUILD_DIR="${BUILD_DIR:-build}"

ZIP=0
mods=()
for a in "$@"; do
    case "$a" in
        --zip) ZIP=1 ;;
        -*) echo "未知参数：$a（只认 --zip）" >&2; exit 2 ;;
        *) mods+=("$a") ;;
    esac
done
if [ ${#mods[@]} -eq 0 ]; then
    mapfile -t mods < <(find "$MODS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
fi
if [ ${#mods[@]} -eq 0 ]; then
    echo "$MODS_DIR/ 下没有 mod" >&2
    exit 2
fi

for mod in "${mods[@]}"; do
    src="$MODS_DIR/$mod"
    entry="$src/reframework/autorun/$mod.lua"
    if [ ! -f "$entry" ]; then
        echo "$mod：找不到入口 $entry（mod 目录名要和入口脚本同名）" >&2
        exit 3
    fi
    # mod 自己不许带 lib/：会和复制进来的共享库混在一起
    if [ -e "$src/reframework/autorun/$mod/lib" ]; then
        echo "$mod：$src/reframework/autorun/$mod/lib 已存在（这个位置留给共享库，mod 自己的模块换个名字）" >&2
        exit 3
    fi
    out="$BUILD_DIR/$mod"
    rm -rf "$out"
    mkdir -p "$out"
    cp -r "$src/." "$out/"
    mkdir -p "$out/reframework/autorun/$mod/lib"
    cp -r src/lib/. "$out/reframework/autorun/$mod/lib/"
    # GPL-3.0 要求发布时附带许可证全文：仓库根目录的 LICENSE 复制进每个 mod（README「许可」）
    cp LICENSE "$out/reframework/autorun/$mod/LICENSE.txt"
    n=$(find "$out" -type f | wc -l)
    echo "  ▣ $out（$n 个文件）"

    if [ $ZIP -eq 1 ]; then
        ver=$(sed -nE 's/^local VERSION = "([^"]+)".*/\1/p' "$entry" | head -1)
        [ -z "$ver" ] && ver=$(sed -nE 's/^K\.VERSION = "([^"]+)".*/\1/p' "$src/reframework/autorun/$mod/const.lua" 2>/dev/null | head -1)
        name="$mod${ver:+-$ver}.zip"
        mkdir -p dist
        rm -f "dist/$name"
        # 用 Python 打包：Git Bash 不自带 zip。-I 隔离模式，不从当前目录载入模块。
        # Linux（GitHub Actions）上通常只有 python3，Windows 上的 python3 可能是应用商店的占位程序（一跑就退出码 49），
        # 所以挨个试，能真正跑起来的才用
        PY="${PYTHON:-}"
        if [ -z "$PY" ]; then
            for c in python3 python; do
                if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
            done
        fi
        if [ -z "$PY" ]; then echo "找不到能用的 Python（可用 PYTHON 环境变量指定）" >&2; exit 2; fi
        "$PY" -I - "$out" "dist/$name" <<'PY'
import os, sys, zipfile
root, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(d, f)
            z.write(p, os.path.relpath(p, root).replace(os.sep, "/"))
PY
        echo "  ⇩ dist/$name"
    fi
done

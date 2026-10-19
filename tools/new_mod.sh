#!/usr/bin/env bash
# 从 templates/ModTemplate/ 新建一个 mod：复制到 src/mods/<名字>/，文件名和内容里的 ModTemplate 都换成新名字。
# 名字就是入口脚本名、模块命名空间（require("<名字>.xxx")）和配置文件名，所以只许用字母、数字开头的 [A-Za-z0-9_]，
# 不许有点（点是模块名的分隔符）。
# 用法：tools/new_mod.sh 名字      例如 tools/new_mod.sh AutoGuardLS
set -eu
cd "$(dirname "$0")/.."

name="${1:-}"
if ! [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
    echo "用法：tools/new_mod.sh 名字（字母开头，只含字母、数字、下划线）" >&2
    exit 2
fi
dst="src/mods/$name"
if [ -e "$dst" ]; then
    echo "$dst 已经存在" >&2
    exit 3
fi

mkdir -p "$dst"
cp -r templates/ModTemplate/. "$dst/"
# 先改路径（深的先改），再改内容
find "$dst" -depth -name '*ModTemplate*' | while read -r p; do
    mv "$p" "$(dirname "$p")/$(basename "$p" | sed "s/ModTemplate/$name/g")"
done
find "$dst" -type f -name '*.lua' -exec sed -i "s/ModTemplate/$name/g" {} +

tools/check.sh $(find "$dst" -name '*.lua' | sort)
echo "建好了：$dst。下一步：改入口脚本 $dst/reframework/autorun/$name.lua，然后 tools/deploy.sh"

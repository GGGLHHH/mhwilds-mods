#!/usr/bin/env bash
# 把 src/reframework/ 部署到游戏目录（先跑检查，不通过就不部署）。
# 只复制本仓库的文件，不碰游戏目录里的其他东西（REF 本体、HitboxViewer 等）。
# 部署后在游戏里点 REF 菜单的 Reset Scripts 生效。
# 用法：tools/deploy.sh          游戏目录可用 MHWILDS_DIR 环境变量覆盖
set -eu
cd "$(dirname "$0")/.."

GAME="${MHWILDS_DIR:-/c/Program Files (x86)/Steam/steamapps/common/MonsterHunterWilds}"
if [ ! -d "$GAME/reframework" ]; then
    echo "找不到 $GAME/reframework（先装 REFramework，或用 MHWILDS_DIR 指定游戏目录）" >&2
    exit 2
fi

tools/check.sh $(find src -name '*.lua' | sort)

changed=0
while read -r f; do
    rel="${f#src/}"
    dst="$GAME/$rel"
    if [ -f "$dst" ] && cmp -s "$f" "$dst"; then
        echo "  = $rel（未变化）"
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst"
    echo "  → $rel"
    changed=1
done < <(find src -type f | sort)

[ $changed -eq 1 ] && echo "已部署。游戏里点 REF 菜单 → Reset Scripts 生效。" || echo "没有变化。"

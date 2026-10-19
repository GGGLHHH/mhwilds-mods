#!/usr/bin/env bash
# 把 src/reframework/ 部署到游戏目录（先跑检查，不通过就不部署）。
# 只复制本仓库的文件，不碰游戏目录里的其他东西（REF 本体、HitboxViewer 等）；另外把废弃清单里旧版部署过的文件挪走（见下）。
# 部署后在游戏里点 REF 菜单的 Reset Scripts 生效。
# 用法：tools/deploy.sh [--dry-run]   游戏目录可用 MHWILDS_DIR 环境变量覆盖
#   --dry-run：照样跑检查，只列出要挪走、要复制的文件，什么都不改
# 自测（假游戏目录，不碰真的游戏目录）：bash tools/mock/deploy_selftest.sh
set -eu
cd "$(dirname "$0")/.."

DRY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        *) echo "未知参数：$a（只认 --dry-run）" >&2; exit 2 ;;
    esac
done

GAME="${MHWILDS_DIR:-/c/Program Files (x86)/Steam/steamapps/common/MonsterHunterWilds}"
if [ ! -d "$GAME/reframework" ]; then
    echo "找不到 $GAME/reframework（先装 REFramework，或用 MHWILDS_DIR 指定游戏目录）" >&2
    exit 2
fi

# 已废弃、旧版部署过的文件。部署时挪到 reframework/autorun_disabled/，不删除。
# 为什么挪、不删：REF 只加载 autorun/ 下的脚本，挪走就不会和新脚本同时运行；
# 要回滚时原样挪回来就行（docs/autoparry/MERGE.md 第 7 节）。
# 探针（AttackTimingProbe.lua、AutoParryCalib.lua）不进清单：它们不是本脚本部署的，研究时还要手动放回去
OBSOLETE=(
    "reframework/autorun/AutoParryGS.lua"   # AutoGuardGS v1.5 起并入 AutoGuardGS.lua；两个同时跑会重复放刀
)
DISABLED_DIR="reframework/autorun_disabled"

tools/check.sh $(find src -name '*.lua' | sort)

# 一致性检查：清单里的路径只许在 reframework/autorun/ 下；清单里的文件名也出现在 src/ 里就报错退出 ——
# 清单写错了会把刚部署的新文件挪走（先挪后复制的话，新文件这次照样会被复制回去，下次部署又被挪走，来回打转）
for rel in "${OBSOLETE[@]}"; do
    case "$rel" in
        reframework/autorun/*) ;;
        *) echo "废弃清单里的 $rel 不在 reframework/autorun/ 下（只撤 autorun 里的脚本）" >&2; exit 3 ;;
    esac
    case "$rel" in
        *..*) echo "废弃清单里的 $rel 带 ..（路径越界）" >&2; exit 3 ;;
    esac
    name="$(basename "$rel")"
    if [ -e "src/$rel" ] || [ -n "$(find src -name "$name" -print -quit)" ]; then
        echo "废弃清单里的 $rel 也在 src/ 里（$(find src -name "$name" | head -1)）：清单写错了，一个文件都没动" >&2
        exit 3
    fi
done

# 先撤废弃文件，再复制新文件：挪动失败就退出、一个新文件都不复制。顺序反过来的话，挪不动时 autorun 里会同时有新旧两个脚本
moved=0
for rel in "${OBSOLETE[@]}"; do
    src_f="$GAME/$rel"
    [ -f "$src_f" ] || continue
    name="$(basename "$rel")"
    dst_rel="$DISABLED_DIR/$name"
    if [ -e "$GAME/$dst_rel" ]; then
        # 已经有同名文件（以前撤过一次）：新挪的加时间戳，不覆盖旧的
        stamp="$(date +%Y%m%d-%H%M%S)"
        base="${name%.lua}"
        dst_rel="$DISABLED_DIR/$base.$stamp.lua"
        n=1
        while [ -e "$GAME/$dst_rel" ]; do
            dst_rel="$DISABLED_DIR/$base.$stamp-$n.lua"
            n=$((n + 1))
        done
    fi
    if [ $DRY -eq 1 ]; then
        echo "  ↷ $rel → $dst_rel（已废弃；--dry-run 不挪）"
        moved=$((moved + 1))
        continue
    fi
    if ! mkdir -p "$GAME/$DISABLED_DIR" 2>/dev/null || [ ! -d "$GAME/$DISABLED_DIR" ]; then
        echo "建不了 $GAME/$DISABLED_DIR：没挪 $rel，一个新文件都没复制" >&2
        exit 4
    fi
    if ! mv "$src_f" "$GAME/$dst_rel"; then
        echo "挪不动 $rel（文件被占用、目录只读？）：一个新文件都没复制" >&2
        exit 4
    fi
    echo "  ↷ $rel → $dst_rel（已废弃）"
    moved=$((moved + 1))
done

changed=0
while read -r f; do
    rel="${f#src/}"
    dst="$GAME/$rel"
    if [ -f "$dst" ] && cmp -s "$f" "$dst"; then
        echo "  = $rel（未变化）"
        continue
    fi
    if [ $DRY -eq 1 ]; then
        echo "  → $rel（--dry-run 不复制）"
    else
        mkdir -p "$(dirname "$dst")"
        cp "$f" "$dst"
        echo "  → $rel"
    fi
    changed=$((changed + 1))
done < <(find src -type f | sort)

if [ $DRY -eq 1 ]; then
    echo "--dry-run：要撤下 $moved 个废弃文件、更新 $changed 个文件；什么都没改。"
elif [ $moved -gt 0 ] || [ $changed -gt 0 ]; then
    echo "撤下了 $moved 个废弃文件、更新了 $changed 个文件。游戏里点 REF 菜单 → Reset Scripts 生效。"
else
    echo "没有变化。"
fi

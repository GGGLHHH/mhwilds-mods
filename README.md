# mhwilds-mods

《怪物猎人：荒野》的 REFramework Lua Mod。

## AutoGuardGS：大剑自动防御

拿大剑时自动处理怪物的攻击，全部走游戏原生的动作和判定：

| 功能 | 说明 | 状态 |
|---|---|---|
| 自动精确防御 | 被打中时，若此刻能举剑，就结算成精确防御（也可切换为普通防御） | 稳定 |
| 防御角度 | 滑块调整防御角度（游戏默认 70°，范围 30°～360°），手动防御同样生效 | 稳定 |
| 霸体保护 | 身上有霸体（蓄力、蓄力斩等）时不防御，不打断攻击 | 稳定 |
| 自动肩撞 | 蓄力中挨打后自动出肩撞，之后可接下一级蓄力 | 稳定 |
| 自动放刀 | 按住抵消蓄力时，危险攻击快到就自动放出抵消上捞斩 | 实验中 |
| 无限蓄力 | 测试用开关：蓄满后不会过热自动放出 | 测试用 |

设置在 REF 菜单 → Script Generated UI → **大剑自动防御**，自动保存到 `reframework/data/AutoGuardGS.json`。

**注意：**

- 只影响自己的角色。防御角度、无限蓄力会临时改写所有大剑共用的武器参数，前者只在你受击结算的瞬间改写，后者在开关打开期间会连带影响同场 NPC 支援猎人的大剑。
- 只在单人模式下测试过，联机表现未验证。

## 安装

1. 安装 [REFramework](https://github.com/praydog/REFramework-nightly/releases) nightly 版（社区汉化版也可以）
2. 把 `src/reframework/` 复制到游戏根目录，或者运行 `tools/deploy.sh`
3. 进游戏，在 REF 菜单里点 Reset Scripts 或重启游戏

## 开发

```bash
tools/check.sh      # 检查全部 Lua：语法 + 意外的全局变量（拼写错误、漏写 local）
tools/deploy.sh     # 先检查，再把 src/ 部署到游戏目录（MHWILDS_DIR 可覆盖路径）
```

需要 Lua 5.4（`luac`），和 REFramework 内置的 Lua 同一个大版本。

- `src/`：正式发布的脚本，**改这里**，再用 deploy 部署，不要直接改游戏目录
- `probes/`：研究过程中写的探针，只记录、不修改游戏，留作参考
- `docs/NOTES.md`：摸清的游戏内部结构和走过的弯路

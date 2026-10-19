# mhwilds-mods

《怪物猎人：荒野》的 REFramework Lua Mod。

## AutoGuardGS：大剑自动防御

拿大剑时自动处理怪物的攻击，全部走游戏原生的动作和判定。只有一个脚本 `AutoGuardGS.lua`（v1.5）：

| 功能 | 说明 | 状态 |
|---|---|---|
| 自动精确防御 | 被打中时，若此刻能举剑，就结算成精确防御（也可切换为普通防御） | 稳定 |
| 防御角度 | 滑块调整防御角度（游戏默认 70°，范围 30°～360°），手动防御同样生效；抵消蓄力和上捞斩期间不改写 | 稳定 |
| 霸体保护 | 身上有霸体（蓄力、蓄力斩等）时不防御，不打断攻击 | 稳定 |
| 自动肩撞 | 蓄力中挨打后自动出肩撞，之后可接下一级蓄力 | 稳定 |
| 自动放刀 | 按住抵消蓄力时，危险攻击快到就自动放出抵消上捞斩；时机按怪物当前的动作速度修正；只接游戏判定为能抵消的攻击；可选调试日志记下每一刀 | 实验 |
| 无限蓄力 | 测试用开关：蓄满后不会过热自动放出 | 测试用 |
| 锁血 | 测试用开关：主玩家不掉血、不会倒下，被打的反应动作照常 | 测试用 |

### 自动放刀（实验）

只在你自己按住抵消蓄力时起作用，默认开。

- **时机**：怪物出招时会给目标猎人发一份攻击预告（游戏本来给 NPC 用的），里面有每段攻击还剩多少帧打过来。这个倒数是按怪物 1 倍速算的，怪物发怒、换招加速时攻击会比倒数早到，所以脚本每帧读怪物当前的动作速度，换算成真实剩余时间。最早一段危险攻击（DANGER）的真实剩余时间落进 22～28 帧（1/60 秒）时，在帧开头请求抵消上捞斩。
  - 28 就是菜单里的「提前量」，可调 23～45：越小越常出抵消动作，太小会被先打到。
- **全是原生的**：脚本只请求上捞斩这一个动作，不改任何共用参数。接没接住、伤害、火花、把怪弹开，都由刀和攻击的真实碰撞决定。
- **不放刀的情况**（只接游戏判定为能抵消的攻击；攻击属性读不准时宁可不放）：
  - 弹体；咆哮、风压、震动；
  - 抓取，以及要技能才能防（SKILL_GUARD）、不可防御（UNABLE_GUARD）的攻击；
  - 会把刀弹开的攻击（游戏标记 `_IsParryBreak`：接上去是被弹开、随即挨打）；
  - 1.5 秒内（按预告的倒数算）要来的攻击里有判定持续超过 1 秒的、抓取或要技能才能防的，这一刻整个不放（同时来的别的攻击也不接）；
  - 怪物刚出招时读不到它的动作速度，这一招不放（中途偶尔读不到，沿用上一帧的速度照常判断）；
  - 联机时在你这边不是主控的怪（副本）。
- **验收现状**（如实写明）：
  - 时机的机制检验（A 阶段，只记录、不放刀）在 5 只新怪上通过（2026-10-11）；
  - 正式验收（B 阶段：在新怪上按规则实打，统计接住率和空挥率）**还没做**；
  - 实际只在缠蛙（设计时就用过的怪）上试打过：**7 刀接住 5**，另 2 刀没接住，0 次被弹开，0 个错误（2026-10-11）。
    - 试打时的条件：【测试】锁血、【测试】无限蓄力、防御角度 360、自动防御都开着，两个研究探针（APCal、ATP）也在跑（游戏日志里探针的 HDR）。这些开关不进放刀的判断和结局判定，但无限蓄力让抵消蓄力不会 2.5 秒过热自动放出、锁血让人倒不下，放刀的机会和节奏和正常打不一样。
  - 所以标「实验」。新怪上的接住率还没有数，靠下面的调试日志持续看；部署后用的还是这份配置，持续监控也是在这些开关开着时采样。正式验收时这些开关开不开还没定。
- **菜单里能看到的**：状态行（正常时写「正常」，出问题会写明原因；出现红字时请把游戏目录的 `re2_framework_log.txt` 发给开发者，然后 Reset Scripts），以及底部统计里的一行：放了几刀、接住几刀（括号里分游戏的两种接住动作 26 / 27，27 时怪物会进抵消硬直）、被弹开几次、没接住几次（空挥、被打断、又回到蓄力等）。
- **调试日志**：菜单底部的「调试日志」开关（和防御共用，默认关）。
  - 打开后，每次放刀在 `re2_framework_log.txt` 里写两行：`[AutoParryGS] FIRE`（放刀）和 `[AutoParryGS] RES`（结局）；本次加载第一次写之前先写一行 `[AutoParryGS] HDR`。
  - 关着时这些都不写。出错时的 `[AutoParryGS] ERR` / `RED` 行不受开关控制，照常写。
  - 标签沿用旧名 `[AutoParryGS]`，含义是「放刀记录」。离线分析见下面「开发」。

### 设置与升级

设置在 REF 菜单 → Script Generated UI → **大剑自动防御**（「自动放刀」是其中一节），自动保存到 `reframework/data/AutoGuardGS.json`。

自动放刀以前是单独的脚本 `AutoParryGS.lua`（单独的菜单「自动放刀（实验）」、单独的配置 `AutoParryGS.json`），v1.5 起并进了 `AutoGuardGS.lua`。从旧版升级时：

- **游戏 `reframework/autorun/` 里的旧 `AutoParryGS.lua` 必须移走**，否则两份放刀逻辑同时运行。`tools/deploy.sh` 会自动把它挪到 `reframework/autorun_disabled/`（不删除）；手动安装要自己挪。
- **配置自动迁移一次**：第一次加载时，如果 `AutoGuardGS.json` 里还没有放刀的设置，就从旧的 `AutoParryGS.json` 读「自动放刀」开关和「提前量」，立刻写进 `AutoGuardGS.json`（还没有 `AutoGuardGS.json` 时，等 REF 存配置时再写）。
  - v1.6 存的提前量照搬（夹到 23～45）；v1.6 之前存的含义不同（当时没有速度修正），一律改成默认的 28。
  - 旧文件只读，不改、不删，回滚时还要用。调试日志开关不迁，用 AutoGuardGS 自己的。
  - 之后只认 `AutoGuardGS.json`。
  - 某次加载读 `AutoGuardGS.json` 出错（比如文件正被别的程序占着）：这次用默认设置，菜单顶上用红字写明，**这次加载不保存任何改动**，免得拿默认值把原文件盖掉；Reset Scripts 重读即可。

**注意：**

- 只影响自己的角色。防御角度、无限蓄力会临时改写所有大剑共用的武器参数，前者只在你受击结算的瞬间改写，后者在开关打开期间会连带影响同场 NPC 支援猎人的大剑。
- 只在单人模式下测试过，联机表现未验证。联机时副本怪（在你这边不是主控的怪）不放刀。
- 打开调试日志后，每次放刀会在游戏日志里多写两行。

## 许可

GPL-3.0-or-later（全文见 [LICENSE](LICENSE)），Copyright (C) 2026 GGG <1635656638@qq.com>。

- 可以自由使用、修改、重新发布，包括修改后的版本。
- 重新发布时必须保留原作者署名和这份许可证，并且以同样的 GPL-3.0 许可公开修改后的源码。
- 发布包里每个 mod 都带一份 `LICENSE.txt`（`tools/build.sh` 打包时从仓库根目录复制进去）。

## 安装

1. 安装 [REFramework](https://github.com/praydog/REFramework-nightly/releases) nightly 版（社区汉化版也可以）
2. 运行 `tools/deploy.sh`；或者用 `tools/build.sh --zip` 打出 `dist/AutoGuardGS-v1.5.zip`，解压到游戏根目录（手动安装时，先把 `reframework/autorun/` 里旧的 `AutoParryGS.lua` 挪走，见上一节）。装好后 `reframework/autorun/` 里是 `AutoGuardGS.lua` 加一个同名目录 `AutoGuardGS/`（模块和共享库），两样都要在
3. 进游戏，在 REF 菜单里点 Reset Scripts 或重启游戏
4. 核对：Script Generated UI 顶层只有一个「大剑自动防御 v1.5」树节点，展开后里面有「自动放刀（实验）」那个勾选框和提前量滑块。如果顶层还另有一个单独的「自动放刀（实验）」树节点（和「大剑自动防御」并列），说明旧的 `AutoParryGS.lua` 还在 autorun 里

## 开发

代码结构（共享库、mod 怎么分层、库的约定、怎么新建 mod）见 `docs/ARCHITECTURE.md`。

```bash
tools/test.sh [--quick]   # 全部测试：检查、库单元测试、组装、模板冒烟、工具自测、mock 合并模式（--quick 跳过 mock）
tools/check.sh            # 检查全部 Lua：语法、意外的全局变量（拼写错误、漏写 local）、手动 release（引用记账）、require 命名空间等
tools/build.sh [--zip]    # 组装 build/<Mod>/（mod + 共享库）；--zip 另打发布包 dist/<Mod>-<版本>.zip
tools/deploy.sh           # 检查、组装，再挪走已废弃的旧文件，最后把 build/ 部署到游戏目录（MHWILDS_DIR 可覆盖路径）
tools/new_mod.sh 名字      # 从模板新建一个 mod
```

- 需要 Lua 5.4（`lua`、`luac`，和 REFramework 内置的 Lua 同一个大版本；不在 PATH 里就写全路径）和 Python 3（只用标准库）。
- `deploy.sh` 的废弃清单（脚本里的 `OBSOLETE`，现在只有 `reframework/autorun/AutoParryGS.lua`）：部署前先把这些旧文件挪到 `reframework/autorun_disabled/`（重名时加时间戳，不删除），挪不动就一个新文件都不复制，免得新旧脚本同时运行。探针不在清单里：研究时手动放进 autorun，用完手动挪走。

**模拟测试**（`tools/mock/`：不开游戏，用假的 REF API 逐帧驱动脚本；场景和断言见 `tools/mock/run.lua` 头注释）：

```bash
lua tools/mock/run.lua                     # 全部场景，跑归档的 v1.6 放刀脚本（参照组）
lua tools/mock/run.lua --merged            # 组装好的 build/AutoGuardGS（先跑 tools/build.sh）：调试日志开、关各跑一遍，逐刀和参照组比，任何差异都算失败；另跑防御、配置迁移、两部分交互的场景
lua tools/mock/run.lua --merged v16_pb     # 只跑指定的场景
lua tools/mock/run.lua --smoke             # 冒烟：验证 mock 本身
lua tools/mock/run.lua --merged --gc-every-frame v16_ref_shared   # 每帧强制回收，查引用记账
bash tools/mock/check_selftest.sh          # check.sh 自测：各种手动 release 的写法都要拦住、不误判
bash tools/mock/deploy_selftest.sh         # deploy.sh 废弃清单的自测（只用临时目录，不碰游戏目录）
```

**离线分析放刀日志**（`tools/apcal_analyze.py`）：

```bash
PYTHONIOENCODING=utf-8 python tools/apcal_analyze.py --selftest
python tools/apcal_analyze.py <数据目录> --log <re2_framework_log.txt> --session <HDR 里的 session> --out report.md
```

- 合并版只写日志、不写 JSON：没跑探针时数据目录给一个空目录即可，跑了探针就给它的 JSON 所在目录（游戏的 `reframework/data/`）。HDR 带 `host=AutoGuardGS-v1.5` 的会被认成合并版。
- 只有放刀日志时，能统计放刀和结局；要细分放早、空挥、被打断，需要同时跑探针 `probes/AutoParryCalib.lua`（不随正式版部署）。

**回滚到两个脚本的版本**：把 `reframework/autorun_disabled/AutoParryGS.lua` 挪回 `reframework/autorun/`，把 `tools/archive/AutoGuardGS_v1.4.2.lua` 复制成游戏 autorun 里的 `AutoGuardGS.lua`，再 Reset Scripts。配置不用动（详见 `docs/autoparry/MERGE.md` 第 7.4 节）。

目录：

- `src/lib/`：共享库（通用层 + `wilds/` 游戏层），打包时复制进每个 mod；`src/mods/<Mod>/`：各个 mod。**改这里**，再用 deploy 部署，不要直接改游戏目录
- `templates/ModTemplate/`：新 mod 的模板；`tools/test/`：库单元测试、模板冒烟
- `probes/`：研究过程中写的探针，只记录、不修改游戏，留作参考；不由 deploy 部署
- `tools/archive/`：归档的旧版脚本（`AutoParryGS_v1.6.lua`、`AutoGuardGS_v1.4.2.lua` 等），给模拟测试当参照组、回滚用；不部署
- `tools/mock/`：模拟测试；`tools/apcal_analyze.py`：放刀日志离线分析；`tools/atp_analyze.py`、`tools/stage_a_judge.py`：时机机制检验（A 阶段）的分析
- `docs/NOTES.md`：摸清的游戏内部结构和走过的弯路
- `docs/autoparry/`：自动放刀的研究与规格（`SPEED.md` 速度修正、`V16.md` 放刀规则、`MERGE.md` 并入 AutoGuardGS）

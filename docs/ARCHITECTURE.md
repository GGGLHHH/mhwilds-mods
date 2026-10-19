# 代码结构：共享库与 mod

这个仓库要做多个 mod，每个 mod 都会单独发给别人。通用的基础设施放在共享库 `src/lib/` 里，每个 mod 打包时各带一份。这里写怎么分层、库有哪些约定、怎么新建 mod，以及构建、部署、测试的流程。游戏内部结构见 `NOTES.md`。

## 目录

```
src/
  lib/                      共享库源码（唯一一份）
    *.lua                   通用层：只依赖 REFramework，和具体游戏无关
    wilds/*.lua             游戏层：《荒野》的猎人、动作、武器、怪物、攻击预告，按武器通用
  mods/<Mod>/               一个 mod 一个目录，里面就是装进游戏根目录的样子
    reframework/autorun/<Mod>.lua        入口：REF 只自动运行 autorun/ 顶层的 .lua
    reframework/autorun/<Mod>/*.lua      mod 自己的模块：require("<Mod>.xxx")
templates/ModTemplate/      新 mod 的模板（tools/new_mod.sh 复制它）
build/<Mod>/                组装结果 = mods/<Mod>/ + lib/ 复制进 autorun/<Mod>/lib/（生成，不进版本库）
dist/<Mod>-<版本>.zip       发布包（tools/build.sh --zip 生成，不进版本库）
```

装进游戏后：

```
reframework/autorun/AutoGuardGS.lua
reframework/autorun/AutoGuardGS/{const,guard,parry}.lua
reframework/autorun/AutoGuardGS/lib/…        ← 共享库，模块名 "AutoGuardGS.lib.xxx"
```

## 分层

| 层 | 位置 | 能依赖谁 | 放什么 |
|---|---|---|---|
| 通用层 | `lib/*.lua` | REF 全局 API、通用层的其他模块 | 日志、结构化记录、错误分级、性能计数、配置、共享参数改写、菜单隔离、sdk 小工具 |
| 游戏层 | `lib/wilds/*.lua` | 通用层、游戏层的其他模块 | 已经实测过、**所有武器通用**的游戏读写；武器编号、动作编号由调用方传 |
| mod | `mods/<Mod>/…` | 库、自己的模块 | 规则、参数、菜单；只属于某种武器、某个功能的东西 |

一样东西什么时候进库：第二个 mod 也要用的时候（见文末「还没进库的」）。没有第二个用户就先放在 mod 里，免得照着猜出来的需求设计接口。

## 库的约定

这几条 `tools/check.sh` 和单元测试会查，违反了直接报失败。

1. **模块级不放可变状态，有状态的做成 `new()` 工厂。** REF 的所有脚本共用一个 Lua 状态，模块缓存在共用的 `package.loaded` 里。模块级的计数器、开关、缓存会被同一个 mod 的所有部件共用。每个部件各 `new()` 一份，互不牵连。
2. **库内互相 `require` 用相对前缀。** 每个文件开头用 `...`（`require` 传进来的模块名）算出自己所在的包：

   ```lua
   local LIB = ((...) or error("lib 模块要用 require 载入")):gsub("[^.]+$", "")          -- "AutoGuardGS.lib."
   local util = require(LIB .. "util")
   -- lib/wilds/ 下的文件去掉两级：(...):gsub("wilds%.[^.]+$", "")
   ```

   库里不许写死 `require("…")`（check.sh 第 5 项）。写死的名字换个 mod 就找不到，或者会找到别的 mod 里的旧版本。
3. **mod 只 `require` 自己命名空间下的模块**，也就是 `"<Mod>."` 开头的（check.sh 第 5 项）。
4. **模块名写全。** 官方 REF 往 `package.path` 里加的是 `autorun/?.lua`、`autorun/?/init.lua`、`autorun/?.dll`（REF 源码 `ScriptRunner.cpp`）。`init.lua` 其实也认，但汉化分支没核对过，mock 也只认全名，所以一律写全名。HitboxViewer 也是这么写的：`require("HitboxViewer.box.init")`。
5. **改游戏共享参数用 `lib/patch`。** 结算后、每帧开头、`re.on_script_reset` 三处都要还原，这是项目约定。还原按后进先出：同一个字段改两次时，最后写回的才是原值。
6. **调用顺序也是行为。** 游戏层的函数把原来的调用顺序固定下来了，例如 `player.snapshot()` 的读取顺序是主角 → 地址 → 武器 → 动作控制器 → 动作 ID。故障注入和逐刀等价都靠这个顺序，改之前先跑 mock。

## 库怎么分发

每个 mod 各带一份库，放在自己的 `autorun/<Mod>/lib/` 下，不共用一个 `autorun/lib/`。原因有两个：

- 分开发布的 mod，装的库版本可能不同。装进同一个目录，后装的会覆盖先装的。
- 就算文件不冲突，`package.loaded` 也是共用的：模块名一样，就全用先加载的那份。

带上 mod 自己的命名空间（`AutoGuardGS.lib.util`），两个 mod 的库就是两份互不相干的模块。代价是每个 mod 多带十几个小文件，可以接受。

## 模块清单

| 模块 | 干什么 | 主要接口 |
|---|---|---|
| `mod` | mod 骨架：配置、日志、性能计数、帧回调、Reset、存配置、菜单一次接好；钩子、回调包 pcall；登记的共享参数改写自动还原 | `new{name, version, title, config, validators}` → `hook` / `on_frame(fn(snap))` / `on_reset` / `menu` / `patch{per_frame}` / `start`；`config` / `L` / `cfg` |
| `util` | 数值检查、写日志用的格式化 | `finite`、`clean_str`、`clamp`、`formatter(on_error)` → `fmt` / `int` / `hex` |
| `log` | 带标签的日志：调试行受开关控制，警告按类别限量 | `new{tag, debug_on, warn_max}` → `info` / `warn` / `debug` / `warn_err(kind, err)` |
| `record` | 给离线分析读的 `KIND k=v` 行；头行懒写，加载期间的行先攒着 | `new{tag, spec, fmt, header_kind, header}` → `emit` / `line` / `finish_loading` |
| `health` | 错误分级：核心模块 10 s 内 3 次标红，可选模块第一次就标黄 | `new{core, emit, …}` → `note(mod, err)` / `set_red`；状态 `red` / `stopped` / `yellow` / `off` |
| `prof` | 性能计数，每 5 秒汇总 | `new{keys, on_report}` → `timed(name, fn)` / `report()`；`text` |
| `config` | `reframework/data/` 的 JSON 配置：只收认识的键和合法的值；读的时候抛错就不写 | `new{path, data, validators, on_error}` → `load` / `save`；`unreadable`；`read(path)` |
| `patch` | 共享参数的临时改写：先记原值再改，按记录写回 | `new()` → `begin` / `set` / `restore` / `restore_each` / `active` / `count` |
| `ui` | 菜单出错隔离：树节点必配对 `tree_pop`，一块出错只换成一行提示 | `new{on_error, retry}` → `tree(label, fn)` / `part(name, fn)`；`COLOR` |
| `ref` | sdk 小工具 | `need`、`type`、`hook`、`safe_pre`、`enum_value`、`enum_into`、`enum_map`、`addr_of` |
| `wilds.player` | 主玩家和当前动作 | `master`、`hunter`、`snapshot`、`current_action`、`action_text` |
| `wilds.action` | 在帧开头请求切动作 | `id(cat, idx)`、`request(hunter, id)`、`LAYER_BASE` |
| `wilds.weapon` | 武器类型、武器动作参数 | `TYPE`（只列实测过的）、`type_value(枚举名)`、`type_name(值)`、`action_param(wtype)` |
| `wilds.hunter` | 状态标志、能不能举起防御 | `status_flags`、`any_flag`、`flag_on/off`、`status_flag`、`GUARD_BLOCKED_ATTRS`、`action_attrs`、`why_cannot_guard` |
| `wilds.enemy` | 怪物 | `is_enemy`、`by_system_index` |
| `wilds.forecast` | 攻击预告的读取（只读、不持有） | `MSG_TYPE`、`read_items`、`has_shell`、`read_master` |

每个文件的头注释写了用法示例和实测出处。

## 新建一个 mod

```bash
tools/new_mod.sh AutoGuardLS      # 复制 templates/ModTemplate → src/mods/AutoGuardLS/，名字全部换掉，跑一遍检查
# 改 src/mods/AutoGuardLS/reframework/autorun/AutoGuardLS.lua
tools/test.sh --quick              # 检查 + 单元测试 + 组装 + 冒烟 + 工具自测
tools/deploy.sh                    # 装进游戏，然后在 REF 菜单点 Reset Scripts
tools/build.sh --zip AutoGuardLS   # 发布包 dist/AutoGuardLS-<版本>.zip
```

模板用 `lib/mod` 骨架，配置、日志、性能计数、菜单隔离、Reset 还原都接好了，照着改就行。AutoGuardGS 没换成骨架：它帧内的调用顺序被 mock 逐刀比对着，自己接线更稳妥。新机制还是先在 `probes/` 写只记录的探针验证，确认后再进 mod，这是项目约定。

## 参考过的：_CatLib

社区库 _CatLib（lingsamuel，v1.14.0）是荒野 mod 常用的共享库。没有许可证文件，只参考思路，不复制代码。

- **借鉴了**：`NewMod` 一行建好一个 mod 的思路，做成了 `lib/mod`，另外加上 pcall 和共享参数自动还原；枚举的双向表（`ref.enum_map`）。
- **没借鉴**：
  - 全局一份库、模块级缓存、`CheckVersion`：我们的 mod 要单独分发，这正是要避开的版本冲突。
  - 把玩家对象缓存到换场景才清：换场景时对象正在销毁，有拿到失效对象的风险；我们每帧现读，开销很小。
  - 钩子不包 pcall、菜单每改一次就写盘、读配置不包 pcall：和项目约定冲突。
- 它用到、我们没验证过的接口，记在 NOTES「待验证的线索（来自 _CatLib）」。

## 构建、部署、测试

| 命令 | 做什么 |
|---|---|
| `tools/check.sh` | 语法、意外的全局变量、手动扣引用、字形、`require` 命名空间 |
| `tools/build.sh [--zip] [Mod…]` | 组装 `build/<Mod>/`，可选打 zip |
| `tools/deploy.sh [--dry-run]` | 检查 → 组装 → 挪走废弃文件 → 把 `build/*` 复制进游戏目录。游戏的 `autorun/<Mod>/` 里多出来的旧文件只提示、不删 |
| `tools/test.sh [--quick]` | 全部测试；不加 `--quick` 时还跑 mock 合并模式（约 4 分钟） |

mock 测的是 `build/` 里组装好的那份，和部署、发布的是同一份文件。mock 的 `require` 照 REF 的规则在入口脚本所在的 autorun 目录下找模块；模块缓存每个脚本一份，模块在这个脚本的环境表里运行，这样副作用和故障注入还能按脚本归属。

## 还没进库的

| 东西 | 现在在哪 | 什么时候进库 |
|---|---|---|
| 攻击预告的跟踪（登记、跨帧持有、丢弃）和 E5c 真实剩余帧计时 | `AutoGuardGS/parry.lua` | 第二个要「预判怪物攻击到达时刻」的 mod 出现时。它和放刀规则的读取顺序有逐刀等价约束，拆的时候要跑 mock |
| 受击转防御的流程（前置开标志、后置还原、角度改写） | `AutoGuardGS/guard.lua` | 第二种能防御的武器（长枪、铳枪、片手）出现时。先核对那种武器的防御动作编号和参数字段 |
| `wilds.weapon.TYPE` 里大剑以外的编号 | — | 做那种武器时先用 MCP 或 Object Explorer 核对再加，不凭印象填 |

## 已验证 / 待验证

- **REF 的 `require` 路径（实测，2026-10-19）**：新布局在游戏里正常加载。`[AutoGuardGS] v1.5 loaded`、5 个钩子全部挂上、HDR 正常、读到防御角度，没有报错。`require("AutoGuardGS.lib.xxx")` 能找到 `autorun/AutoGuardGS/lib/xxx.lua`，子目录里的文件不会被当成脚本自动运行。
- **Reset Scripts 会清空模块缓存（REF 源码确认，2026-10-19）**：`ScriptRunner::reset_scripts()` 先销毁主 Lua 状态（`m_main_state.reset()`），再新建一个 `ScriptState`，所以 `package.loaded` 一定是新的，改了库代码点 Reset 就生效。你装的是汉化分支，还要在游戏里确认一次：用探针 `probes/WeaponTypeProbe.lua`，它加载时往 `package.loaded` 里留一个标记，连续 Reset 两次，日志里的 `[WeaponTypeProbe] RESET_SENTINEL` 应该是 `absent`。

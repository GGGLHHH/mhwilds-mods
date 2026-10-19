# mhwilds-mods 项目约定

《怪物猎人：荒野》REFramework Lua Mod。游戏内部结构和已验证的结论见 `docs/NOTES.md`，动手前先读。

## 工作方式

- **改 `src/`，不要直接改游戏目录**。共享库在 `src/lib/`，各 mod 在 `src/mods/<Mod>/`；结构和库的约定见 `docs/ARCHITECTURE.md`，新 mod 用 `tools/new_mod.sh` 建。改完运行 `tools/deploy.sh`（会先检查、组装），再请用户在 REF 菜单点 Reset Scripts。
- 每次改完 Lua 都要跑 `tools/check.sh`（语法 + 意外的全局变量 + require 命名空间）。Lua 里写错变量名不报错、只当 nil，必须提前查。提交前跑 `tools/test.sh`（不加 `--quick`，含 mock 逐刀等价）。
- 共享库里不放模块级可变状态（做成 `new()` 工厂），库内 require 用相对前缀；只属于一个 mod 的东西留在 mod 里，第二个 mod 要用时再进库。
- 新机制先写**只记录、不修改**的探针放进 `probes/` 验证，确认后再进正式版。探针部署进游戏 autorun 时注意性能：别每帧大量读取游戏对象。
- 调试读游戏日志：`/c/Program Files (x86)/Steam/steamapps/common/MonsterHunterWilds/re2_framework_log.txt`，按 `[AutoGuardGS]` 等标签 grep。
- 游戏在跑时可用 re-engine-mcp（localhost:8899）查类型、读对象；调用游戏方法要放在 Lua 的主线程回调里，不要从 MCP 调用。

## 代码约定

- 中文注释写「为什么」，标明哪些是实测结论
- 菜单文字用中文，控件标签带 `##英文ID`；避开 `°`、全角空格这类字体里可能没有的字符
- 改共享参数（武器参数等）一定要有还原路径：结算后、每帧开头、`re.on_script_reset` 三处兜底
- 所有钩子用 pcall 包住，出错要还原状态

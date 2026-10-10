# mhwilds-mods 项目约定

《怪物猎人：荒野》REFramework Lua Mod。游戏内部结构和已验证的结论见 `docs/NOTES.md`，动手前先读。

## 工作方式

- **改 `src/`，不要直接改游戏目录**。改完运行 `tools/deploy.sh`（会先跑检查），再请用户在 REF 菜单点 Reset Scripts。
- 每次改完 Lua 都要跑 `tools/check.sh`（语法 + 意外的全局变量）。Lua 里写错变量名不报错、只当 nil，必须提前查。
- 新机制先写**只记录、不修改**的探针放进 `probes/` 验证，确认后再进正式版。探针部署进游戏 autorun 时注意性能：别每帧大量读取游戏对象。
- 调试读游戏日志：`/c/Program Files (x86)/Steam/steamapps/common/MonsterHunterWilds/re2_framework_log.txt`，按 `[AutoGuardGS]` 等标签 grep。
- 游戏在跑时可用 re-engine-mcp（localhost:8899）查类型、读对象；调用游戏方法要放在 Lua 的主线程回调里，不要从 MCP 调用。

## 代码约定

- 中文注释写「为什么」，标明哪些是实测结论
- 菜单文字用中文，控件标签带 `##英文ID`；避开 `°`、全角空格这类字体里可能没有的字符
- 改共享参数（武器参数等）一定要有还原路径：结算后、每帧开头、`re.on_script_reset` 三处兜底
- 所有钩子用 pcall 包住，出错要还原状态

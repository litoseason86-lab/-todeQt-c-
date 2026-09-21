# Qt skills 归档与来源

此目录位于 `.agents/skills/` 之外，不作为本项目的活动 skill 目录。归档内容只用于人工恢复或溯源，不在普通 Qt 任务中自动读取。

## 完整归档

| 目录 | 恢复场景 |
|---|---|
| `qt-cpp-docs` | 需要统一格式的 C++ API 文档 |
| `qt-qml-docs` | 需要统一格式的 QML API 文档 |
| `qt-figma-token-extraction` | 从 Figma 提取设计令牌 |
| `qt-figma-component-generation` | 从 Figma 生成 QML 控件 |

四个目录的正文、许可证及配套资源保持原样。需要恢复时，确认 `.agents/skills/` 下没有同名目录，再将对应完整目录移回；恢复后先核对旧指令是否符合当前项目规则。无需批量恢复其他 skill。

## 合并与本地维护

- `qt-qml-test-run` 已并入 `.agents/skills/qt-qml-test/`，运行流程见其 `references/qt-quick-test-running.md`，解析脚本保留在 `references/scripts/`。旧入口不再保留。
- 七个活动 Qt skill 由项目直接维护，不再列入根目录 `skills-lock.json` 的上游安装集合，避免后续批量操作恢复旧入口或覆盖定制内容。
- [upstream-lock.json](upstream-lock.json) 保存此次调整前全部 Qt skill 的来源与哈希，仅供核对；不要将它直接作为活动安装清单。
- 原始版本及完整历史可通过 Git 查阅。恢复旧流程前，应重新评估其中的强制确认、构建目录和代理规则。

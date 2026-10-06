---
name: merge-to-main
description: 把分支合并回 main 之前使用：清理本分支产生的副产物、归档计划文件、跑 iOS 不签名编译。只在用户要求合并时触发。
---

# 合并回 main 前的清理

按顺序做完再合并。

1. 列出待删清单写进汇报。已跟踪的看 `git diff --name-status main...HEAD`；未跟踪和被忽略的看 `git status --porcelain --ignored`。无法确认来自本分支的，单独列出来问用户，不擅自删。
2. 副产物是只为开发过程服务、不作为交付物保留的文件：截图与渲染图、HTML 预览与设计稿、`.superpowers/`、`.codex/visualizations/` 等头脑风暴与可视化产物、日志、临时计划与审查记录、临时备份文件。已提交到分支的用 `git rm` 删除，随分支一起合并，保证合并后 `main` 上不留；没进 git 的直接从工作区删掉。
3. 不是副产物、不得删除：源码、测试、`docs/` 下的正式文档、`plans/README.md`、`~/pt-build`、`~/pt-audit`、`~/pt-ios`、仓库内 `build/`、`.cache/` 语言服务器索引、`tests/mcp-sdk/node_modules/` 测试依赖、个人本地配置。
4. 计划文件：正文先随功能提交入库，再删除，并在 `plans/README.md` 用 `git show <提交>:<路径>` 指回留档提交；不能跳过入库直接删。
5. 在 `~/pt-ios` 跑一次不签名编译（命令见 `docs/运行命令.md`），确认 iOS 也编得过、没有新增告警。

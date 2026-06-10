# Phase 3.1 科目管理系统测试报告

## 测试日期

2026-06-10

## 自动化验证

- `cmake --build build`：通过
- `ctest --test-dir build --output-on-failure`：通过，2/2 tests passed

## 功能测试结果

- [x] 数据库迁移到版本 2
- [x] 预设科目自动创建
- [x] 旧任务文本科目迁移到 `category_id`
- [x] 迁移前创建数据库备份文件
- [x] `CategoryManager` 查询、添加、编辑、删除校验
- [x] 预设科目不可编辑、不可删除
- [x] 有关联任务的科目不可删除
- [x] `TaskManager` 支持 `categoryId`
- [x] 任务返回 `category: { id, name, color }` 嵌套结构
- [x] `AddTaskDialog` 支持不设置科目
- [x] `TaskItem` 支持科目颜色标签
- [x] 科目变更后任务视图和统计视图刷新

## 发现的问题

- 已修复：任务返回结构原先使用 `categoryData`，现在保留兼容字段，同时按设计提供 `category` 嵌套对象。
- 已修复：新增任务默认强制选择第一个科目，现在默认是“不设置科目”。
- 已修复：v2 迁移中科目表创建和预设插入纳入事务。
- 已修复：迁移前缺少备份文件，现在会生成 `pomodoro_backup_*.db` 并保留最近 3 个。
- 已修复：科目变更后任务和统计视图不会立即刷新。

## 结论

科目管理主流程通过自动化验证。真实 UI 操作仍建议在应用内抽查添加、编辑、删除科目和创建无科目任务。

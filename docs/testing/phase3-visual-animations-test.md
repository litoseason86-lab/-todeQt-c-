# Phase 3.3 视觉动画优化测试报告

> ⚠️ **历史归档，不代表当前行为**（本声明 2026-08-07 补记）。
> 这是 2026-06-10 一次性验收的事实快照，此后界面被整体重做过（玻璃化、六套主题壁纸、
> `reduceMotion` 事实源改造、奖励回路的粒子与弹窗），正文不再维护。
> 当前的测试口径见 `docs/运行命令.md`，界面规则见 `AGENTS.md` 的「Qt/QML 界面规则」。
>
> **勘误与补充**：
> - 本文写作时**还没有 `reduceMotion`**。现行硬规则是：无限循环动画和装饰粒子在
>   `reduceMotion` 下必须**真正停止**（`running: false` / 不创建对象），
>   而不是把 `duration` 归零继续空转（见 `AGENTS.md`）。新增动画必须照这条写。
> - 「`ctest` 通过，2/2 tests passed」是当年的规模；现在是 15 个 ctest 目标。
> - 正文的 `qmlprofiler` 命令依赖 `POMODORO_TODO_ENABLE_QML_DEBUG=ON`（该选项默认 **OFF**），
>   且它会拉起可见窗口——按现行规则**不得在自动流程里执行**，只能由人手动跑。
>   产物 `build/phase3-visual.qtd` 是仓库内 `build/` 的历史残留。
> - 至今**仍没有常设的 QML 渲染性能工装**，`plans/025` 就是为补这个缺口立的项（状态 TODO）。
>   因此本文「性能说明」一节的结论只对 2026-06 的那次手动采样成立。

## 测试日期

2026-06-10

## 自动化验证

- `cmake --build build`：通过
- `ctest --test-dir build --output-on-failure`：通过，2/2 tests passed
- `/Users/zerionlito/Qt/6.9.0/macos/bin/qmlprofiler --interactive --include animations,scenegraph -o build/phase3-visual.qtd build/PomodoroTodo.app/Contents/MacOS/PomodoroTodo`：通过，已生成 `build/phase3-visual.qtd`

## 动画效果检查

- [x] 任务完成状态有透明度和轻微位移动画
- [x] 任务标题完成后有删除线和颜色变化
- [x] 页面切换有淡出和淡入过渡
- [x] 对话框打开和关闭有 150ms 以上动画
- [x] 对话框遮罩有透明度动画
- [x] 侧边栏悬停颜色动画为 150ms
- [x] 统计卡片支持淡入和错峰延迟
- [x] 统计数字变化动画为 150ms + 150ms
- [x] 科目管理和导出弹窗按主窗口尺寸居中

## 性能说明

动画实现使用 QML 声明式动画和 Animator 类型，未引入 JavaScript 帧循环。QML Profiler 已能连接应用并采集 `animations,scenegraph` 数据；输出文件位于 `build/phase3-visual.qtd`。

## 发现的问题

- 已修复：多个动画时长低于 150ms。
- 已修复：对话框缺少遮罩透明度动画。
- 已修复：统计卡片同时淡入且切换页面后不重播。
- 已修复：侧边栏内弹窗按侧边栏宽度定位导致错位。

## 结论

动画代码满足计划中的静态要求并通过构建/QML 测试。视觉流畅度需要在运行应用中最终确认。

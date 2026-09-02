# 042：全局主动休息与超长自由专注时长修正

## 状态

- **状态**：已实施，待提交
- **优先级**：P1
- **执行分支**：`feature/new-requirement`
- **边界**：主动休息不是番茄完成后的 `BreakPhase`，也不是任何任务的子状态。

## 已确认的产品规则

### 全局主动休息

1. 入口只在“今日任务”标题右侧的操作区，紧挨“添加任务”左边；计时器空闲时显示“开始休息”。
2. 已有自由专注、番茄专注或番茄休息时，入口隐藏，不能并行开启第二个计时器。
3. 主动休息开始后，入口显示 `休息 HH:MM:SS`；点击它跳转至专注页。侧栏、仪表盘、托盘和窗口标题同步显示当前休息状态。
4. 专注页使用独立的“主动休息”面板，提供正计时、暂停/继续、结束休息，并明确写出“休息时间不会计入今日专注”。结束后返回今日任务页。
5. 主动休息不关联任务、不创建 `focus_sessions`、不产生历史记录、不增加今日专注、目标进度或番茄数。
6. 应用重启后，主动休息只恢复为暂停态，离线经过时间不补计；这是为了避免把未实际休息的时间伪造为时长。

### 超长自由专注的确认与修正

1. 自由专注超过设置的提醒阈值后，继续使用原有“确认自由计时记录”弹窗；默认阈值为 8 小时。
2. 弹窗增加时、分输入框，供用户修正即将写入的专注时长；输入框上限为 99 小时 59 分钟。
3. 不编辑时沿用实际原始秒数，避免仅打开弹窗就把秒数截断为整分钟。
4. 编辑后按用户输入的整分钟记录，且不得低于最小有效专注时长（3 分钟）。后端再次校验，QML 校验不能被视为数据边界。
5. 修正只能往下调：修正值不得超过本次实际已计时长。预填的就是实际分钟数，改大只可能是手滑
   （把 `09:01` 打成 `90:01`），而这条时长会直接进统计和长期目标进度。弹窗就地拦截并提示上限，
   服务层同样拒绝——上限和下限一样属于数据边界。
6. 修正过时长的记录，`end_time` 按 `start_time + 修正时长` 写入，而不是继续写“现在”。

## 实现结构

| 层 | 责任 |
| --- | --- |
| `FocusTimer` | 新增 `ManualRestMode` / `ManualRestPhase`，负责启动、暂停、恢复、结束及活动快照；主动休息不写数据库会话。`stopFreeFocusWithDuration()` 负责校验并写入用户修正后的自由专注时长。 |
| `TodayTaskView` / `MainWindow` | 渲染唯一入口、禁止与其他计时并行，并负责跳转专注页与结束后返回今日任务。 |
| `FocusView` / `ManualRestPanel` | 专注页的主动休息状态与交互。面板通过 `Loader` 独立加载，只发出用户意图，不直接操作服务。 |
| 仪表盘、侧栏、沉浸层、托盘 | 投影同一 `FocusTimer` 状态。主动休息使用正计时，且不触发今日专注累计。 |
| 长时确认弹窗 | 仅收集修正值；用户未编辑时走原有保存路径，编辑后调用带时长的后端保存接口。 |

## 数据与统计不变量

- `ManualRestPhase` 与既有 `BreakPhase` 均不创建 `focus_sessions`。
- `FocusLiveSeconds` 仅累计番茄工作阶段及带会话的自由专注；主动休息必须始终被排除。
- 结束主动休息只清除活动快照和内存状态，不能调用专注完成、任务完成、番茄计数或统计刷新逻辑。
- 用户修正的自由专注时长仅在确认保存成功后写入；保存失败时仍保留当前会话，避免丢失计时。
- 一条记录占用的时间区间（`start_time`…`end_time`）必须与它的 `duration` 一致。修正时长却让
  `end_time` 停在“现在”，会同时坏掉两件事：时间轴把这条记录画成“08:59 - 17:59 / 45分钟”，
  而 `FocusHistoryService` 的重叠校验按区间判定，整段窗口被锁死，用户再也补录不进这段时间里
  真实发生的其它专注——“忘了停、改完再补录”恰恰是修正功能最典型的下一步。
- `FocusTimer::m_startTime` 与会话行的 `start_time` 恒等（`startFocus` 用同一个值写库和写内存，
  `restoreInterruptedSession` 再从行里读回内存）。收缩区间依赖这个不变量，测试夹具回拨开始时刻
  时两处必须一起改。

## 涉及文件

- `src/services/FocusTimer.h`、`src/services/FocusTimer.cpp`
- `qml/MainWindow.qml`、`qml/views/TodayTaskView.qml`、`qml/views/FocusView.qml`
- `qml/components/ManualRestPanel.qml`、`LongFreeFocusConfirmDialog.qml`、`DurationFieldPair.qml`
- `qml/components/DashboardTimerPanel.qml`、`Sidebar.qml`、`FocusImmersiveOverlay.qml`、`FocusLiveSeconds.qml`
- `src/services/TrayController.cpp`、`resources/qml.qrc`
- 对应 C++ / QML 回归测试

## 验收清单

- [x] 今日任务页的入口位于添加任务按钮左侧，且只在没有其他计时器时可启动。
- [x] 主动休息在所有主要状态展示处可见，专注页有独立正计时控制面板。
- [x] 主动休息不写专注记录，也不进入今日实时专注秒数。
- [x] 重启恢复为暂停态且不补计离线时间。
- [x] 超过自由专注提醒阈值的确认弹窗可以手动修改将要记录的时长。
- [x] 未修改输入时保留秒级原始时长；修改后的时长受 3 分钟下限保护。
- [x] 修正值超过实际计时长时，弹窗就地提示上限，服务层一并拒绝。
- [x] 修正后的记录区间随时长一起收缩，让出的时间段可以正常补录。
- [x] 资源清单、QML 静态检查、服务测试、平台测试与相关 QML 回归通过。

## 验证命令

```sh
cmake --build ~/pt-audit --target PomodoroTodo -j4
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit --output-on-failure -R \
  '^(PomodoroTodoTests|PlatformControlTests|QmlResourceManifestTests|QmlLintGate|QmlTextFormatGate|QmlTest\.(focus_view|today_rollover|dashboard_view|focus_immersive|mainwindow_ui_optimization))$'
```

不部署、不启动应用，除非用户明确要求构建部署或人工验收。

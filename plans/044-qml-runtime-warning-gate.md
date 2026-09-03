# 044：QML 运行时告警门禁

## 状态

- **状态**：已实施，全量 ctest 69/69 通过
- **优先级**：P1（属于「一整类静默缺陷」）
- **触发**：对项目整体做深度 review 时，把全部 50 个 QML 测试跑一遍并收集 stderr，
  发现三处运行时告警——它们不让任何断言转红，测试一直全绿。

## 问题

QML 的运行时告警不是噪音，每一类都对应一种真实故障模式：

| 告警 | 后果 |
| --- | --- |
| `Unable to assign [undefined] to <type>` | 属性赋值被拒，绑定**停在上一次的值** |
| `TypeError` / `is not a function` | 求值当场中断，后面的兜底逻辑**根本跑不到** |
| `Binding loop` | 绑定反复求值，界面可能停在中间态 |

发现的三处，全都是「生产对象有这个成员，测试桩没有」，因此线上暂时不出错，
但每一处都偏离了本仓已有的写法：

- **`MonthGoalView.formatDuration`**（最严重）。守卫只判 `focusHistoryServiceRef !== null`，
  不判方法在不在，注入缺方法的对象时抛 TypeError，**它自己写在下面的兜底格式化反而跑不到**，
  整个求值中断、标签变空白。同一文件另外三处（`lastError` / `invalidSessionCount` /
  `cleanupInvalidSessions`）以及 `TodayFocusView` 里**同名同功能**的那个函数，
  用的都是 `typeof ref.method === "function"`——全仓十余处都这么写，只有这里漏了。
- **`ExportDialog.busy`** 写成 `!!ref && ref.busy`：`a && b` 在 b 为 undefined 时整体是
  undefined，赋给 bool 被拒、属性停在旧值。这个属性决定**导出期间能不能关掉对话框**，
  停在旧值意味着导出跑着却能被 Esc 关掉。全仓另外八处同类判断都用 `Boolean(...)`。
- **`SettingsFocusPage` 的 `freeTimerWarningHours`** 直接取值，undefined 赋给 int 被拒。
  本仓数值兜底的写法是 `Number(...) || 默认值`。

## 方案

三处按各自的既定写法修掉，并加门禁防止再犯。

门禁**挂在已有的每个 QML 测试条目上**（`FAIL_REGULAR_EXPRESSION`），而不是新增一条：
串行重跑全部 50 个 QML 测试实测 **63s**，会让全量从 22s 涨到三倍以上；
挂在已有条目上是**零额外运行时开销**——实测加门禁前后都是 21.5s。

```cmake
FAIL_REGULAR_EXPRESSION "Unable to assign;TypeError;is not a function;Binding loop"
```

某条测试确实需要故意触发告警时，单独覆盖它这一项属性。

## 已知盲区

门禁只能看见**测试实际实例化过**的 QML。没有任何测试碰过的组件，
其中的告警不会被发现。这不是门禁的缺陷，是测试覆盖的边界——
但记在这里，免得以后误以为「门禁绿了就等于全仓没有运行时告警」。

## 验证

逐个把三处 bug 放回去，门禁分别拦下 1 / 3 / 1 条测试；全部还原后 69/69 通过。

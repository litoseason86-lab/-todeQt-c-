# 本项目 QML 测试的坑

写、改或排查本项目的 Qt Quick Test 时读。每条都在本项目踩过；涉及 Qt 行为的写的是当时的现象和对策，换 Qt 版本后先复核。用例按函数名字母序执行、弹层关闭后焦点仍留在 overlay 等坑见 `docs/业务规则.md`「界面与验证约定」，这里不重复。

## 断言与可见性

- 不要断言 `item.visible === true`。`visible` 是沿父链算出的有效可见性，而 `TestCase` 默认 `visible: false`（Qt 自带的 `TestCase.qml`），挂在它下面的项读回来恒为假；后台无头环境里窗口本身是否显示也不可靠。改为断言驱动 `visible:` 绑定的那个属性（如 `view.state`、自定义布尔），或其它不沿父链传递的属性。断言 `false` 不受影响。
- 同一原因会让 Layout 里「先隐藏、后显示」的子项永远拿不到尺寸：有效可见性一直是假，不发 `visibleChanged`，布局不把它算进来，里面的 ListView 一个委托都不建，`findChild` 找委托得到 null。做法：Layout 的直接子项用一个始终可见的包裹 Item，条件可见的内容放在里面（`CountdownView.qml` 的 `countdownSecondaryList` 就是这样，别把包裹层「简化」掉）。

## 查找对象

- 从弹层根 `findChild` 找不到 Repeater 生成的委托（静态子项能找到）。给委托所在的容器设 `objectName`，先找到容器再从容器里找，写法见 `tst_routine_weekday_dialog.qml` 的 `chip()`。找不到时别先去怀疑 `required property index` 或模型。
- 表单上的选择态（如星期位掩码）不会随弹层关闭复位（离屏下实测 `onClosed` 里的复位没有生效），在 `init()` 里手动归位，否则排在后面的用例会莫名变红。

## 时序与等待

- 模型整体换新（换数组、reset）后要按坐标操作委托：先 `verify(waitForItemPolished(容器))`。新委托先建在 (0,0)，Flow 或布局下一帧才排好位置，按旧坐标移过去会落在别的项上。悬停没生效时先打印 `mapToItem(null, …)` 看坐标落在哪，再怀疑环境。
- 会量颜色或切主题的用例，在 `initTestCase` 把 `Theme.reduceMotion` 和替身 `appSettings.reduceMotion` 设为 true，`cleanupTestCase` 还原（照 `tst_contrast_audit.qml`）。`Theme.reduceMotion` 只在 `main.qml` 绑定，测试里默认是 false，颜色动画照常跑，并行时量到的是过渡色。
- 指针位置会跨用例留在同一个测试窗口里。弹层出现在静止的指针下时，Qt 下一帧会补发一次悬停，选项行跟着改高亮（`ChoicePopup.openedByKeyboard` 就是为此加的）。测「键盘打开弹层」的用例：先把指针停到弹层将出现的位置再打开，`wait(300)` 让补发的悬停送到，才能稳定复现。

## 输入与字体

- QML 测试发不出 `QInputMethodEvent`，而 iPad 的全部输入、Mac 的拼音上屏都走输入法，`TextArea` 在这条路径上不发 `textEdited`。测「编辑后自动保存」这类行为，用 `MemoQuickTests` 宿主注入的 `inputMethodProbe.commit(输入框, 文字)`、`inputMethodProbe.compose(输入框, 拼音)`（只发给当前焦点对象，焦点不对返回 false）；目前 `memo_view` 走这个宿主。
- 不要在测试里手动调用 `input.textEdited()` 之类的信号来假装输入：曾经因此把「输入法输入不保存」的缺陷完全遮住，全量照样全绿。
- 默认字族在本机找不到，回退字体的字宽全是整数，「字宽带小数被布局取整、误显示省略号」这类问题测不出。`MemoQuickTests` 已在 `qmlEngineAvailable` 里设系统字体；用例先断言字宽确实带小数，再看 `truncated`，排版刚变时用 `tryCompare(…, "truncated", false)`。

## 替身

- 替身要照真实服务同步发信号。本项目的失败播报在调用过程中同步 `emit`，用 `Connections { enabled: … }` 做门禁会漏掉这一发；替身改成异步 emit，这个缺陷就测不出来。
- 拿真实视图做测试或截图时，替身缺方法会直接抛 `is not a function`。先 `grep -o "root\.timer\.[A-Za-z]*(" 视图.qml | sort -u` 列出被调用的方法，一次补全。

## 偶发失败

- 先看 `~/pt-audit/Testing/Temporary/LastTestsFailed.log` 确认是哪条：`LastTest.log` 会被下一轮覆盖。
- 普通并发常复现不了。起 2×核数个带超时的忙等进程把 CPU 占满（`perl -e 'alarm 280; 1 while 1'`），同时 6–8 个实例跑**整份**测试文件；只跑那一个用例反而不复现，问题可能依赖前面用例留下的状态（比如指针位置）。
- 临时日志加在仓库外的副本里，不动仓库。定位后写一条正常负载下也能稳定复现的用例；修复后在同样的满负载下跑 16 次以上。结束后用 `pgrep` 确认忙等进程没有残留。

## 变异验证

- 判据：`qmltestrunner` 只跑一个函数要写成 `用例名::test_xxx`，写错时找不到函数照样返回非零。所以判据是「整份跑，输出里该函数是 `FAIL!`」，并且每条变异先跑一次未变异的基线，确认该函数是 `PASS`。C++ 的 QTest 二进制同理。
- 直接跑 `qmltestrunner` 没有 ctest 的 `FAIL_REGULAR_EXPRESSION`，`Binding loop`、`TypeError` 等告警不会判失败。要靠这些告警判定时，在用例 `init()` 里写 `failOnWarning(/Binding loop/)`（见 `tst_memo_view.qml`），或者走 ctest。
- QML 测试直接从 `qml/` 源码导入，改 QML 不用重新构建。改 C++ 要确认真的重编了：别用 `sed -i.bak` 加 `mv` 还原（文件 mtime 变旧，make 判定不用重编）；make 按秒比较时间戳，写入源码后用 `touch -t` 把 mtime 设到几秒后，并对比 `CMakeFiles/<目标>.dir/<源码路径>.o` 的 mtime，没重编的那一轮作废。
- 一条命令只做「改 → 跑 → 立即还原 → 用备份 `cmp`」。命令被打断、超时或报错后，先用备份 `cmp` 每个被改的源文件，不一致就拷回去，再做别的。
- 变异要改掉整个条件：`if (A || B)` 只把 A 换成 `false && A` 仍保留 B，会被误读成测试没抓到。指针处理器的 `acceptedButtons: Qt.NoButton` 不是停用，而是接受所有按键，不能拿它当「关掉处理器」的变异。
- 一次只变异一个改动点，并确认相邻的旧用例仍通过；只有几处改动对应的用例集完全不相交时，才可以同时变异。
- 变异可能让工作线程永久卡住、测试进程卡在退出：跑测试时套一层 `perl -e 'alarm 120; exec @ARGV'`；模拟卡住的用例用 `qScopeGuard` 在函数退出时放行。

## 离屏截图走查

不启动应用也能看界面：在仓库外写一个截图脚本，用 `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ~/Qt/6.10.3/macos/bin/qmltestrunner -input <脚本>.qml` 跑，在 TestCase 里 `grabImage(项).save(路径)`。

- 脚本第一行写 `pragma ComponentBehavior: Bound`。漏了它，一创建组件就刷一串行号错乱的 `RangeError: Maximum call stack size exceeded`，部分处理函数没跑完、页面状态是坏的，容易误判成产品缺陷。
- 脚本不在 `tests/qml/` 下时，导入写成 `import "file:<仓库绝对路径>/qml"`。
- 截真实视图时把 TestCase 设成 `visible: true`，否则截到纯底色的空图，`mouseMove` 也进不去。
- 带 `layer.enabled` 加 `MultiEffect` 的卡片和面板离屏会整块空白：截图前递归把 `layer.enabled` 设为 false。只关 layer，不碰 `opacity`；入场动画没走完就多等一会儿。
- 离屏平台不开悬停（`Button` 默认 `hoverEnabled` 为假），要看悬停态先显式设 `hoverEnabled = true` 再 `mouseMove`。
- Popup 画在窗口的 overlay 层，`grabImage(testCase)` 截不到；要连弹层、遮罩一起截，截 `testCase.Window.contentItem`。
- `grabImage(…).save()` 没有返回值（失败时抛异常），别写成 `verify(image.save(...))`。
- 状态色带 `Behavior on color` 时截图会慢一帧，先设 `Theme.reduceMotion` 或晚一点截，再下结论。
- 设计稿上看不出生产布局的问题（稿子用 `Column`，生产用 `ColumnLayout` 加 `anchors.fill`）：定稿后用生产视图加桩服务再截一次。

## 容易漏测的场景

几轮代码审查在全绿的测试上确认过一批真缺陷，漏掉的都是下面这几类。新功能写测试时主动补：

- 合法的零值被 `|| 默认值` 吞掉（优先级「低」是 0、日界可以是 0 点）。
- 重复操作：连点建出重复记录、重复改写关联。
- 恢复备份后的变更通知：`AppSettings::reload()` 漏发新属性的 NOTIFY。
- 弹窗打开期间外部数据变了（另一台增删科目）；弹层从「打开」到「选定」之间，同步把选中项换成了邻项。动作要认准打开时记下的目标编号，目标不在了就收起弹层。
- 跨模块状态同步：A 模块写入后 B 模块的服务不发信号，停在 B 页面的用户一直看着旧状态。
- 组合操作：单个动作都对，串起来出错（鼠标翻月没同步键盘光标，回车提交的是看不见的旧日期）。
- 界面的筛选口径和服务端推导状态的口径分了家，整块界面不可达。
- 超长输入被静默截断而不是拒绝：文本字段要测 N 和 N+1 两个边界，并断言被拒绝的写入没留下任何痕迹。
- 常驻页面订阅全局失败信号却没按 `pageActive` 门禁，别处的失败在它身上留下过期的红条。
- 控件实际几何越界（Layout 的最小宽度超过弹窗可用宽度）。
- 外键要按完整约束验证：`PRAGMA foreign_key_list` 逐行看都合规，复合外键要靠 `id`、`seq` 认出来；父表缺对应的复合唯一索引时，新增记录会被拒。

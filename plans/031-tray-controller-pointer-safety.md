# Plan 031: 菜单栏宿主在析构时断开对 TrayController 的裸指针

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/platform src/services/TrayController.cpp src/main.cpp
> grep -n "assign) TrayController" src/platform/macos/MacStatusBarController.mm  # 必须命中
> grep -n "MacStatusBarController statusBar" src/main.cpp                        # 必须命中 :102 附近
> ```

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: correctness（防御性）
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

**先说清楚这条有多严重：现在的代码不会崩。** `main.cpp` 的声明顺序已经挡住了主路径。
这是一条**防御性**改动，不是活跃缺陷——本计划的优先级因此是 P3。

`qml`/ObjC 边界上的宿主对象持有一个**裸的、不带生命周期保证的** C++ 指针：

```objc
// src/platform/macos/MacStatusBarController.mm:10
@property (nonatomic, assign) TrayController* controller;
```

`assign` 等价于 unsafe_unretained：指针不会被置空，`TrayController` 析构后它就悬垂。
五个菜单动作全部这样用它：

```objc
// src/platform/macos/MacStatusBarController.mm:85-89
- (void)pauseClicked  { if (self.controller) self.controller->requestPause(); }
- (void)resumeClicked { if (self.controller) self.controller->requestResume(); }
- (void)stopClicked   { if (self.controller) self.controller->requestStop(); }
- (void)showClicked   { if (self.controller) self.controller->requestShowWindow(); }
- (void)quitClicked   { if (self.controller) self.controller->requestQuit(); }
```

`if (self.controller)` **挡不住悬垂指针**——悬垂指针非空，判断照样通过，然后解引用。

### 为什么现在不会崩

```cpp
// src/main.cpp:99-103
TrayController trayController(FocusTimer::instance());
QObject::connect(&instanceGuard, &SingleInstanceGuard::activationRequested,
                 &trayController, &TrayController::requestShowWindow);
MacStatusBarController statusBar(&trayController);   // ← 声明在后
trayController.setView(&statusBar);
```

两个都是栈对象，`statusBar` 声明在 `trayController` **之后**，因此**先于**它析构。
菜单宿主在被引用者之前就消失了——顺序是对的。

### 那为什么还要改

1. **这个正确性依赖于两行相隔三行的声明顺序，代码里没有任何东西说明这一点。**
   有人调整 `main.cpp` 的初始化顺序、或把 `TrayController` 改成智能指针/成员变量，
   保护就静默消失了，而且**不会有任何编译错误或测试失败**。
2. 退出路径上仍有一个窄窗口：`quitClicked` → `requestQuit()` → 应用开始退出，
   而此时仍在 ObjC 回调栈内。
3. 修法是**一行**：析构时把宿主里的指针置空。成本几乎为零。

## Current state

### 析构现状

```objc
// src/platform/macos/MacStatusBarController.mm:100-106
MacStatusBarController::~MacStatusBarController()
{
    if (m_impl) {
        CFBridgingRelease(m_impl);   // 释放 PTStatusBarController
        m_impl = nullptr;
    }
}
```

`CFBridgingRelease` 把 ARC 强引用还回去。但如果 AppKit 此刻仍持有该对象
（菜单打开、动作在途），对象不会立即 dealloc，而它的 `controller` 指针**仍指向
即将析构的 `TrayController`**。

### 这一层其余部分是好的（不要顺手改）

第五轮审计确认过：
- **ARC 已启用**：`CMakeLists.txt:117` 的 `COMPILE_OPTIONS "-fobjc-arc"`，附中文注释。
- `CFBridgingRetain`/`CFBridgingRelease` 配对正确。
- `MacNotificationBackend` 的完成回调线程处理是对的：
  `src/services/NotificationService.cpp:70-73` 用 `QPointer` + `QMetaObject::invokeMethod`
  切回服务对象线程，并写了注释说明"macOS 完成回调不保证位于 GUI 线程"。

**本计划只动那一个裸指针。**

### 项目约定

- 注释用中文，解释「为什么」和「边界条件」。跨层调用属于必须注释的类别。
- 分层：`src/platform` 只放平台实现，业务留在 `src/services`。

## Commands you will need

构建目录必须在仓库外，**必须显式传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**（cache 变量会粘住）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-031 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-031 -j8` | exit 0 |
| 托盘测试 | `QT_QPA_PLATFORM=offscreen /tmp/pt-031/PlatformControlTests` | 全过 |
| 全量 | `cd /tmp/pt-031 && ctest --output-on-failure` | `100% tests passed ... out of 14` |

## Scope

**In scope**：
- `src/platform/macos/MacStatusBarController.mm`（析构时断开指针 + 注释）
- `src/main.cpp`（**仅**在声明顺序处加一句中文注释说明依赖关系）
- `tests/PlatformControlTests.cpp`（若能构造出可测的断开语义，见 Test plan）

**Out of scope**（不许碰）：
- **`MacNotificationBackend`** —— 第五轮已确认它的 ARC 与线程处理是正确的。
- **`TrayController` 的业务逻辑与 `TrayView` 接口** —— 本计划不改接口形状。
- **把 `TrayController` 改成智能指针 / 单例 / QObject 父子** —— 那是所有权模型的改造，
  远超本计划。**如果你觉得需要这么做，STOP 并报告。**
- `src/main.cpp` 的初始化顺序 —— 现在是对的，只加注释不调顺序。
- 任何 QML 文件。

## Git workflow

- 分支：`advisor/031-tray-pointer-safety`
- 中文提交信息：`菜单栏宿主析构时断开对 TrayController 的引用`
- **不要 push，不要开 PR。**

## Steps

### Step 1: 给 ObjC 宿主加一个显式断开方法

在 `PTStatusBarController` 上加：

```objc
// 宿主可能被 AppKit 短暂持有（菜单打开、动作在途），因此不能依赖它随
// MacStatusBarController 一起立即 dealloc。析构时主动断开裸指针，
// 让后续误触的菜单动作走 nil 分支，而不是解引用一个已析构的 TrayController。
- (void)detachController
{
    self.controller = nullptr;
}
```

### Step 2: 析构时先断开，再释放

```cpp
MacStatusBarController::~MacStatusBarController()
{
    if (m_impl) {
        PTStatusBarController* impl = (__bridge PTStatusBarController*)m_impl;
        // 顺序要紧：先断开对 TrayController 的引用，再交还强引用。
        // 反过来的话，若 AppKit 仍持有宿主，它会带着悬垂指针继续存活。
        [impl detachController];
        CFBridgingRelease(m_impl);
        m_impl = nullptr;
    }
}
```

顺带把状态项从菜单栏移除（`[[NSStatusBar systemStatusBar] removeStatusItem:...]`）
**只有在你确认现状会残留图标时才做**——现代 macOS 上 `NSStatusItem` 释放即移除，
不确定就不要动，并在报告里说明你为什么没做。

**Verify**: `cmake --build /tmp/pt-031 -j8` → exit 0；
`cd /tmp/pt-031 && ctest --output-on-failure` → 14/14

### Step 3: 在 `main.cpp` 记下声明顺序的依赖

`src/main.cpp:99-103` 之上加一句：

```cpp
// statusBar 必须声明在 trayController 之后：栈对象逆序析构，
// 菜单栏宿主要先于它引用的控制器消失。调整这里的顺序前先读
// MacStatusBarController 的析构函数。
```

**只加注释，不动顺序。**

### Step 4: 全量回归

**Verify**: `cd /tmp/pt-031 && ctest --output-on-failure` → 14/14

## Test plan

- **回归**：`PlatformControlTests`（17 个用例）是主要安全网。
- **新增用例的可行性存疑**：`MacStatusBarController` 会真的去创建 `NSStatusItem`，
  在离屏测试环境里构造它可能拉起 AppKit 状态项——**这违反项目"后台验证不得弹窗"的规则**。
  因此：**先判断能否在不创建真实状态项的前提下测到断开语义**。
  - 能 → 加一个用例：构造后析构，断言菜单动作不再解引用（可用一个带标记的
    `TrayController` 派生类观察）。
  - 不能 → **不要硬写**，在报告里说明为什么无法测，本计划接受"无新增用例"。
    一条会拉起系统状态项的测试，代价远大于它的价值。

## Done criteria

- [ ] `cd /tmp/pt-031 && ctest --output-on-failure` → 14/14
- [ ] `grep -n "detachController" src/platform/macos/MacStatusBarController.mm` → 命中
- [ ] 析构函数里 `detachController` 在 `CFBridgingRelease` **之前**
- [ ] `src/main.cpp` 声明顺序处有中文注释说明依赖
- [ ] `git diff src/services/NotificationService.cpp src/platform/macos/MacNotificationBackend.mm`
      → **无输出**（确认没有顺手改那一层）
- [ ] 报告里写明了「是否新增用例」及其理由
- [ ] `plans/README.md` 中 031 的状态行已更新

## STOP conditions

- Drift check 与实际不符。
- 你认为应该把 `TrayController` 的所有权模型改掉（智能指针、QObject 父子、单例）——
  停下报告。那是另一个量级的改动。
- 新增用例会创建真实的 `NSStatusItem` / 弹出任何系统 UI —— 放弃该用例，
  按 Test plan 的说明记录原因。**不要为了"有测试"而违反不弹窗的规则。**
- `PlatformControlTests` 变红。

## Maintenance notes

- **这条的真正价值是把一个隐式依赖写成了显式代码。** 改完之后，
  即使有人调整 `main.cpp` 的声明顺序，宿主也不会带着悬垂指针存活。
- 若将来 `TrayController` 变成堆对象或成员变量，`main.cpp` 那句注释会失去意义——
  届时应该确认 `detachController` 仍在正确的时机被调用。
- 同一层里另外两处已确认是好的（ARC 已开、通知回调正确切线程），
  第五轮审计记录在 `plans/README.md`。**不要在这条上顺手"一起加固"它们。**

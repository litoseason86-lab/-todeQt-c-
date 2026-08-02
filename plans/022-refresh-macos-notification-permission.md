# Plan 022: 每次投递前刷新 macOS 通知授权状态

> **Executor instructions**: 先建立可注入测试边界，再删缓存短路。不要用真实系统通知做自动化测试。完成后更新索引。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/platform/macos/MacNotificationBackend.h src/platform/macos/MacNotificationBackend.mm tests/MacNotificationBackendTests.cpp CMakeLists.txt
> ```

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

后端把一次“拒绝”永久缓存：`deliver()` 看到 `m_authState == 2` 就直接失败，不再向系统查询。用户随后在 macOS 系统设置中重新授权，应用进程仍会一直认为权限被拒，直到重启。权限属于外部可变状态，缓存只能用于展示，不能成为投递前的永久短路。

## Current state

- `MacNotificationBackend::requestAuthorization()` 异步更新原子状态。
- `deliver()` 当前首先执行：

  ```cpp
  if (m_authState->load() == 2) {
      callback(false, QStringLiteral("系统通知权限已被拒绝"));
      return;
  }
  ```

  因此后面的 `getNotificationSettingsWithCompletionHandler` 永远没有机会观察重新授权。
- `.mm` 通过 `safeNotificationCenter()` 保护无 bundle id/裸二进制场景，这是已有崩溃护栏，必须保留。
- 当前没有测试直接编译 `MacNotificationBackend.mm`；`PlatformControlTests` 只测 fake NotificationBackend。
- CMake 为 ObjC++ 后端设置 `-fobjc-arc`，新测试复用同一 `.mm` 时必须继续受 ARC 管理。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-022 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-022 --target MacNotificationBackendTests PomodoroTodo -j8` | exit 0 |
| 定向测试 | `cd /tmp/pt-022 && ctest -R '^MacNotificationBackendTests$' --output-on-failure` | 1/1 通过 |
| 全量 | `cd /tmp/pt-022 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | 15/15 通过（若其他计划已新增测试，以实际总数为准） |

## Suggested executor toolkit

- 使用 `qt-cmake-project` 增加 Qt 6 测试目标并核对 target visibility、ARC 和 Apple framework 链接。
- 不需要 Qt/QML UI Skill；本计划零 QML。

## Scope

**In scope**：`src/platform/macos/MacNotificationBackend.h`、`src/platform/macos/MacNotificationBackend.mm`、`tests/MacNotificationBackendTests.cpp`（新建）、`CMakeLists.txt`。

**Out of scope**：修改 NotificationService 公共接口；更改授权弹窗时机；自动打开系统设置；真实发送系统通知；状态栏 UI；迁移所有既有 CMake target；非 macOS 后端。

## Git workflow

- 分支：`advisor/022-refresh-macos-notification-permission`
- 中文提交信息：`投递通知前刷新系统授权状态`
- 不 push，不开 PR。

## Steps

### Step 1: 创建测试文件和最小测试目标框架

先创建 `tests/MacNotificationBackendTests.cpp`，使用 `QTEST_APPLESS_MAIN`，只放测试类和三条槽声明。CMake 在 Apple 平台新增 `MacNotificationBackendTests`，源包含测试文件与 `MacNotificationBackend.h/.mm`，链接 `Qt6::Core`、`Qt6::Test`、Foundation、UserNotifications；使用 Qt 6 target API，保持 `PRIVATE` visibility。不要创建 GUI bundle，不调用真实通知中心。

确认 `.mm` 的既有 `COMPILE_OPTIONS "-fobjc-arc"` source property 对新 target 生效；必要时把 property 设置保持在两个 target 声明之前，但不要复制一份不同设置。

**Verify**：配置成功；在测试注入 API 未增加前，测试目标可以只有空框架并编译。此阶段不提前实现行为。

### Step 2: 提取纯 C++ 的可注入系统边界

在头文件定义最小函数类型：

- `AuthorizationQuery`：异步返回 allowed 与错误文本。
- `NotificationSubmitter`：接收 title/body/playSound 与既有 DeliveryCallback。

保留无参生产构造函数，再增加供测试使用的构造函数接收这两个函数。头文件不能暴露 Objective-C 类型。生产构造在 `.mm` 内把 `safeNotificationCenter()`、`getNotificationSettings...` 和 `addNotificationRequest...` 包装成默认函数。

共享回调必须安全跨异步生命周期；沿用 `shared_ptr`，不能捕获已析构的 `this`。保留无 bundle id 的中文错误与 ARC 对象生命周期。

**Verify**：应用和测试目标编译；头文件可被纯 `.cpp` 测试包含。

### Step 3: 先写“拒绝后重新授权”红灯测试

用同步 fake query 模拟连续返回 `[false, true]`，fake submitter 计数并成功回调：

1. 第一次 deliver 查询一次、submit 0 次、callback false、`isAuthorized()==false`。
2. 不重建 backend，第二次 deliver 必须再次查询、submit 1 次、callback true、`isAuthorized()==true`。

再覆盖 query 不可用错误原样传递、submitter 失败原样传递且 callback 恰好一次。

**Verify**：保留旧缓存短路时第二次投递用例失败（query count 仍为 1）。若不失败，STOP 检查 fake 是否实际经过缓存状态。

### Step 4: 删除缓存短路，每次投递都查询系统

`deliver()` 不再根据 `m_authState` 提前返回。每次都调用 `AuthorizationQuery`：

- query 失败/未授权：更新 cache 为 denied，callback false，不 submit。
- 授权：更新 cache 为 allowed，再调用 submitter。
- submit 失败不把授权 cache 改成 denied，因为“授权”和“本次投递”是两个不同事实。

`isAuthorized()` 可以继续返回最近一次观察值；中文注释明确它只是缓存展示，不得用于绕过下一次系统查询。

**Verify**：三条新测试通过；应用目标编译。

### Step 5: 全量回归与 CMake 预检

运行定向、全量、`git diff --check`，再执行：

```bash
ctest --test-dir /tmp/pt-022 -N | rg 'MacNotificationBackendTests'
```

**Verify**：新测试被 CTest 注册且通过；没有真实通知、授权弹窗或 GUI 窗口；只改授权文件。

## Test plan

- denied → 同进程外部改为 authorized → 第二次投递成功。
- 授权查询不可用：不提交，请求回调一次并带错误。
- 已授权但 submit 失败：授权 cache 保持 allowed，失败透传。
- 无回调重复调用、无真实系统 API。

## Done criteria

- [ ] `deliver()` 每次都刷新授权，缓存不再短路。
- [ ] 拒绝后重新授权无需重启应用。
- [ ] `safeNotificationCenter` 崩溃护栏完整保留。
- [ ] 新测试完全由注入 fake 驱动，不触发系统通知。
- [ ] 新 CTest 注册，定向和全量测试全绿。
- [ ] CMake 使用明确 PRIVATE 链接与 ARC，`git diff --check` 无输出。
- [ ] 022 状态行已更新。

## STOP conditions

- 当前 Qt/CMake 配置无法把同一 `.mm` 安全编入测试目标。
- 为测试必须 swizzle 系统全局对象或触发真实授权弹窗。
- NotificationBackend 的 callback 生命周期契约已改变。
- 修复需要修改非 macOS 平台或公共 QML API。

## Maintenance notes

- reviewer 要区分“授权查询失败”“未授权”“投递失败”，三者不能共享一个 cache 更新规则。
- 计划 024 依赖本计划，因为它要给这里新增的第 15 个 CTest 条目设置超时。

# Plan 024: 为每个 CTest 进程设置明确超时

> **Executor instructions**: 先盘点实际 CTest 条目，再设置按测试类型分级的进程超时。不要用测试内部 sleep 代替 CTest watchdog。完成后更新索引。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- CMakeLists.txt README.md docs/运行命令.md
> ```
>
> 计划 022 未完成则先执行；本计划必须覆盖其新增的 `MacNotificationBackendTests`。

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/022-refresh-macos-notification-permission.md`
- **Category**: tests / dx
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

当前 CTest 条目没有 `TIMEOUT`，死锁、异步信号丢失或 QML runner 卡住时，后台验证会无限挂起。测试内部的 `wait(10000)` 只能限制某一个断言，不能约束整个进程。显式 watchdog 能把“卡死”变成确定失败，同时给较慢的 QML 套件留出合理余量。

## Current state

- 当前基线有 14 个 CTest；计划 022 会新增 `MacNotificationBackendTests`，执行本计划时应为 15 个。
- `CMakeLists.txt` 已对 `BackupServiceTests`、资产测试和 `PomodoroTodoQmlTests` 设置 ENVIRONMENT，但没有任何 `TIMEOUT` property。
- `PomodoroTodoQmlTests` 把全部 QML 文件放在一个 runner 进程中，是最慢条目，不能与单个资产测试使用同一阈值。
- 官方构建/测试命令分散在 `README.md` 和 `docs/运行命令.md`；文档不得继续给出可能无限等待的裸 `ctest` 作为 CI/后台验证命令。
- 构建目录必须在仓库外，并关闭自动本地部署。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-024 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-024 -j8` | exit 0 |
| 枚举 | `ctest --test-dir /tmp/pt-024 -N` | 15 个测试，含 MacNotificationBackendTests |
| 全量 | `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir /tmp/pt-024 --output-on-failure --timeout 240` | 15/15 通过 |

## Suggested executor toolkit

- 使用 `qt-cmake-project` 核对 `set_tests_properties` 位置、既有 ENVIRONMENT 不被覆盖和 Qt 6 CMake 语法。

## Scope

**In scope**：`CMakeLists.txt`、`README.md`、`docs/运行命令.md`。

**Out of scope**：拆分 QML CTest；删除固定 wait/qSleep；修改测试代码；添加 CI；修改应用 target、部署默认值或 Qt 版本；给测试统一设置过短的全局 `CTEST_TEST_TIMEOUT`。

## Git workflow

- 分支：`advisor/024-ctest-process-timeouts`
- 中文提交信息：`为测试进程设置超时护栏`
- 不 push，不开 PR。

## Steps

### Step 1: 盘点实际条目并保存机器可读基线

配置 `/tmp/pt-024`，执行：

```bash
ctest --test-dir /tmp/pt-024 --show-only=json-v1 > /tmp/pt-024-before.json
python3 -c 'import json; d=json.load(open("/tmp/pt-024-before.json", encoding="utf-8")); print(len(d["tests"])); print("\n".join(t["name"] for t in d["tests"]))'
```

**Verify**：输出 15，且包含 `MacNotificationBackendTests` 与 `PomodoroTodoQmlTests`。不是 15 或缺少 022 测试则 STOP，不要凭旧清单写 properties。

### Step 2: 在所有 add_test 之后设置分级 TIMEOUT

在 `CMakeLists.txt` 所有测试注册完成后集中设置，保持既有 ENVIRONMENT property：

- `PomodoroTodoQmlTests`: 180 秒。
- 业务/数据库 C++ 套件（PomodoroTodoTests、CoreLogicTests、RobustnessTests、CountdownServiceTests、GoalServiceTests、PlatformControlTests、BackupServiceTests、TimingRobustnessTests）: 90 秒。
- 资产/清单/平台小测试（FontAssetsTests、WallpaperAssetsTests、ShaderAssetsTests、SoundAssetsTests、QmlResourceManifestTests、MacNotificationBackendTests）: 30 秒。

使用 `set_tests_properties(... PROPERTIES TIMEOUT N)`，按组列测试名；不要用全局变量覆盖所有条目。加中文注释解释 QML runner 聚合全部文件，所以阈值更宽。

**Verify**：重新配置后导出 JSON，并用 Python 检查每个测试都有 TIMEOUT 且值符合分组：

```bash
ctest --test-dir /tmp/pt-024 --show-only=json-v1 > /tmp/pt-024-after.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/pt-024-after.json', encoding='utf-8'))
missing = []
for test in d['tests']:
    props = {p['name']: p['value'] for p in test.get('properties', [])}
    if 'TIMEOUT' not in props:
        missing.append(test['name'])
print('tests=', len(d['tests']), 'missing=', missing)
raise SystemExit(1 if missing else 0)
PY
```

预期 `tests= 15 missing= []`、exit 0。

### Step 3: 校正文档中的后台测试命令

在 `README.md` 与 `docs/运行命令.md` 的全量后台测试命令加 CLI 总兜底 `--timeout 240`。说明：

- CMake 中每条测试已有更严格的 30/90/180 秒 timeout；CLI 240 是对旧构建缓存/误配置的最后护栏，不替代 target property。
- 保留 `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic`。
- 不修改部署命令，不复用部署构建目录，不写仓库内 `build/`。

**Verify**：

```bash
rg -n "ctest.*--timeout 240|TIMEOUT" README.md docs/运行命令.md CMakeLists.txt
```

预期两份文档各有命令说明，CMake 有三组 TIMEOUT。

### Step 4: 证明 watchdog 生效且正常套件不误杀

先跑全量。然后只做配置级验证，不要故意修改产品测试制造死锁：用 `ctest --show-only=json-v1` 的 property 作为机器证据。

**Verify**：15/15 通过；总耗时明显低于最宽 180 秒不构成硬要求，唯一硬要求是无条目缺 timeout。`git diff --check` 无输出。

## Test plan

- 配置期 JSON 检查 15 个条目全部带 TIMEOUT。
- 分组值检查：QML=180、业务=90、小测试=30。
- 全量 CTest 15/15，现有 ENVIRONMENT 仍存在。
- 文档命令包含 offscreen、Basic、`--timeout 240`。

## Done criteria

- [ ] 15 个 CTest 条目无一缺 TIMEOUT。
- [ ] QML/业务/小测试按 180/90/30 秒分级。
- [ ] 既有 offscreen/Basic 与其他 ENVIRONMENT property 未丢失。
- [ ] README 与运行命令文档有 240 秒 CLI 兜底。
- [ ] 全量测试 15/15，`git diff --check` 无输出。
- [ ] 没有修改任何测试或产品源码。
- [ ] 024 状态行已更新。

## STOP conditions

- 计划 022 未完成，测试总数不是 15 或条目名已变化。
- 任一正常测试在当前机器上稳定超过拟定阈值；先报告实测耗时，不擅自无限放宽。
- 设置 TIMEOUT 会覆盖/丢失既有 ENVIRONMENT。
- 需要修改测试代码才能让全量通过。

## Maintenance notes

- 新增 CTest 时必须同时加入一个超时分组；否则本计划的“全覆盖”会立刻漂移。
- 180 秒不是性能目标，只是死锁护栏。QML 套件拆分后应按实际 P95 下调，而不是永久继承宽阈值。

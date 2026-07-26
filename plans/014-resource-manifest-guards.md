# Plan 014: 给音效与 QML 资源清单补守门测试（漏一条就静默失效）

> **Executor instructions**: 按步骤执行，每步跑完验证命令、确认预期输出再进入下一步。
> 触发 "STOP conditions" 立即停下报告，不要自行发挥。完成后更新 `plans/README.md` 里本计划的状态行。
>
> **Drift check（先跑这个）**：
>
> 本仓库有一批**尚未提交**的工作区改动，`git diff <SHA>..HEAD` 形式的漂移检查在这里无效。
> 改用 grep 判据：
>
> ```bash
> grep -n "sounds/milestone.wav" src/services/PhaseSoundService.cpp   # 必须命中
> grep -n "sounds/milestone.wav" resources/qml.qrc                     # 必须命中
> grep -n "ShaderAssetsTests" CMakeLists.txt                           # 必须命中（要照抄的范式）
> ls tests/ShaderAssetsTests.cpp                                       # 必须存在
> ```
>
> 任一不命中 → STOP，报告实际看到的内容。

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW（纯新增测试，零产品代码改动）
- **Depends on**: none（可与其它计划并行）
- **Category**: tests
- **Planned at**: commit `43ba2ee`（+ 未提交工作区），2026-07-26

## Why this matters

本项目已经为字体、壁纸、Shader 各建了一个「资源守门」测试
（`FontAssetsTests` / `WallpaperAssetsTests` / `ShaderAssetsTests`）——
每个都只有十几行，作用是确认资源真的被打进了二进制。这个范式是对的，
但它有两个洞，而刚交付的奖励机制正好同时踩在这两个洞上：

**洞 1：音效没有守门测试。** `PhaseSoundService` 是**唯一一个不在任何测试可执行文件里的服务**。
它按字面量路径读三个 wav（其中两个是这批改动新加的）。`rcc` 只能发现「文件不存在」，
发现不了「C++ 里写的资源路径和 qrc 里的 alias 对不上」——那种情况下编译通过、
测试全绿、应用启动正常，只是里程碑庆祝**没有声音**，而且没有任何报错。

**洞 2：`qml.qrc` 是一份 74 条的手工清单，没有任何东西校验它的完整性。**
QML 测试 `import "../../qml"` 读的是**源码目录**，而应用运行时读的是 `qrc:/`。
所以一个新组件只要忘了往 qrc 里加一行，就会出现：文件在磁盘上、QML 测试能引用它、
测试全绿——而打包出来的应用一碰到它就报 "is not a type"。
这批改动手工新增了 8 条 QML alias，全靠人眼。

两个测试加起来不到 60 行，堵住的是「测试全绿但应用是坏的」这一整类失败。

## Current state

### 要照抄的范式：`tests/ShaderAssetsTests.cpp`（全文 21 行）

```cpp
#include <QFile>
#include <QtTest>

// Shader 资源守门：Qt 6 的 ShaderEffect 只能读取预编译 QSB，缺失时折射层会静默失效。
class ShaderAssetsTests : public QObject
{
    Q_OBJECT

private slots:
    void liquidGlassShaderIsPackaged()
    {
        QFile shader(QStringLiteral(":/shaders/liquid_glass.frag.qsb"));
        QVERIFY2(shader.exists(), "液态玻璃 QSB 未打包进资源");
        QVERIFY2(shader.open(QIODevice::ReadOnly), "液态玻璃 QSB 无法读取");
        QVERIFY2(shader.size() > 128, "液态玻璃 QSB 内容异常或为空");
    }
};

QTEST_APPLESS_MAIN(ShaderAssetsTests)
#include "ShaderAssetsTests.moc"
```

注意三点：用 `QTEST_APPLESS_MAIN`（不需要 GUI）、断言分三级
（存在 / 可读 / 大小合理）、类顶部有一句中文注释说明**这个守门测试防的是什么失效**。

### 对应的 CMake 注册（`CMakeLists.txt:492-502`）

```cmake
add_executable(ShaderAssetsTests
    tests/ShaderAssetsTests.cpp
    resources/shaders.qrc          # ← 关键：把 qrc 编进测试可执行文件本身
)

target_link_libraries(ShaderAssetsTests PRIVATE
    Qt6::Core
    Qt6::Test
)

add_test(NAME ShaderAssetsTests COMMAND ShaderAssetsTests)
```

`WallpaperAssetsTests` 多了一行环境设置（`CMakeLists.txt:486-490`），因为它要解码图片：

```cmake
set_tests_properties(WallpaperAssetsTests PROPERTIES
    # 图片解码无需真实窗口；offscreen 保证后台不弹窗。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)
```

音效测试只是读文件字节，不播放，**不需要**这行。

### 洞 1 的现场：三个音效资源路径

`src/services/PhaseSoundService.cpp` 顶部：

```cpp
const auto kPhaseCompleteResource = QStringLiteral(":/sounds/phase-complete.wav");   // :10
const auto kMilestoneResource     = QStringLiteral(":/sounds/milestone.wav");        // :12
const auto kGoalAchievedResource  = QStringLiteral(":/sounds/goal-achieved.wav");    // :14
```

`resources/qml.qrc:74-76` 里对应的 alias：

```xml
<file alias="sounds/phase-complete.wav">sounds/phase-complete.wav</file>
<file alias="sounds/milestone.wav">sounds/milestone.wav</file>
<file alias="sounds/goal-achieved.wav">sounds/goal-achieved.wav</file>
```

qrc 的 `prefix="/"`，所以 alias `sounds/x.wav` → 资源路径 `:/sounds/x.wav`。今天是对上的。

### 洞 2 的现场：`resources/qml.qrc`

```xml
<RCC>
    <qresource prefix="/">
        <file alias="qml/qmldir">../qml/qmldir</file>
        <file alias="qml/Theme.qml">../qml/Theme.qml</file>
        <file alias="qml/LogicalDay.js">../qml/LogicalDay.js</file>
        ...
```

实测：74 个 `<file>` 条目 = 70 个 `.qml`/`.js`（`find qml -name "*.qml" -o -name "*.js"`）
+ `qmldir` + 3 个 wav。**当前是完整的**——本计划是给它加一把锁，不是修一个已发生的缺失。

## Commands you will need

构建目录**必须在仓库外**，且**必须传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`**
（该选项默认 ON 且部署目标挂在 `ALL` 上，不关会覆盖 `/Applications/番茄Todo.app`）。

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `cmake -S /Users/zerionlito/code/番茄todo -B /tmp/pt-014 -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译新测试 | `cmake --build /tmp/pt-014 --target SoundAssetsTests -j8` | exit 0 |
| 跑新测试 | `/tmp/pt-014/SoundAssetsTests` | 全过 |
| 列出 ctest 条目 | `cd /tmp/pt-014 && ctest -N` | 从 12 条变成 **13** 条 |
| 全量 | `cd /tmp/pt-014 && ctest --output-on-failure` | `100% tests passed ... out of 13` |

## Scope

**In scope**：
- `tests/SoundAssetsTests.cpp`（新建）
- `tests/QmlResourceManifestTests.cpp`（新建）
- `CMakeLists.txt` — 注册这两个新测试目标（照抄 `ShaderAssetsTests` 的块）

**Out of scope**（看着相关也不许碰）：
- **`src/services/PhaseSoundService.cpp`** —— 一行都不要改。审计发现它有一个真实的
  小问题（每次播放都重新从资源解出临时文件，且从不清理），但那是性能/整洁问题，
  与「资源是否打包正确」是两件事。本计划只加守门测试。
- `resources/qml.qrc` —— 当前是完整的。**如果你的新测试发现它缺条目，STOP 并报告**，
  不要顺手补——那说明有个组件已经在应用里坏了，需要人先看一眼是怎么漏的。
- 任何 `qml/` 文件、任何其它 `src/` 文件。
- 既有的三个资源测试。

## Git workflow

- 分支：`advisor/014-resource-manifest-guards`
- 中文提交信息，例如：`新增音效与 QML 资源清单守门测试`
- **不要 push，不要开 PR。**

## Steps

### Step 1: `tests/SoundAssetsTests.cpp`

照 `ShaderAssetsTests` 的形状写，覆盖三个 wav。**路径字符串必须与
`src/services/PhaseSoundService.cpp:10/12/14` 逐字符一致**——
这个测试的全部价值就在于「C++ 里写的那个字符串真的能打开」。

```cpp
#include <QFile>
#include <QtTest>

// 音效资源守门：PhaseSoundService 按字面量资源路径取 wav，
// rcc 只能发现文件缺失，发现不了"C++ 里的路径与 qrc alias 对不上"。
// 那种情况下编译通过、测试全绿，只是庆祝时没有声音，且没有任何报错。
// 因此这里的路径必须与 PhaseSoundService.cpp 里的常量逐字符一致。
class SoundAssetsTests : public QObject
{
    Q_OBJECT

private slots:
    void phaseCompleteSoundIsPackaged();
    void milestoneSoundIsPackaged();
    void goalAchievedSoundIsPackaged();
    void allSoundsAreValidWavContainers();
};
```

前三个槽照 Shader 的三级断言（存在 / 可读 / 大小 > 一个合理下界，
wav 用 `> 1024` 比 `> 128` 更合适）。

第四个槽多做一步：读前 12 字节，断言是合法的 WAVE 容器
（前 4 字节 `RIFF`，第 8-11 字节 `WAVE`）。理由：这能抓住
「文件被 Git LFS 指针替换」「文件被截断」「误提交了一个改名的 mp3」这类情况，
而单纯的大小检查抓不住。加中文注释说明这一点。

用 `QTEST_APPLESS_MAIN(SoundAssetsTests)` 和 `#include "SoundAssetsTests.moc"` 收尾。

**Verify**: `cmake --build /tmp/pt-014 --target SoundAssetsTests -j8 && /tmp/pt-014/SoundAssetsTests`
→ `Totals: 4 passed, 0 failed`

### Step 2: 在 CMakeLists 注册

照抄 `CMakeLists.txt:492-502` 的 `ShaderAssetsTests` 块，放在它**紧后面**（保持资源测试聚在一起）：

```cmake
add_executable(SoundAssetsTests
    tests/SoundAssetsTests.cpp
    resources/qml.qrc              # 音效打在 qml.qrc 里，不是单独的 qrc
)

target_link_libraries(SoundAssetsTests PRIVATE
    Qt6::Core
    Qt6::Test
)

add_test(NAME SoundAssetsTests COMMAND SoundAssetsTests)
```

注意音效在 `resources/qml.qrc` 里（不像 shader 有自己的 `shaders.qrc`）。
**不需要** `ENVIRONMENT "QT_QPA_PLATFORM=offscreen"`——只读字节，不解码不播放。

**Verify**: `cd /tmp/pt-014 && ctest -N` → 条目数从 12 变 13，能看到 `SoundAssetsTests`

### Step 3: `tests/QmlResourceManifestTests.cpp`

这个测试解决洞 2：确认磁盘上每一个 `.qml`/`.js` 都进了 qrc。

做法：把 `resources/qml.qrc` 编进测试可执行文件，然后用
`QDirIterator(QStringLiteral(":/qml"), QDirIterator::Subdirectories)` 遍历**资源里**的条目，
与源码目录里的文件列表比对。

源码目录路径怎么拿到？**不要硬编码绝对路径**（那样换台机器就废了）。
用 CMake 传进来：

```cmake
target_compile_definitions(QmlResourceManifestTests PRIVATE
    QML_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml"
)
```

测试里：

```cpp
// QML 测试 import 的是源码目录，应用运行时读的是 qrc:/。
// 两者不一致时的表现是：测试全绿，打包出的应用一用到该组件就报 "is not a type"。
// 因此这里逐个比对磁盘文件与资源条目，让"忘了往 qml.qrc 加一行"当场变红。
void QmlResourceManifestTests::everyQmlSourceFileIsInTheResourceManifest()
```

遍历 `QML_SOURCE_DIR` 下所有 `*.qml` 和 `*.js`（含子目录），
对每一个算出它应有的资源路径（`:/qml/<相对路径>`），断言 `QFile::exists`。
失败信息里**必须带上缺失的文件名**——否则执行者看到红灯不知道该加哪一行：

```cpp
QVERIFY2(QFile::exists(resourcePath),
         qPrintable(QStringLiteral("QML 源文件未登记进 resources/qml.qrc：%1").arg(relativePath)));
```

再加一个反向槽，抓「qrc 里留着已删除文件的条目」：

```cpp
void QmlResourceManifestTests::everyManifestEntryHasASourceFile()
```

用 `QDirIterator(":/qml", QDirIterator::Subdirectories)` 遍历资源，
反查磁盘上是否存在对应文件。

**关于 `qmldir`**：它没有 `.qml`/`.js` 后缀，正向槽的过滤会跳过它。
反向槽会遍历到它，要能正确处理。**先跑起来看实际行为，再决定是否需要特殊处理**，
不要预先写一堆猜测性的例外。

**Verify**: `cmake --build /tmp/pt-014 --target QmlResourceManifestTests -j8 && /tmp/pt-014/QmlResourceManifestTests`
→ 全过。当前 qrc 是完整的（74 条 = 70 个 qml/js + qmldir + 3 个 wav），所以应该直接绿。

### Step 4: 证明这两个守门测试真的会红

守门测试最容易犯的错是「写了个永远绿的断言」。**必须实测一次**：

1. 临时把 `resources/qml.qrc` 里**任意一行** `<file>` 注释掉
2. 重新构建并跑 `QmlResourceManifestTests` → **必须红**，且错误信息里点名了那个文件
3. **把改动还原**（`git checkout resources/qml.qrc` 或手动去掉注释）
4. 同样地，临时把 `SoundAssetsTests.cpp` 里某个路径改成一个不存在的名字 → 必须红 → 还原

在最终报告里写明你做了这个验证、看到了什么错误信息。

**Verify**: `git status --short resources/qml.qrc` → 还原后**无输出**

### Step 5: 全量回归

**Verify**:
```
cd /tmp/pt-014 && ctest --output-on-failure
```
→ `100% tests passed, 0 tests failed out of 13`

## Test plan

- **新增** `SoundAssetsTests`：3 个路径的存在/可读/大小 + 1 个 WAVE 容器头校验 = 4 个用例
- **新增** `QmlResourceManifestTests`：正向（源文件都在清单里）+ 反向（清单里没有幽灵条目）= 2 个用例
- 结构范式：`tests/ShaderAssetsTests.cpp`（21 行，`QTEST_APPLESS_MAIN`，三级断言）
- CMake 范式：`CMakeLists.txt:492-502`
- **Step 4 是本计划最重要的一步**：一个从来没红过的守门测试等于没有守门。

## Done criteria

全部必须成立：

- [ ] `cd /tmp/pt-014 && ctest --output-on-failure` → **13/13** 通过（原本 12）
- [ ] `cd /tmp/pt-014 && ctest -N` 输出里有 `SoundAssetsTests` 和 `QmlResourceManifestTests`
- [ ] `/tmp/pt-014/SoundAssetsTests` → `Totals: 4 passed`
- [ ] `git diff --stat src/ qml/ resources/` → **无输出**（零产品代码与资源改动）
- [ ] `grep -c "sounds/" tests/SoundAssetsTests.cpp` → 3（三个路径都覆盖到）
- [ ] `grep -n "QML_SOURCE_DIR" CMakeLists.txt` → 命中（没有硬编码绝对路径）
- [ ] 报告里写明了 Step 4 的实测结果（故意破坏后看到的错误信息）
- [ ] `plans/README.md` 中 014 的状态行已更新

## STOP conditions

停下报告，不要自行发挥：

- Drift check 判据不命中。
- **`QmlResourceManifestTests` 第一次跑就发现 `qml.qrc` 真的缺条目。**
  这意味着已经有组件在打包后的应用里是坏的。报告缺了哪些，**不要自己补 qrc**——
  需要先搞清楚是怎么漏的（可能还有别的同批遗漏）。
- `SoundAssetsTests` 第一次跑就红 —— 同理，报告，不要改 qrc 或改路径。
- 你发现必须修改 `src/services/PhaseSoundService.cpp` 才能测。本计划是**资源打包**守门，
  不是服务行为测试；测的是 `QFile(":/sounds/...")` 能不能打开，不需要碰服务。
- Step 4 里故意破坏之后测试**仍然绿** —— 说明断言写错了，这是必须解决的问题。

## Maintenance notes

- 以后每加一个 QML 组件或音效，忘记登记 qrc 会当场变红，不会再拖到打包之后。
  这两个测试的运行成本都不到 1 秒。
- `QmlResourceManifestTests` 依赖 `QML_SOURCE_DIR` 编译期宏指向源码树。
  **如果将来做成完全独立于源码树的构建产物（比如从 tarball 构建），这个测试会失效**，
  届时应该改成在 CMake 配置期用 `file(GLOB)` 生成期望清单再比对，而不是删掉它。
- 本计划**没有**处理审计发现的另一个 `PhaseSoundService` 问题：
  它每次播放都 `remove` + `copy` 一次临时文件（GUI 线程上的 40-64KB 同步写），
  且这些临时文件从不清理。属于性能与整洁问题，已记录在 `plans/README.md`，
  与资源守门是两件事，刻意没有合并进来。
</content>

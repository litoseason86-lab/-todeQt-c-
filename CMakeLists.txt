cmake_minimum_required(VERSION 3.16)

project(PomodoroTodo VERSION 0.1.0 LANGUAGES CXX)

# 菜单栏与系统通知走 macOS 原生 API（NSStatusItem / UNUserNotificationCenter），
# 需要 Objective-C++ 编译能力。本项目只面向 macOS，不做其它平台分支。
enable_language(OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# 6.7 是 QDateTime::TransitionResolution 的引入版本（见 src/services/LogicalDay.h 的逻辑日边界计算）。
# 不写下界的话，用更低版本的 Qt 也能配置成功，报错要推迟到编译期才出现。
find_package(Qt6 6.7 REQUIRED COMPONENTS Concurrent Core Gui Network Quick QuickControls2 QuickLayouts QuickTest Sql Test)
message(STATUS "使用的 Qt: ${Qt6_VERSION} @ ${Qt6_DIR}")

if(APPLE AND TARGET WrapOpenGL::WrapOpenGL)
    # AGL.framework 是旧版 OpenGL 框架，新版 macOS SDK 已经移除；
    # Qt 的 WrapOpenGL 导入目标可能仍引用它。
    # 当前 SDK 不再提供该框架时，需要移除这个过期链接项。
    set(POMODORO_TODO_EFFECTIVE_SYSROOT "${CMAKE_OSX_SYSROOT}")
    if(NOT POMODORO_TODO_EFFECTIVE_SYSROOT)
        execute_process(
            COMMAND xcrun --sdk macosx --show-sdk-path
            OUTPUT_VARIABLE POMODORO_TODO_EFFECTIVE_SYSROOT
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
    endif()

    set(POMODORO_TODO_CURRENT_SDK_AGL "${POMODORO_TODO_EFFECTIVE_SYSROOT}/System/Library/Frameworks/AGL.framework")
    if(NOT EXISTS "${POMODORO_TODO_CURRENT_SDK_AGL}")
        get_target_property(POMODORO_TODO_OPENGL_LIBS WrapOpenGL::WrapOpenGL INTERFACE_LINK_LIBRARIES)
        if(POMODORO_TODO_OPENGL_LIBS)
            list(FILTER POMODORO_TODO_OPENGL_LIBS EXCLUDE REGEX "^-framework AGL$")
            list(FILTER POMODORO_TODO_OPENGL_LIBS EXCLUDE REGEX "/AGL\\.framework$")
            set_target_properties(WrapOpenGL::WrapOpenGL PROPERTIES
                INTERFACE_LINK_LIBRARIES "${POMODORO_TODO_OPENGL_LIBS}"
            )
        endif()
    endif()
endif()

set(APP_SOURCES
    src/main.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/models/CountdownGoal.cpp
    src/models/LongGoal.h
    src/models/LongGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/ExportService.h
    src/services/ExportService.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/StatisticsService.h
    src/services/StatisticsService.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/FocusSessionRules.h
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/PhaseSoundService.h
    src/services/PhaseSoundService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/GoalService.h
    src/services/GoalService.cpp
    src/services/TrayController.h
    src/services/TrayController.cpp
    src/services/NotificationService.h
    src/services/NotificationService.cpp
    src/services/SingleInstanceGuard.h
    src/services/SingleInstanceGuard.cpp
    src/services/BackupOperations.h
    src/services/BackupOperations.cpp
    src/services/BackupService.h
    src/services/BackupService.cpp
    src/services/GlobalHotkeyBackend.h
    src/services/ShortcutRegistry.h
    src/services/ShortcutRegistry.cpp
    src/platform/macos/MacStatusBarController.h
    src/platform/macos/MacStatusBarController.mm
    src/platform/macos/MacNotificationBackend.h
    src/platform/macos/MacNotificationBackend.mm
    src/platform/macos/MacGlobalHotkeyBackend.h
    src/platform/macos/MacGlobalHotkeyBackend.mm
    resources/qml.qrc
    resources/wallpapers.qrc
    resources/fonts.qrc
    resources/shaders.qrc
)

set(APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/resources/app-icons/PomodoroTodo.icns")
set_source_files_properties("${APP_ICON}" PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources"
)
list(APPEND APP_SOURCES "${APP_ICON}")

add_executable(PomodoroTodo ${APP_SOURCES})

# 菜单栏/通知的 ObjC++ 后端用 ARC 管理 Cocoa 对象生命周期。
# 全局热键后端只调 Carbon 的 C 接口、不持有 ObjC 对象，一并开 ARC 保持编译选项一致。
set_source_files_properties(
    src/platform/macos/MacStatusBarController.mm
    src/platform/macos/MacNotificationBackend.mm
    src/platform/macos/MacGlobalHotkeyBackend.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
)

target_compile_definitions(PomodoroTodo PRIVATE
    POMODORO_TODO_VERSION="${PROJECT_VERSION}"
)

option(POMODORO_TODO_ENABLE_QML_DEBUG "Enable QML debugging and profiling hooks" OFF)
if(POMODORO_TODO_ENABLE_QML_DEBUG)
    # 通过配置项控制 QML 调试钩子，避免为了调试改动发布源码。
    target_compile_definitions(PomodoroTodo PRIVATE QT_QML_DEBUG)
endif()

target_link_libraries(PomodoroTodo PRIVATE
    Qt6::Core
    Qt6::Concurrent
    Qt6::Network
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::QuickLayouts
    Qt6::Sql
    # 菜单栏、通知与窗口/Dock 行为所需的 macOS 系统框架。
    "-framework AppKit"
    "-framework Foundation"
    "-framework UserNotifications"
    # 全局快捷键走 Carbon 的 RegisterEventHotKey：它不需要辅助功能授权，
    # 而 NSEvent 全局监听需要，对一个本地番茄钟来说索要那个权限并不合理。
    "-framework Carbon"
)

set_target_properties(PomodoroTodo PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_ICON_FILE "PomodoroTodo.icns"
    MACOSX_BUNDLE_BUNDLE_NAME "番茄Todo"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.zerionlito.pomodorotodo"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    WIN32_EXECUTABLE TRUE
)

# 日常开发目录保持自动同步；审计/CI/临时构建传 -DPOMODORO_TODO_DEPLOY_LOCAL=OFF，
# 避免非正式构建悄悄覆盖固定启动入口。
option(POMODORO_TODO_DEPLOY_LOCAL "构建后自动把应用同步到本机固定启动入口" ON)

# 会被同步到 /Applications 的构建，不指定类型就默认 RelWithDebInfo。
#
# 空的 CMAKE_BUILD_TYPE 既没有 -O 也没有 -DNDEBUG。实测这个应用的耗时由 SQLite I/O
# 和 Qt 框架（本就已优化）主导，测试套件在两种配置下跑不出差别，所以这里**不是**
# 在追性能；理由是长期使用的那份不该是未指定类型的构建：断言语义、体积、
# 以及"日常入口和临时试验构建用同一档"这件事本身都不对。
# 显式传了 CMAKE_BUILD_TYPE 的（包括 Debug）一律尊重，不覆盖。
if(POMODORO_TODO_DEPLOY_LOCAL AND NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING
        "构建类型（部署构建默认 RelWithDebInfo）" FORCE)
    message(STATUS "部署构建未指定 CMAKE_BUILD_TYPE，已默认为 RelWithDebInfo")
endif()

if(APPLE AND POMODORO_TODO_DEPLOY_LOCAL)
    set(POMODORO_TODO_LOCAL_APP_PATH "/Applications/番茄Todo.app" CACHE PATH
        "本机固定启动入口，构建后会用最新包覆盖这里"
    )
    # 这个路径是 cache 变量，命令行可以覆盖，而下面的部署步骤会对它执行递归删除。
    # 写错一层目录就会不可逆地删掉无关内容，所以在配置阶段就挡住不像应用包的路径。
    if(NOT POMODORO_TODO_LOCAL_APP_PATH MATCHES "\\.app$")
        message(FATAL_ERROR
            "POMODORO_TODO_LOCAL_APP_PATH 必须指向一个 .app 应用包，当前值："
            "${POMODORO_TODO_LOCAL_APP_PATH}。若只想构建而不部署，请传 -DPOMODORO_TODO_DEPLOY_LOCAL=OFF。")
    endif()
    set(POMODORO_TODO_LSREGISTER
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    )

    add_custom_target(deploy-local-app ALL
        COMMAND ${CMAKE_COMMAND} -E echo "Deploying PomodoroTodo to ${POMODORO_TODO_LOCAL_APP_PATH}"
        # 脚本先复制到同文件系统的临时包，验证主二进制后再原子切换，
        # 避免复制失败后 /Applications 中连旧版都不剩。
        COMMAND ${CMAKE_COMMAND}
            "-DSOURCE_APP=$<TARGET_BUNDLE_DIR:PomodoroTodo>"
            "-DDESTINATION_APP=${POMODORO_TODO_LOCAL_APP_PATH}"
            "-DBUNDLE_EXECUTABLE=PomodoroTodo"
            "-DLSREGISTER=${POMODORO_TODO_LSREGISTER}"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/DeployLocalApp.cmake"
        DEPENDS PomodoroTodo
        VERBATIM
    )
endif()

# 编译告警门禁。实测（2026-08-08，Qt 6.9.0 / AppleClang）全仓在 -Wall -Wextra 下
# 只有一条告警且已清掉，所以开启的代价接近零、收益是把这个状态锁住：以后新代码
# 引入未初始化成员、签名不匹配、漏 case 之类的问题会当场暴露，而不是等到审计轮次。
#
# 只加到本项目自己的目标上，不用 CMAKE_CXX_FLAGS 全局污染——那会连 Qt 自动生成的
# moc/qrc 代码也一起管，那些不是我们能修的。
# 不开 -Werror：单条告警不值得阻断本地开发，CI 里可另行升级。
function(pomodoro_todo_enable_warnings target)
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra)
    endif()
endfunction()

pomodoro_todo_enable_warnings(PomodoroTodo)

enable_testing()

add_executable(PomodoroTodoTests
    tests/ServiceTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/models/LongGoal.h
    src/models/LongGoal.cpp
    src/services/GoalService.h
    src/services/GoalService.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/ExportService.h
    src/services/ExportService.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/StatisticsService.h
    src/services/StatisticsService.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(PomodoroTodoTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(PomodoroTodoTests)
add_test(NAME PomodoroTodoTests COMMAND PomodoroTodoTests)

add_executable(CoreLogicTests
    tests/CoreLogicTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(CoreLogicTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(CoreLogicTests)
add_test(NAME CoreLogicTests COMMAND CoreLogicTests)

add_executable(RobustnessTests
    tests/RobustnessTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/StatisticsService.h
    src/services/StatisticsService.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(RobustnessTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(RobustnessTests)
add_test(NAME RobustnessTests COMMAND RobustnessTests)

add_executable(CountdownServiceTests
    tests/CountdownServiceTests.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(CountdownServiceTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(CountdownServiceTests)
add_test(NAME CountdownServiceTests COMMAND CountdownServiceTests)

# 长期目标：进度全部由 focus_sessions 现算，所以测试直接写入专注记录再断言聚合结果。
# 不引入 FocusTimer——本目标验证的是聚合口径与里程碑去重，不是计时器状态机。
add_executable(GoalServiceTests
    tests/GoalServiceTests.cpp
    src/models/LongGoal.h
    src/models/LongGoal.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/GoalService.h
    src/services/GoalService.cpp
    src/services/FocusSessionRules.h
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(GoalServiceTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(GoalServiceTests)
add_test(NAME GoalServiceTests COMMAND GoalServiceTests)

# 菜单栏控制器与通知服务是平台无关层，测试不引入任何 .mm / AppKit 依赖，
# 用假视图与假通知后端验证状态机与降级逻辑。
add_executable(PlatformControlTests
    tests/PlatformControlTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/TrayController.h
    src/services/TrayController.cpp
    src/services/NotificationService.h
    src/services/NotificationService.cpp
    src/services/SingleInstanceGuard.h
    src/services/SingleInstanceGuard.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(PlatformControlTests PRIVATE
    Qt6::Core
    Qt6::Network
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(PlatformControlTests)
add_test(NAME PlatformControlTests COMMAND PlatformControlTests)

# 原生通知授权的状态查询可由 fake 注入，测试不访问系统通知中心或弹授权框。
add_executable(MacNotificationBackendTests
    tests/MacNotificationBackendTests.cpp
    src/services/NotificationService.h
    src/services/NotificationService.cpp
    src/platform/macos/MacNotificationBackend.h
    src/platform/macos/MacNotificationBackend.mm
)

target_link_libraries(MacNotificationBackendTests PRIVATE
    Qt6::Core
    Qt6::Test
    "-framework Foundation"
    "-framework UserNotifications"
)

pomodoro_todo_enable_warnings(MacNotificationBackendTests)
add_test(NAME MacNotificationBackendTests COMMAND MacNotificationBackendTests)

# 快捷键注册表是平台无关层：默认键位、用户覆盖、冲突判定与全局热键装配全在这里，
# 用假热键后端验证，不向系统注册任何真实热键。
add_executable(ShortcutRegistryTests
    tests/ShortcutRegistryTests.cpp
    src/services/GlobalHotkeyBackend.h
    src/services/ShortcutRegistry.h
    src/services/ShortcutRegistry.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
)

target_link_libraries(ShortcutRegistryTests PRIVATE
    Qt6::Core
    # QKeySequence 属于 QtGui；这里不创建任何窗口，离屏平台即可。
    Qt6::Gui
    Qt6::Test
)

pomodoro_todo_enable_warnings(ShortcutRegistryTests)
add_test(NAME ShortcutRegistryTests COMMAND ShortcutRegistryTests)
set_tests_properties(ShortcutRegistryTests PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)

# 全局热键后端里唯一容易写错的是键码/修饰位翻译（Qt 在 macOS 上交换了 Ctrl 与 Meta）。
# 这个目标只测那段纯函数，不调用 RegisterEventHotKey，因此不会占用系统按键。
add_executable(MacGlobalHotkeyTests
    tests/MacGlobalHotkeyTests.cpp
    src/services/GlobalHotkeyBackend.h
    src/platform/macos/MacGlobalHotkeyBackend.h
    src/platform/macos/MacGlobalHotkeyBackend.mm
)

target_link_libraries(MacGlobalHotkeyTests PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    "-framework Carbon"
)

pomodoro_todo_enable_warnings(MacGlobalHotkeyTests)
add_test(NAME MacGlobalHotkeyTests COMMAND MacGlobalHotkeyTests)
set_tests_properties(MacGlobalHotkeyTests PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)

# 备份/恢复：SQLite 快照 + 嵌入偏好；测试用临时目录与临时数据库，覆盖一致性与回滚。
add_executable(BackupServiceTests
    tests/BackupServiceTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/BackupOperations.h
    src/services/BackupOperations.cpp
    src/services/BackupService.h
    src/services/BackupService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(BackupServiceTests PRIVATE
    Qt6::Core
    Qt6::Concurrent
    Qt6::Gui
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(BackupServiceTests)
add_test(NAME BackupServiceTests COMMAND BackupServiceTests)
set_tests_properties(BackupServiceTests PROPERTIES
    # QDesktopServices/QtGui 需要一个平台；离屏即可，不弹窗。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)

# 计时健壮性：注入 FakeClock 模拟休眠、时钟跳变、跨界完成，不依赖真实等待或机器睡眠。
add_executable(TimingRobustnessTests
    tests/TimingRobustnessTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(TimingRobustnessTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(TimingRobustnessTests)
add_test(NAME TimingRobustnessTests COMMAND TimingRobustnessTests)

add_executable(FontAssetsTests
    tests/FontAssetsTests.cpp
    resources/fonts.qrc
)

target_link_libraries(FontAssetsTests PRIVATE
    Qt6::Gui
    Qt6::Test
)

pomodoro_todo_enable_warnings(FontAssetsTests)
add_test(NAME FontAssetsTests COMMAND FontAssetsTests)
set_tests_properties(FontAssetsTests PROPERTIES
    # 字体校验无需真实窗口；offscreen 保证后台不弹窗。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)

add_executable(WallpaperAssetsTests
    tests/WallpaperAssetsTests.cpp
    resources/wallpapers.qrc
)

target_link_libraries(WallpaperAssetsTests PRIVATE
    Qt6::Gui
    Qt6::Test
)

pomodoro_todo_enable_warnings(WallpaperAssetsTests)
add_test(NAME WallpaperAssetsTests COMMAND WallpaperAssetsTests)
set_tests_properties(WallpaperAssetsTests PROPERTIES
    # 图片解码无需真实窗口；offscreen 保证后台不弹窗。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)

add_executable(ShaderAssetsTests
    tests/ShaderAssetsTests.cpp
    resources/shaders.qrc
)

target_link_libraries(ShaderAssetsTests PRIVATE
    Qt6::Core
    Qt6::Test
)

pomodoro_todo_enable_warnings(ShaderAssetsTests)
add_test(NAME ShaderAssetsTests COMMAND ShaderAssetsTests)

add_executable(SoundAssetsTests
    tests/SoundAssetsTests.cpp
    resources/qml.qrc
)

target_link_libraries(SoundAssetsTests PRIVATE
    Qt6::Core
    Qt6::Test
)

pomodoro_todo_enable_warnings(SoundAssetsTests)
add_test(NAME SoundAssetsTests COMMAND SoundAssetsTests)

add_executable(QmlResourceManifestTests
    tests/QmlResourceManifestTests.cpp
    resources/qml.qrc
)

target_compile_definitions(QmlResourceManifestTests PRIVATE
    QML_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml"
)

target_link_libraries(QmlResourceManifestTests PRIVATE
    Qt6::Core
    Qt6::Test
)

pomodoro_todo_enable_warnings(QmlResourceManifestTests)
add_test(NAME QmlResourceManifestTests COMMAND QmlResourceManifestTests)

# QML 静态检查门禁。此前 qmllint 只是「可以手动跑一下」，输出 250 条 unqualified
# 却退出码 0，等于没有门禁——那批告警也确实累积到了 250 条。
#
# 现在 unqualified 与 Quick.layout-positioning 都已清零，接成 ctest 条目把这个状态锁住。
# 判据是「显式豁免两类已知项 + 其余零容忍」，而不是笼统设一个告警数量上限：
# 后者会让「修好一条旧的、混进一条新的」蒙混过关。
#
# 两类豁免的理由：
#   missing-property     —— qmllint 推导不到 ScrollView.contentItem 等运行时类型，属工具限制
#   use-proper-function  —— 项目既定的回调注入模式（AddTaskDialog 的 taskSubmitter 等）
# 任何一类将来被清干净，就把对应的 disable 去掉，门禁自动收紧。
find_program(POMODORO_TODO_QMLLINT
    NAMES qmllint
    HINTS "${QT6_INSTALL_PREFIX}/bin" "${Qt6_DIR}/../../../bin"
    NO_CMAKE_SYSTEM_PATH
)
if(POMODORO_TODO_QMLLINT)
    file(GLOB_RECURSE POMODORO_TODO_QML_SOURCES
        "${CMAKE_CURRENT_SOURCE_DIR}/qml/*.qml")
    add_test(
        NAME QmlLintGate
        COMMAND ${POMODORO_TODO_QMLLINT}
            -I "${CMAKE_CURRENT_SOURCE_DIR}/qml"
            --missing-property disable
            --use-proper-function disable
            --max-warnings 0
            ${POMODORO_TODO_QML_SOURCES}
    )
    set_tests_properties(QmlLintGate PROPERTIES TIMEOUT 60)
    message(STATUS "QML 静态检查门禁已启用: ${POMODORO_TODO_QMLLINT}")
else()
    # 找不到就跳过而不是配置失败：qmllint 随 Qt SDK 提供，但不该让缺它挡住构建。
    message(WARNING "未找到 qmllint，跳过 QML 静态检查门禁")
endif()

# 文本格式门禁：非字面量的 text 绑定必须显式声明 textFormat。
# Qt 的默认值是 AutoText，会用 mightBeRichText() 猜——用户写的任务标题里带
# "<b>" 就会被当富文本解析。qmllint 不管这件事，所以单独一条。
# 用 Python 而不是再写一个 C++ 目标：判据是纯文本模式匹配，不需要跑起应用。
find_package(Python3 COMPONENTS Interpreter)
if(Python3_FOUND)
    add_test(NAME QmlTextFormatGate
             COMMAND ${Python3_EXECUTABLE}
                     ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml_text_format_gate.py
                     ${CMAKE_CURRENT_SOURCE_DIR}/qml)
    set_tests_properties(QmlTextFormatGate PROPERTIES TIMEOUT 60)
    message(STATUS "QML 文本格式门禁已启用")
else()
    message(WARNING "未找到 Python3，跳过 QML 文本格式门禁")
endif()

add_test(
    NAME PomodoroTodoQmlTests
    COMMAND Qt6::qmltestrunner -input ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml
)
set_tests_properties(PomodoroTodoQmlTests PROPERTIES
    # 测试固定离屏平台与 Basic 风格，后台验证不得创建真实应用窗口。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic"
)

# 每个 CTest 进程都需要 watchdog：QML runner 聚合全部文件，因此比单个业务/资产测试留出更宽余量。
set_tests_properties(PomodoroTodoQmlTests PROPERTIES TIMEOUT 180)
set_tests_properties(
    PomodoroTodoTests
    CoreLogicTests
    RobustnessTests
    CountdownServiceTests
    GoalServiceTests
    PlatformControlTests
    BackupServiceTests
    TimingRobustnessTests
    ShortcutRegistryTests
    PROPERTIES TIMEOUT 90
)
set_tests_properties(
    FontAssetsTests
    WallpaperAssetsTests
    ShaderAssetsTests
    SoundAssetsTests
    QmlResourceManifestTests
    MacNotificationBackendTests
    MacGlobalHotkeyTests
    PROPERTIES TIMEOUT 30
)

cmake_minimum_required(VERSION 3.16)

project(PomodoroTodo VERSION 0.1.0 LANGUAGES CXX)

# 菜单栏与系统通知走 macOS 原生 API（NSStatusItem / UNUserNotificationCenter），
# 需要 Objective-C++ 编译能力。平台只有 macOS 与 iOS 两个：iOS 构建只产出应用本体，
# 菜单栏、全局热键、外部 AI 接入、测试与本机部署都只属于 macOS（见下方 if(IOS) 分支）。
enable_language(OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# 6.7 是 QDateTime::TransitionResolution 的引入版本（见 src/services/LogicalDay.h 的逻辑日边界计算）。
# 不写下界的话，用更低版本的 Qt 也能配置成功，报错要推迟到编译期才出现。
find_package(Qt6 6.7 REQUIRED COMPONENTS Concurrent Core Gui Network Qml Quick QuickControls2 QuickLayouts Sql)
if(NOT IOS)
    # 测试只在 macOS 上离屏运行；iOS 构建不注册任何测试，也就不要求 iOS 套件带测试模块。
    find_package(Qt6 6.7 REQUIRED COMPONENTS QuickTest Test)
endif()

# CVE-2025-12385：Text 组件解析 <img> 时不校验尺寸，可导致无限制内存分配与界面失去响应。
# 影响 5.0.0–6.5.10、6.6.0–6.8.5、6.9.0–6.10.0，修复于 6.5.11 / 6.8.6 / 6.10.1。
#
# 只警告不报错，两个理由：本项目已落实官方缓解措施（所有非字面量的 text 绑定显式
# PlainText，由 QmlTextFormatGate 强制）；而发行版打包的 Qt 常把补丁向后移植却不动
# 版本号，硬卡版本会把这些完全安全的构建也挡在外面。
set(POMODORO_TODO_CVE_2025_12385_FIXED FALSE)
if(Qt6_VERSION VERSION_GREATER_EQUAL "6.10.1"
   OR (Qt6_VERSION VERSION_GREATER_EQUAL "6.8.6" AND Qt6_VERSION VERSION_LESS "6.9.0")
   OR (Qt6_VERSION VERSION_GREATER_EQUAL "6.5.11" AND Qt6_VERSION VERSION_LESS "6.6.0"))
    set(POMODORO_TODO_CVE_2025_12385_FIXED TRUE)
endif()
if(NOT POMODORO_TODO_CVE_2025_12385_FIXED)
    message(WARNING
        "当前 Qt ${Qt6_VERSION} 在 CVE-2025-12385 的影响范围内（Text 组件不校验 <img> 尺寸）。"
        "本项目已落实官方缓解措施（全部非字面量 text 绑定显式 PlainText），"
        "但仍建议升级到 6.10.1+ / 6.8.6+ / 6.5.11+。"
        "若你用的是已向后移植补丁的发行版打包，可忽略本条。")
endif()
message(STATUS "使用的 Qt: ${Qt6_VERSION} @ ${Qt6_DIR}")

if(APPLE AND NOT IOS AND TARGET WrapOpenGL::WrapOpenGL)
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
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
    src/services/ExportService.h
    src/services/ExportService.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/ApplicationActivity.h
    src/services/ApplicationActivity.cpp
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
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    src/services/TrayController.h
    src/services/TrayController.cpp
    src/services/NotificationService.h
    src/services/NotificationService.cpp
    src/services/PhaseAlarmCoordinator.h
    src/services/PhaseAlarmCoordinator.cpp
    src/services/BackupOperations.h
    src/services/BackupOperations.cpp
    src/services/BackupService.h
    src/services/BackupService.cpp
    src/services/SnapshotRetention.h
    src/services/GlobalHotkeyBackend.h
    src/services/ShortcutRegistry.h
    src/services/ShortcutRegistry.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/TaskInteractionCoordinator.h
    src/services/TaskInteractionCoordinator.cpp
    # 外部 AI 接入（plans/047）：common 是与辅助程序共用的契约与路径，bridge 只编入主应用。
    src/mcp/common/McpContracts.h
    src/mcp/common/McpContracts.cpp
    src/mcp/common/McpPaths.h
    src/mcp/common/McpPaths.cpp
    src/mcp/common/McpJsonStream.h
    src/mcp/common/McpJsonStream.cpp
    src/mcp/common/McpEndpointFiles.h
    src/mcp/common/McpEndpointFiles.cpp
    resources/qml.qrc
    resources/wallpapers.qrc
    resources/fonts.qrc
    resources/shaders.qrc
)

if(NOT IOS)
    # 只在 macOS 存在的能力：单实例守卫（本地 socket 召回窗口）、外部 AI 接入的主应用侧、
    # 菜单栏、系统通知后端、全局热键与偏好域清理。iOS 由系统保证单实例，
    # 也没有外部进程能连进来，这些源码整体不编入；main.cpp 里的装配用 Q_OS_MACOS 同步圈住。
    list(APPEND APP_SOURCES
        src/services/SingleInstanceGuard.h
        src/services/SingleInstanceGuard.cpp
        src/mcp/bridge/McpAccessController.h
        src/mcp/bridge/McpAccessController.cpp
        src/mcp/bridge/McpLocalServer.h
        src/mcp/bridge/McpLocalServer.cpp
        src/platform/macos/MacLocalPeerIdentity.h
        src/platform/macos/MacLocalPeerIdentity.cpp
        src/mcp/bridge/McpToolDispatcher.h
        src/mcp/bridge/McpToolDispatcher.cpp
        src/mcp/bridge/McpTaskWrites.cpp
        src/mcp/bridge/McpCreateRegistry.h
        src/mcp/bridge/McpCreateRegistry.cpp
        src/platform/macos/MacStatusBarController.h
        src/platform/macos/MacStatusBarController.mm
        src/platform/macos/MacNotificationBackend.h
        src/platform/macos/MacNotificationBackend.mm
        src/platform/macos/MacGlobalHotkeyBackend.h
        src/platform/macos/MacGlobalHotkeyBackend.mm
        src/platform/macos/MacPreferencesCleanup.h
        src/platform/macos/MacPreferencesCleanup.mm
    )

    set(APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/resources/app-icons/PomodoroTodo.icns")
    set_source_files_properties("${APP_ICON}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources"
    )
    list(APPEND APP_SOURCES "${APP_ICON}")
endif()

if(IOS)
    # UserNotifications 在 iOS 上是同一套接口，通知后端直接复用 macOS 目录里的实现。
    list(APPEND APP_SOURCES
        src/platform/macos/MacNotificationBackend.h
        src/platform/macos/MacNotificationBackend.mm
    )
    set_source_files_properties(src/platform/macos/MacNotificationBackend.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
    )
endif()

if(IOS)
    # iOS 上的 Qt 是静态库：平台插件和 QML 插件要靠 Qt 的收尾步骤扫描导入并链接进来，
    # 所以必须用 qt_add_executable。MANUAL_FINALIZATION 让收尾在下方 iOS 属性全部设好之后
    # 才执行（见 qt_finalize_target）。macOS 保持原来的 add_executable，避免 Qt 的收尾步骤
    # 改写 Mac 包的 Info.plist 等既有产物。
    qt_add_executable(PomodoroTodo MANUAL_FINALIZATION ${APP_SOURCES})
else()
    add_executable(PomodoroTodo ${APP_SOURCES})
endif()

# 菜单栏/通知的 ObjC++ 后端用 ARC 管理 Cocoa 对象生命周期。
# 全局热键后端只调 Carbon 的 C 接口、不持有 ObjC 对象，一并开 ARC 保持编译选项一致。
if(NOT IOS)
    set_source_files_properties(
        src/platform/macos/MacStatusBarController.mm
        src/platform/macos/MacNotificationBackend.mm
        src/platform/macos/MacGlobalHotkeyBackend.mm
        src/platform/macos/MacPreferencesCleanup.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
    )
endif()

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
)

if(IOS)
    target_link_libraries(PomodoroTodo PRIVATE
        "-framework Foundation"
        "-framework UserNotifications"
    )
endif()

if(NOT IOS)
    target_link_libraries(PomodoroTodo PRIVATE
        # 菜单栏、通知与窗口/Dock 行为所需的 macOS 系统框架。
        "-framework AppKit"
        "-framework Foundation"
        "-framework UserNotifications"
        # 全局快捷键走 Carbon 的 RegisterEventHotKey：它不需要辅助功能授权，
        # 而 NSEvent 全局监听需要，对一个本地番茄钟来说索要那个权限并不合理。
        "-framework Carbon"
    )
endif()

set_target_properties(PomodoroTodo PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "番茄Todo"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.zerionlito.pomodorotodo"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    WIN32_EXECUTABLE TRUE
)
if(NOT IOS)
    # .icns 只有 macOS 认；iOS 图标要用资源目录（asset catalog），验证阶段先用系统默认图标。
    set_target_properties(PomodoroTodo PROPERTIES MACOSX_BUNDLE_ICON_FILE "PomodoroTodo.icns")
endif()

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

if(APPLE AND NOT IOS AND POMODORO_TODO_DEPLOY_LOCAL)
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
            "-DHELPER_EXECUTABLE=PomodoroTodoMcp"
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

if(IOS)
    # 免费个人团队注册包标识时要求全局唯一；若 Xcode 提示已被占用，改这个缓存变量即可。
    set(POMODORO_TODO_IOS_BUNDLE_ID "com.zerionlito.pomodorotodo" CACHE STRING
        "iOS 包标识")
    # 开发团队 ID 在 Xcode 的 Settings → Accounts 里查看；留空时交给 Qt 从 Xcode 偏好里自动探测。
    set(POMODORO_TODO_IOS_DEVELOPMENT_TEAM "" CACHE STRING
        "iOS 签名使用的开发团队 ID")

    set_target_properties(PomodoroTodo PROPERTIES
        # Xcode 生成器会把 Info.plist 的 CFBundleIdentifier 写成 PRODUCT_BUNDLE_IDENTIFIER 的引用，
        # 所以改这一处就够了，签名与包内标识自动保持一致。
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${POMODORO_TODO_IOS_BUNDLE_ID}"
        # 1 = iPhone，2 = iPad：同一个包同时装到两种设备上。
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
        # 静态 Qt 需要扫描 QML 的 import 语句来决定链接哪些 QML 插件。
        # 只扫应用自己的 qml/ 目录：tests/qml 里的 QtTest 导入不属于应用，扫进来会白白链接测试模块。
        QT_QML_ROOT_PATH "${CMAKE_CURRENT_SOURCE_DIR}/qml"
        # 自带 Info.plist 模板：Qt 默认把主屏幕显示名写成目标名 PomodoroTodo，这里改用中文包名。
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/src/platform/ios/Info.plist.in"
    )
    if(POMODORO_TODO_IOS_DEVELOPMENT_TEAM)
        set_target_properties(PomodoroTodo PROPERTIES
            XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${POMODORO_TODO_IOS_DEVELOPMENT_TEAM}"
            XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
        )
    endif()

    qt_finalize_target(PomodoroTodo)

    # iOS 构建到此为止：下方的外部 AI 辅助程序、测试与门禁都只在 macOS 上构建和运行，
    # 本机部署目标也已在上方按平台排除。这个目录（约定 ~/pt-ios）永不部署。
    message(STATUS "iOS 构建：只产出应用本体，不注册测试、不部署")
    return()
endif()

# 外部 AI 接入的无界面辅助程序：AI 客户端以 stdio 方式拉起它，它只负责 MCP 协议与转发。
# 源码清单只列 helper 与 common，业务服务、SQL 与 QML 一律不编入——辅助程序不直接碰数据库，
# 权限判断与读写都在主应用内完成。McpHelperLinkGate 会检查它确实没有链接这些模块。
# 下面的 bundle-mcp-helper 将产物复制到应用包 Contents/MacOS/。
qt_add_executable(PomodoroTodoMcp
    src/mcp/helper/main.cpp
    src/mcp/helper/McpStdioServer.h
    src/mcp/helper/McpStdioServer.cpp
    src/mcp/helper/McpStdioDevice.h
    src/mcp/helper/McpStdioDevice.cpp
    src/mcp/helper/McpBridgeClient.h
    src/mcp/helper/McpBridgeClient.cpp
    src/mcp/common/McpContracts.h
    src/mcp/common/McpContracts.cpp
    src/mcp/common/McpPaths.h
    src/mcp/common/McpPaths.cpp
    src/mcp/common/McpJsonStream.h
    src/mcp/common/McpJsonStream.cpp
    src/mcp/common/McpEndpointFiles.h
    src/mcp/common/McpEndpointFiles.cpp
)

target_compile_definitions(PomodoroTodoMcp PRIVATE
    POMODORO_TODO_VERSION="${PROJECT_VERSION}"
)

target_link_libraries(PomodoroTodoMcp PRIVATE
    Qt6::Core
    Qt6::Network
)

pomodoro_todo_enable_warnings(PomodoroTodoMcp)

if(APPLE)
    # 单独的打包目标每次核对复制；helper 改动即使主程序无需重链也会进入新包。
    add_custom_target(bundle-mcp-helper ALL
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:PomodoroTodoMcp>"
            "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/MacOS/PomodoroTodoMcp"
        DEPENDS PomodoroTodo PomodoroTodoMcp
        VERBATIM
    )
    if(TARGET deploy-local-app)
        add_dependencies(deploy-local-app bundle-mcp-helper)
    endif()
endif()


enable_testing()

add_executable(PomodoroTodoTests
    tests/ServiceTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
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

# Qml 只给服务测试用：用 QJSEngine 走一遍界面调用 Q_INVOKABLE 的真实路径（重载选择、
# undefined/null/空串的转换），C++ 直接调用测不到这一层。
target_link_libraries(PomodoroTodoTests PRIVATE
    Qt6::Core
    Qt6::Concurrent
    Qt6::Qml
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
    Qt6::Concurrent
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
    src/services/RoutineRules.h
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
    Qt6::Concurrent
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

# 知识缺口：捕获、排期、状态流转与转任务事务。
# 需要 TaskManager 是因为 convertToTask 会真的往 tasks 里插行，测试要能回查这条任务；
# 不引入 FocusTimer——知识缺口本来就不接计时。
add_executable(KnowledgeGapServiceTests
    tests/KnowledgeGapServiceTests.cpp
    src/models/Task.h
    src/models/Task.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
)

target_link_libraries(KnowledgeGapServiceTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(KnowledgeGapServiceTests)
add_test(NAME KnowledgeGapServiceTests COMMAND KnowledgeGapServiceTests)

# 课表：只验证存储与「按周次筛选」两件事。日期到周次的换算不在这里——
# 它在 QML 侧的 ScheduleWeeks.js，由 QML 测试覆盖。
# 不引入 TaskManager/FocusTimer：课表项与任务、专注记录之间没有任何写入关系，
# 把它们连进来只会让「课表不影响统计」这条不变量变得难以断言。
add_executable(ScheduleServiceTests
    tests/ScheduleServiceTests.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # AppSettings 只为一条用例引入：它把「学期总周数上限」与
    # ScheduleService::kMaxWeekIndex 钉死在一起，两处常量不能各改各的。
    src/services/AppSettings.h
    src/services/AppSettings.cpp
)

target_link_libraries(ScheduleServiceTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(ScheduleServiceTests)
add_test(NAME ScheduleServiceTests COMMAND ScheduleServiceTests)

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

# 偏好清理直接读写 CoreFoundation 偏好：用例只写按进程号命名的临时偏好域，结束时删掉，
# 系统全局域只读不写。
add_executable(MacPreferencesCleanupTests
    tests/MacPreferencesCleanupTests.cpp
    src/platform/macos/MacPreferencesCleanup.h
    src/platform/macos/MacPreferencesCleanup.mm
)

target_link_libraries(MacPreferencesCleanupTests PRIVATE
    Qt6::Core
    Qt6::Test
    "-framework CoreFoundation"
)

pomodoro_todo_enable_warnings(MacPreferencesCleanupTests)
add_test(NAME MacPreferencesCleanupTests COMMAND MacPreferencesCleanupTests)

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

# 番茄到点提醒的系统预约：用假通知后端手动控制系统回调的先后，
# 验证串行执行、代次防迟到回调、自然到点不撤销、失败时退回即时提醒。
add_executable(PhaseAlarmCoordinatorTests
    tests/PhaseAlarmCoordinatorTests.cpp
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
    src/services/NotificationService.h
    src/services/NotificationService.cpp
    src/services/PhaseAlarmCoordinator.h
    src/services/PhaseAlarmCoordinator.cpp
)

target_link_libraries(PhaseAlarmCoordinatorTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(PhaseAlarmCoordinatorTests)
add_test(NAME PhaseAlarmCoordinatorTests COMMAND PhaseAlarmCoordinatorTests)

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

# 外部 AI 接入的共享契约与本机路径：纯函数测试，不启动辅助程序、不连接端点、不创建目录。
qt_add_executable(McpProtocolTests
    tests/McpProtocolTests.cpp
    src/mcp/common/McpContracts.h
    src/mcp/common/McpContracts.cpp
    src/mcp/common/McpPaths.h
    src/mcp/common/McpPaths.cpp
)

target_link_libraries(McpProtocolTests PRIVATE
    Qt6::Core
    Qt6::Test
)

pomodoro_todo_enable_warnings(McpProtocolTests)
add_test(NAME McpProtocolTests COMMAND McpProtocolTests)

# 与生产 helper 共用入口和传输实现，测试入口仅接受显式临时目录，不能回退到生产端点。
get_target_property(POMODORO_MCP_HELPER_SOURCES PomodoroTodoMcp SOURCES)
qt_add_executable(McpTestHelper ${POMODORO_MCP_HELPER_SOURCES})
target_compile_definitions(McpTestHelper PRIVATE MCP_TEST_HOST POMODORO_TODO_VERSION="${PROJECT_VERSION}")
target_link_libraries(McpTestHelper PRIVATE Qt6::Core Qt6::Network)
pomodoro_todo_enable_warnings(McpTestHelper)

qt_add_executable(McpIntegrationTests
    tests/McpIntegrationTests.cpp
    src/mcp/common/McpContracts.h src/mcp/common/McpContracts.cpp
    src/mcp/common/McpPaths.h src/mcp/common/McpPaths.cpp
    src/mcp/common/McpJsonStream.h src/mcp/common/McpJsonStream.cpp
    src/mcp/common/McpEndpointFiles.h src/mcp/common/McpEndpointFiles.cpp
    src/mcp/helper/McpBridgeClient.h src/mcp/helper/McpBridgeClient.cpp
    src/mcp/bridge/McpAccessController.h src/mcp/bridge/McpAccessController.cpp
    src/mcp/bridge/McpLocalServer.h src/mcp/bridge/McpLocalServer.cpp
    src/platform/macos/MacLocalPeerIdentity.h src/platform/macos/MacLocalPeerIdentity.cpp
)
target_link_libraries(McpIntegrationTests PRIVATE Qt6::Core Qt6::Network Qt6::Test)
target_compile_definitions(McpIntegrationTests PRIVATE MCP_TEST_HELPER="$<TARGET_FILE:McpTestHelper>")
add_dependencies(McpIntegrationTests McpTestHelper)
pomodoro_todo_enable_warnings(McpIntegrationTests)
add_test(NAME McpIntegrationTests COMMAND McpIntegrationTests)
set_tests_properties(McpIntegrationTests PROPERTIES TIMEOUT 120)

# 只读工具与真实服务共用隔离数据库，辅助程序目标仍不链接这些业务依赖。
qt_add_executable(McpServiceTests
    tests/McpServiceTests.cpp
    src/models/Task.h src/models/Task.cpp
    src/services/ServiceReadResult.h
    src/services/DatabaseManager.h src/services/DatabaseManager.cpp
    src/services/AppSettings.h src/services/AppSettings.cpp
    src/services/TaskManager.h src/services/TaskManager.cpp
    src/services/CategoryManager.h src/services/CategoryManager.cpp
    src/services/StatisticsService.h src/services/StatisticsService.cpp
    src/services/KnowledgeGapService.h src/services/KnowledgeGapService.cpp
    src/services/TaskInteractionCoordinator.h src/services/TaskInteractionCoordinator.cpp
    src/mcp/common/McpContracts.h src/mcp/common/McpContracts.cpp
    src/mcp/bridge/McpToolDispatcher.h src/mcp/bridge/McpToolDispatcher.cpp
    src/mcp/bridge/McpTaskWrites.cpp
    src/mcp/bridge/McpCreateRegistry.h src/mcp/bridge/McpCreateRegistry.cpp
)
target_link_libraries(McpServiceTests PRIVATE Qt6::Core Qt6::Sql Qt6::Test)
pomodoro_todo_enable_warnings(McpServiceTests)
add_test(NAME McpServiceTests COMMAND McpServiceTests)

# SDK / 实际客户端联调的隔离宿主，不注册默认 CTest，不依赖 Node。
get_target_property(POMODORO_MCP_SERVICE_TEST_SOURCES McpServiceTests SOURCES)
list(FILTER POMODORO_MCP_SERVICE_TEST_SOURCES EXCLUDE REGEX "tests/McpServiceTests[.]cpp$")
qt_add_executable(McpSdkHost
    tests/McpSdkHost.cpp
    ${POMODORO_MCP_SERVICE_TEST_SOURCES}
    src/mcp/common/McpPaths.h src/mcp/common/McpPaths.cpp
    src/mcp/common/McpJsonStream.h src/mcp/common/McpJsonStream.cpp
    src/mcp/common/McpEndpointFiles.h src/mcp/common/McpEndpointFiles.cpp
    src/mcp/bridge/McpAccessController.h src/mcp/bridge/McpAccessController.cpp
    src/mcp/bridge/McpLocalServer.h src/mcp/bridge/McpLocalServer.cpp
    src/mcp/helper/McpStdioDevice.h src/mcp/helper/McpStdioDevice.cpp
    src/platform/macos/MacLocalPeerIdentity.h src/platform/macos/MacLocalPeerIdentity.cpp
)
target_link_libraries(McpSdkHost PRIVATE Qt6::Core Qt6::Sql Qt6::Network)
pomodoro_todo_enable_warnings(McpSdkHost)

# 辅助程序链接门禁：只允许 Qt Core/Network。源码清单写对了还不够——
# 以后有人在 helper 里顺手 include 一个服务头文件、再补一行链接库，清单看不出来，链接结果看得出来。
add_test(
    NAME McpHelperLinkGate
    COMMAND ${CMAKE_COMMAND}
        "-DHELPER_BINARY=$<TARGET_FILE:PomodoroTodoMcp>"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CheckMcpHelperLinks.cmake"
)

# QML 静态检查门禁。此前 qmllint 只是「可以手动跑一下」，输出 250 条 unqualified
# 却退出码 0，等于没有门禁——那批告警也确实累积到了 250 条。
#
# 现在显式开启 missing-property 与 use-proper-function，已知静态推导限制只在
# 具体表达式旁成对压制。其他位置新增任意一条告警都会因 max-warnings 0 失败；
# ignore-settings 防止开发者本机配置改变 CI 和本地门禁的共同判据。
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
            --ignore-settings
            -I "${CMAKE_CURRENT_SOURCE_DIR}/qml"
            --missing-property warning
            --use-proper-function warning
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
    if(APPLE)
        add_test(NAME McpBundleSmoke
            COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/check_mcp_bundle.py"
                "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/MacOS/PomodoroTodoMcp")
        add_test(NAME DeployLocalAppTests
            COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/DeployLocalAppTests.py")
    endif()
    add_test(NAME QmlTextFormatGate
             COMMAND ${Python3_EXECUTABLE}
                     ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml_text_format_gate.py
                     ${CMAKE_CURRENT_SOURCE_DIR}/qml)
    set_tests_properties(QmlTextFormatGate PROPERTIES TIMEOUT 60)
    message(STATUS "QML 文本格式门禁已启用")

    # 悬停过渡门禁：带 `Behavior on color` 的状态色不得回落到黑基透明。
    # Qt 的 "transparent" / Qt.rgba(0,0,0,0) 是透明黑，ColorAnimation 会从它插值出灰色，
    # 界面上就是「鼠标刚放上去，按钮下面闪过一道阴影」。同样是纯文本判据，跟着上面这条走。
    add_test(NAME QmlHoverTransitionGate
             COMMAND ${Python3_EXECUTABLE}
                     ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml_hover_transition_gate.py
                     ${CMAKE_CURRENT_SOURCE_DIR}/qml)
    set_tests_properties(QmlHoverTransitionGate PROPERTIES TIMEOUT 60)
    message(STATUS "QML 悬停过渡门禁已启用")
else()
    message(WARNING "未找到 Python3，跳过 QML 文本格式与悬停过渡门禁")
endif()

# QML 测试按文件拆成独立 ctest 条目。聚合成一条时 qmltestrunner 在单进程里串行跑完
# 全部文件，`ctest -j` 对全量耗时最大的这一块完全无效——实测它占 -j4 全量 57s 中的 56s。
# 拆开后同样的机器上并行跑约 25s。
#
# CONFIGURE_DEPENDS 是必须的：没有它，新增一个 tst_*.qml 之后 CMake 不会重新 glob，
# 新测试会静默不被执行——那比不拆更危险。
file(GLOB POMODORO_TODO_QML_TEST_FILES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/qml/tst_*.qml")

foreach(qml_test_file IN LISTS POMODORO_TODO_QML_TEST_FILES)
    get_filename_component(qml_test_name "${qml_test_file}" NAME_WE)
    string(REGEX REPLACE "^tst_" "" qml_test_name "${qml_test_name}")
    add_test(
        NAME QmlTest.${qml_test_name}
        COMMAND Qt6::qmltestrunner -input "${qml_test_file}"
    )
    set_tests_properties(QmlTest.${qml_test_name} PROPERTIES
        # 测试固定离屏平台与 Basic 风格，后台验证不得创建真实应用窗口。
        # 每条都要带：漏掉一条就会在无头环境里尝试拉起 cocoa 窗口并挂住。
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic"
        # 单文件比聚合快得多，但最慢的 tst_ui_optimization 实测约 20s，留足慢机器余量。
        TIMEOUT 120
        # QML 运行时告警一律判失败。
        #
        # 这些告警不会让任何断言转红，测试照样全绿，但每一条都是真缺陷：
        #   Unable to assign [undefined]  属性赋值被拒，绑定停在上一次的值
        #   TypeError / is not a function 求值当场中断，后面的兜底逻辑根本跑不到
        #   Binding loop                  绑定反复求值，界面可能停在中间态
        # 实测本仓曾同时存在三处：ExportDialog 的 busy 决定导出期间能否关窗却停在旧值；
        # MonthGoalView.formatDuration 抛 TypeError，跳过了它自己写的兜底格式化。
        #
        # 挂在已有条目上而不是新加一条门禁：串行重跑全部 QML 测试实测 63s，
        # 会让全量从 22s 涨到三倍以上，而这里是零额外开销。
        # 某条测试确实需要故意触发告警时，单独覆盖它的 FAIL_REGULAR_EXPRESSION。
        FAIL_REGULAR_EXPRESSION "Unable to assign;TypeError;is not a function;Binding loop"
    )
endforeach()

list(LENGTH POMODORO_TODO_QML_TEST_FILES POMODORO_TODO_QML_TEST_COUNT)
message(STATUS "QML 测试已拆分为 ${POMODORO_TODO_QML_TEST_COUNT} 条独立 ctest 条目")
set_tests_properties(
    PomodoroTodoTests
    CoreLogicTests
    RobustnessTests
    CountdownServiceTests
    PlatformControlTests
    BackupServiceTests
    TimingRobustnessTests
    PhaseAlarmCoordinatorTests
    ShortcutRegistryTests
    PROPERTIES TIMEOUT 90
)
set_tests_properties(
    FontAssetsTests
    WallpaperAssetsTests
    ShaderAssetsTests
    SoundAssetsTests
    QmlResourceManifestTests
    McpProtocolTests
    McpHelperLinkGate
    MacNotificationBackendTests
    MacPreferencesCleanupTests
    MacGlobalHotkeyTests
    PROPERTIES TIMEOUT 30
)

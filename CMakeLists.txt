# 下限 3.22：Qt 6.10.3 的 Qt6ConfigExtras.cmake 要求使用方至少 3.22（QT_SUPPORTED_MIN_CMAKE_VERSION_FOR_USING_QT），
# 再低 find_package(Qt6) 就会拒绝。上限 4.0：策略按本机实际验证过的 CMake 4.0.2 取新行为（062 A056）；
# 改动前后逐一对比了 Mac 全部编译/链接命令、测试登记和 iOS Xcode 工程。
cmake_minimum_required(VERSION 3.22...4.0)

project(PomodoroTodo VERSION 1.0.5 LANGUAGES CXX)

# 菜单栏与系统通知走 macOS 原生 API（NSStatusItem / UNUserNotificationCenter），
# 需要 Objective-C++ 编译能力。平台只有 macOS 与 iOS 两个：iOS 构建只产出应用本体，
# 菜单栏、全局热键、外部 AI 接入、测试与本机部署都只属于 macOS（见下方 if(IOS) 分支）。
enable_language(OBJCXX)
# 055-P3A：SwiftUI 只在 iOS 编译。Qt 函数保留定义时的策略，故须在 find_package 前设默认值。
# CMake 4.0.2 + Xcode 27 实测：CMP0142 OLD 会生成不存在的 Swift 库搜索路径副本。
# 版本范围升到 4.0 后这行仍不能删：062 实测去掉它，Qt 函数里的库搜索路径照旧变回 OLD 写法。
if(IOS)
    enable_language(Swift)
    set(CMAKE_POLICY_DEFAULT_CMP0142 NEW)
    # CMP0157（3.29）取新行为后，CMake 不再自动给非 Debug 配置开整模块优化（wholemodule），这里显式指定：
    # Debug 增量编译（Xcode 工程里与原来一样不写该属性），Release 等配置 wholemodule。原来只有应用目标被设上，
    # 现在 IPadCore、IPadUI 两个纯 Swift 库也一致。真机安装用 Debug，不受影响。
    set(CMAKE_Swift_COMPILATION_MODE "$<IF:$<CONFIG:Debug>,incremental,wholemodule>")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# 6.7 是 QDateTime::TransitionResolution 的引入版本（见 src/services/LogicalDay.h 的逻辑日边界计算）。
# 不写下界的话，用更低版本的 Qt 也能配置成功，报错要推迟到编译期才出现。
find_package(Qt6 6.7 REQUIRED COMPONENTS Concurrent Core Gui Network Qml Quick QuickControls2 QuickLayouts Sql)
# Shader编译是构建输入，缺少同SDK的qsb时直接失败，不能继续打包过期二进制。
find_package(Qt6 6.7 REQUIRED COMPONENTS ShaderTools)
# 备份取消使用自行创建的SQLite C API连接，不借用Qt主连接的native句柄。
find_package(SQLite3 REQUIRED)
if(APPLE AND SQLite3_INCLUDE_DIR MATCHES "[.]sdk/usr/include$")
    # Xcode27.1+CMake4.0.2实测：FindSQLite3把SDK的usr/include作为显式搜索路径后，
    # libc++的include_next绕过标准库包装头而编译失败。该头目录本就由sysroot隐式提供。
    set_property(TARGET SQLite::SQLite3 PROPERTY INTERFACE_INCLUDE_DIRECTORIES "")
endif()

# Mac主驱动与备份C API必须来自同一个SQLite运行实例；插件独立构建，不替换SDK。
if(APPLE AND NOT IOS)
    include(cmake/QtSqliteRuntime.cmake)
endif()

# 主应用和资源测试采用同一生成选项，保持原资源URL和跨图形后端集合。
function(pomodoro_todo_add_glass_shader target resource_name)
    qt_add_shaders(${target} ${resource_name}
        PREFIX "/shaders"
        BASE "${CMAKE_CURRENT_SOURCE_DIR}/shaders"
        GLSL "100 es,120,150"
        HLSL 50
        MSL 12
        FILES "${CMAKE_CURRENT_SOURCE_DIR}/shaders/liquid_glass.frag"
    )
endfunction()
if(NOT IOS)
    # 测试只在 macOS 上离屏运行；iOS 构建不注册任何测试，也就不要求 iOS 套件带测试模块。
    set(QT_NO_PRIVATE_MODULE_WARNING ON)
    find_package(Qt6 6.7 REQUIRED COMPONENTS GuiPrivate QuickTest Test)
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
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp src/services/SyncApplier.h src/services/SyncApplier.cpp
    src/services/SyncNotifier.h
    src/services/SyncNotifier.cpp
    src/services/SyncFiles.h
    src/services/SyncFiles.cpp
    src/services/SyncFolder.h
    src/services/LocalSyncFolder.h
    src/services/LocalSyncFolder.cpp
    src/services/SyncWorker.h
    src/services/SyncWorker.cpp
    src/services/SyncEngine.h
    src/services/SyncEngine.cpp
    src/services/SyncController.h
    src/services/SyncController.cpp
    src/services/SyncedSettings.h
    src/services/SyncedSettings.cpp
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
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/PhaseSoundService.h
    src/services/PhaseSoundService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    # 055-P4-4：统计页翻周期的纯函数（iPad 原生页经逻辑日桥接调用）。
    src/services/StatisticsPeriod.h src/services/StatisticsPeriod.cpp
    src/services/TrayController.h
    src/services/TrayController.cpp
    src/services/NotificationService.h
    src/services/NotificationService.cpp
    src/services/PhaseCompletionNotifier.h
    src/services/PhaseCompletionNotifier.cpp
    src/services/PhaseAlarmCoordinator.h
    src/services/PhaseAlarmCoordinator.cpp
    src/services/BackupOperationControl.h
    src/services/BackupSqliteDriver.h
    src/services/BackupSqliteDriver.cpp
    src/services/BackupOperations.h
    src/services/BackupOperations.cpp
    src/services/BackupExecutor.h
    src/services/BackupExecutor.cpp
    src/services/BackupExecutorProtocol.h
    src/services/BackupExecutorProtocol.cpp
    src/services/BackupService.h
    src/services/BackupService.cpp
    src/services/SnapshotRetention.h
    src/services/GlobalHotkeyBackend.h
    src/services/ShortcutRegistry.h
    src/services/ShortcutRegistry.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/MemoService.h
    src/services/MemoService.cpp
    src/services/TrashStore.h
    src/services/TrashStore.cpp
    src/services/TrashService.h
    src/services/TrashService.cpp
    src/services/TaskInteractionCoordinator.h
    src/services/TaskInteractionCoordinator.cpp
    src/services/PendingDeletion.h
    src/services/PendingDeletion.cpp
    src/services/FocusSessionController.h
    src/services/FocusSessionController.cpp
    src/services/QmlValues.h
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
)

if(NOT IOS)
    # 只在 macOS 存在的能力：单实例守卫（本地 socket 召回窗口）、外部 AI 接入的主应用侧、
    # 菜单栏、全局热键与偏好域清理。iOS 由系统保证单实例，
    # 也没有外部进程能连进来，这些源码整体不编入；main.cpp 里的装配用 Q_OS_MACOS 同步圈住。
    list(APPEND APP_SOURCES
        src/entry/mac/main.cpp
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
        src/platform/macos/MacGlobalHotkeyBackend.h
        src/platform/macos/MacGlobalHotkeyBackend.mm
        src/platform/macos/MacPreferencesCleanup.h
        src/platform/macos/MacPreferencesCleanup.mm
        # 设备间同步：Mac 经文件协调读写 iCloud 云盘里的同步文件夹（协调实现在 src/platform/apple）。
        src/platform/macos/MacSyncFolder.h
        src/platform/macos/MacSyncFolder.cpp
        src/platform/macos/MacBackupExecutor.h
        src/platform/macos/MacBackupExecutor.cpp
        src/platform/macos/MacExitWatchdog.h
        src/platform/macos/MacExitWatchdog.cpp
    )

    set(APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/resources/app-icons/PomodoroTodo.icns")
    set_source_files_properties("${APP_ICON}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources"
    )
    list(APPEND APP_SOURCES "${APP_ICON}")
endif()

# macOS 与 iOS 共用的 Apple 框架实现放在 src/platform/apple：UserNotifications 在两个平台上
# 是同一套接口，系统通知后端只写一份。它的 ObjC++ 部分用 ARC 管理 Cocoa 对象的生命周期。
list(APPEND APP_SOURCES
    src/platform/apple/AppleNotificationBackend.h
    src/platform/apple/AppleNotificationBackend.mm
    # iCloud 云盘里单个文件的上传状态（同步时提示「iCloud 空间已满」这类问题），两个平台同一套接口。
    src/platform/apple/AppleUbiquitousItem.h
    src/platform/apple/AppleUbiquitousItem.mm
    src/platform/apple/AppleCoordinatedFiles.h
    src/platform/apple/AppleCoordinatedFiles.mm
)
set_source_files_properties(
    src/platform/apple/AppleNotificationBackend.mm
    src/platform/apple/AppleUbiquitousItem.mm
    src/platform/apple/AppleCoordinatedFiles.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
)

if(IOS)
    # iPad 的同步文件夹：用「文件」选择器选中的 iCloud 云盘文件夹（安全作用域书签 + 文件协调），
    # 以及切到后台时向系统要时间把改动写完。
    list(APPEND APP_SOURCES
        src/entry/ios/main.cpp
        src/entry/ios/UiRouter.h
        src/entry/ios/UiRouter.cpp
        src/platform/ios/IosSyncFolder.h
        src/platform/ios/IosSyncFolder.mm
        src/platform/ios/IosFolderPicker.h
        src/platform/ios/IosFolderPicker.mm
        src/platform/ios/IosBackgroundTask.h
        src/platform/ios/IosBackgroundTask.mm
        # 055-P3A：挂载与生命周期只在 iOS 装配。
        src/platform/ios/native/IPadUiPreferences.h
        src/platform/ios/native/IPadShellPreferences.h
        src/platform/ios/native/IPadShellPreferences.cpp
        src/platform/ios/native/NativeRoot.h
        src/platform/ios/native/NativeRoot.mm
        src/platform/ios/bridge/PTLifecycleBridge.h
        src/platform/ios/bridge/PTLifecycleBridge.mm
        src/platform/ios/bridge/PTShellBridge.h
        src/platform/ios/bridge/PTShellBridge.mm
        src/platform/ios/bridge/PTTaskBridge.h src/platform/ios/bridge/PTTaskBridge.mm
        src/platform/ios/bridge/PTPendingDeletionBridge.h src/platform/ios/bridge/PTPendingDeletionBridge.mm
        src/platform/ios/bridge/PTInteractionBridge.h src/platform/ios/bridge/PTInteractionBridge.mm
        src/platform/ios/bridge/PTCategoryBridge.h src/platform/ios/bridge/PTCategoryBridge.mm
        src/platform/ios/bridge/PTLogicalDayBridge.h src/platform/ios/bridge/PTLogicalDayBridge.mm
        src/platform/ios/bridge/PTSettingsBridge.h src/platform/ios/bridge/PTSettingsBridge.mm
        src/platform/ios/bridge/PTStatisticsBridge.h src/platform/ios/bridge/PTStatisticsBridge.mm
        src/platform/ios/bridge/PTFocusHistoryBridge.h src/platform/ios/bridge/PTFocusHistoryBridge.mm
        # 055-P3B：转换与非单例服务登记。
        src/platform/ios/bridge/PTBridgeSupport.h
        src/platform/ios/bridge/PTBridgeSupport.mm
        # 055-P4-1：专注与今日知识缺口提醒桥接。
        src/platform/ios/bridge/PTFocusBridge.h src/platform/ios/bridge/PTFocusBridge.mm
        src/platform/ios/bridge/PTGapReminderBridge.h src/platform/ios/bridge/PTGapReminderBridge.mm
        # 055-P4-5：废纸篓与设置的数据桥接。
        src/platform/ios/bridge/PTTrashBridge.h src/platform/ios/bridge/PTTrashBridge.mm
        src/platform/ios/bridge/PTSyncBridge.h src/platform/ios/bridge/PTSyncBridge.mm
        src/platform/ios/bridge/PTBackupBridge.h src/platform/ios/bridge/PTBackupBridge.mm
        src/platform/ios/bridge/PTExportBridge.h src/platform/ios/bridge/PTExportBridge.mm
        src/platform/ios/bridge/PTRoutineBridge.h src/platform/ios/bridge/PTRoutineBridge.mm
    )
    set_source_files_properties(
        src/platform/ios/IosSyncFolder.mm
        src/platform/ios/IosFolderPicker.mm
        src/platform/ios/IosBackgroundTask.mm
        src/platform/ios/native/NativeRoot.mm
        src/platform/ios/bridge/PTLifecycleBridge.mm
        src/platform/ios/bridge/PTShellBridge.mm
        src/platform/ios/bridge/PTTaskBridge.mm
        src/platform/ios/bridge/PTPendingDeletionBridge.mm
        src/platform/ios/bridge/PTInteractionBridge.mm
        src/platform/ios/bridge/PTCategoryBridge.mm
        src/platform/ios/bridge/PTLogicalDayBridge.mm
        src/platform/ios/bridge/PTSettingsBridge.mm
        src/platform/ios/bridge/PTStatisticsBridge.mm
        src/platform/ios/bridge/PTFocusHistoryBridge.mm
        # 055-P3B：支撑层使用 Foundation，按 ARC 管理对象。
        src/platform/ios/bridge/PTBridgeSupport.mm
        # 055-P4-1：桥接仅使用 Foundation，ARC 管理回调生命周期。
        src/platform/ios/bridge/PTFocusBridge.mm src/platform/ios/bridge/PTGapReminderBridge.mm
        src/platform/ios/bridge/PTTrashBridge.mm
        src/platform/ios/bridge/PTSyncBridge.mm
        src/platform/ios/bridge/PTBackupBridge.mm
        src/platform/ios/bridge/PTExportBridge.mm
        src/platform/ios/bridge/PTRoutineBridge.mm
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

# 菜单栏的 ObjC++ 后端用 ARC 管理 Cocoa 对象生命周期（通知后端在上方共用清单里设置）。
# 全局热键后端只调 Carbon 的 C 接口、不持有 ObjC 对象，一并开 ARC 保持编译选项一致。
if(NOT IOS)
    set_source_files_properties(
        src/platform/macos/MacStatusBarController.mm
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
        # 文件选择器、后台任务与选择器里的「文件夹」类型。
        "-framework UIKit"
        "-framework UniformTypeIdentifiers"
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

# 普通构建只产出应用包；日常部署目录显式传 ON，避免新构建目录覆盖正式安装。
option(POMODORO_TODO_DEPLOY_LOCAL "构建后自动把应用同步到本机固定启动入口" OFF)

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
            "-DBACKUP_EXECUTOR=PomodoroTodoBackupExecutor"
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
        # CMake 4.0.2 + Xcode 27 会把无语言限制的选项写进 OTHER_SWIFT_FLAGS；Swift 不接受 -Wall。
        target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-Wall;-Wextra>")
        # 64 位转 32 位的截断告警：iOS 用 Xcode 生成器，默认就开着它；Mac 这边不开的话，
        # 这类告警只在编 iOS 时冒出来，平时看不到也就没人修（2026-10 攒到过 6 条）。只有 Clang 认这个选项。
        if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
            target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-Wshorten-64-to-32>")
        endif()
    endif()
endfunction()

# 057-A：业务与同步层的静态库。源文件仍留在原目录，避免改变 include 路径和资源布局；
# PlainTextLayout 属于 QML 接入层，SingleInstanceGuard 属于 macOS 入口，两个例外留在原目标。
set(PTCORE_SOURCES ${APP_SOURCES})
list(FILTER PTCORE_SOURCES INCLUDE REGEX "^src/(services|models)/")
list(FILTER PTCORE_SOURCES EXCLUDE REGEX "^src/services/SingleInstanceGuard\\.")
list(FILTER PTCORE_SOURCES EXCLUDE REGEX "^src/models/PlainTextLayout\\.")
list(APPEND PTCORE_SOURCES
    src/models/Task.h
    src/models/CountdownGoal.h
    src/models/FocusSession.h
    src/services/ServiceReadResult.h
)
list(REMOVE_DUPLICATES PTCORE_SOURCES)

add_library(PTCore STATIC ${PTCORE_SOURCES})
target_include_directories(PTCore PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(PTCore PRIVATE SQLite::SQLite3)
target_link_libraries(PTCore PUBLIC
    Qt6::Core
    Qt6::Gui
    Qt6::Sql
    Qt6::Concurrent
)
pomodoro_todo_enable_warnings(PTCore)

# 057-B：跨平台共享装配与生命周期库 PTApp。
set(PTAPP_SOURCES
    src/app/SharedApp.h
    src/app/SharedApp.cpp
    src/app/AppLifecycle.h
    src/app/AppLifecycle.cpp
    src/app/AppServices.h
    src/app/AppServices.cpp
)
add_library(PTApp STATIC ${PTAPP_SOURCES})
target_include_directories(PTApp PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(PTApp PUBLIC PTCore)
pomodoro_todo_enable_warnings(PTApp)

# 057-C：跨平台 QML 门面与文字排版库 PTQml。
set(PTQML_SOURCES
    src/qmlfacade/QmlFacade.h
    src/qmlfacade/QmlFacade.cpp
    src/models/PlainTextLayout.h
    src/models/PlainTextLayout.cpp
)
add_library(PTQml STATIC ${PTQML_SOURCES})
target_include_directories(PTQml PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(PTQml PUBLIC
    PTApp
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
)
pomodoro_todo_enable_warnings(PTQml)

# PomodoroTodo 继续保留入口、平台后端、资源和 macOS 专属源码；业务实现由 PTCore 提供，装配由 PTApp 提供，QML 门面由 PTQml 提供。
get_target_property(POMODORO_TODO_TARGET_SOURCES PomodoroTodo SOURCES)
foreach(ptcore_source IN LISTS PTCORE_SOURCES)
    list(REMOVE_ITEM POMODORO_TODO_TARGET_SOURCES
        "${ptcore_source}"
        "${CMAKE_CURRENT_SOURCE_DIR}/${ptcore_source}")
endforeach()
foreach(ptqml_source IN LISTS PTQML_SOURCES)
    list(REMOVE_ITEM POMODORO_TODO_TARGET_SOURCES
        "${ptqml_source}"
        "${CMAKE_CURRENT_SOURCE_DIR}/${ptqml_source}")
endforeach()
set_property(TARGET PomodoroTodo PROPERTY SOURCES "${POMODORO_TODO_TARGET_SOURCES}")
list(REMOVE_ITEM APP_SOURCES ${PTCORE_SOURCES})
list(REMOVE_ITEM APP_SOURCES ${PTQML_SOURCES})
target_link_libraries(PomodoroTodo PRIVATE PTQml PTApp PTCore)
pomodoro_todo_add_glass_shader(PomodoroTodo app_glass_shader)

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

    # 055-P3A：数据层与界面层使用与 SwiftPM 一致的独立模块，不链接 Qt。
    add_library(IPadCore STATIC
        src/ui/ipad/Sources/IPadCore/ShellNavigation.swift
        src/ui/ipad/Sources/IPadCore/ShellStore.swift)
    add_library(IPadUI STATIC
        src/ui/ipad/Sources/IPadUI/NativeRoot.swift
        src/ui/ipad/Sources/IPadUI/Shell/ShellBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Shell/PageRegistry.swift
        src/ui/ipad/Sources/IPadUI/Shell/ShellRootView.swift
        src/ui/ipad/Sources/IPadUI/Theme/ThemeColors.swift
        src/ui/ipad/Sources/IPadUI/Theme/WallpaperBackground.swift
        src/ui/ipad/Sources/IPadUI/Components/MarkedTextEditor.swift)
    # 055-P3B：跨页任务动作与撤销提示状态。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/PendingDeletionStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/TaskActions.swift)
    # 055-P3B：领域协议与适配器按层登记，页面仍保留占位。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Bridging/TaskBridge.swift
        src/ui/ipad/Sources/IPadCore/Bridging/PendingDeletionBridge.swift
        src/ui/ipad/Sources/IPadCore/Bridging/InteractionBridge.swift
)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Bridges/TaskBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/PendingDeletionBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/InteractionBridgeAdapter.swift
)
    # 055-P3B：科目、逻辑日与设置协议和适配器。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Bridging/CategoryBridge.swift
        src/ui/ipad/Sources/IPadCore/Bridging/LogicalDayBridge.swift
        src/ui/ipad/Sources/IPadCore/Bridging/SettingsBridge.swift
    )
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Bridges/CategoryBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/LogicalDayBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/SettingsBridgeAdapter.swift
    )
    # 055-P3B：统计与专注历史协议及适配器。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Bridging/StatisticsBridge.swift
        src/ui/ipad/Sources/IPadCore/Bridging/FocusHistoryBridge.swift
        src/ui/ipad/Sources/IPadCore/Bridging/CoreBridges.swift
    )
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Bridges/StatisticsBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/FocusHistoryBridgeAdapter.swift
    )
    # 055-P4-2：课表数据桥接与 Swift 类型、适配器，追加在现有清单末尾.
    target_sources(PomodoroTodo PRIVATE
        src/platform/ios/bridge/PTScheduleBridge.h src/platform/ios/bridge/PTScheduleBridge.mm)
    set_source_files_properties(src/platform/ios/bridge/PTScheduleBridge.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Bridging/ScheduleBridging.swift
        src/ui/ipad/Sources/IPadCore/Stores/ScheduleStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/TimelineStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/WeekStore.swift
        src/ui/ipad/Sources/IPadCore/Format/LogicalDateNavigation.swift
        src/ui/ipad/Sources/IPadCore/Format/TimelineLayout.swift
        src/ui/ipad/Sources/IPadCore/Format/ScheduleFormat.swift
        src/ui/ipad/Sources/IPadCore/Format/ScheduleLayout.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Bridges/ScheduleBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Pages/Schedule/ScheduleView.swift
        src/ui/ipad/Sources/IPadUI/Pages/Schedule/WeekGrid.swift
        src/ui/ipad/Sources/IPadUI/Pages/Schedule/ScheduleEntrySheet.swift
        src/ui/ipad/Sources/IPadUI/Pages/Schedule/ScheduleSettingsSheet.swift
        src/ui/ipad/Sources/IPadUI/Pages/TodayFocusView.swift
        src/ui/ipad/Sources/IPadUI/Pages/SessionEditorSheet.swift
        src/ui/ipad/Sources/IPadUI/Pages/WeekView.swift)
    # 055-P4-5：废纸篓与设置的协议、Store 和页面。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Bridging/TrashBridging.swift
        src/ui/ipad/Sources/IPadCore/Bridging/SyncBridging.swift
        src/ui/ipad/Sources/IPadCore/Bridging/BackupBridging.swift
        src/ui/ipad/Sources/IPadCore/Bridging/ExportBridging.swift
        src/ui/ipad/Sources/IPadCore/Bridging/RoutineBridging.swift
        src/ui/ipad/Sources/IPadCore/Stores/TrashStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/SettingsStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/SettingsAvailability.swift
        src/ui/ipad/Sources/IPadCore/Stores/SettingsManagementStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/FileTransferWorkspace.swift
        src/ui/ipad/Sources/IPadCore/Stores/SettingsBackupStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/SettingsExportStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/SettingsSyncStore.swift
        src/ui/ipad/Sources/IPadCore/Format/RoutineWeekdaysFormat.swift
        src/ui/ipad/Sources/IPadCore/Format/TrashFormat.swift
    )
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Bridges/TrashBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/SyncBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/BackupBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/ExportBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/RoutineBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Pages/Trash/TrashPage.swift
        src/ui/ipad/Sources/IPadUI/Pages/Settings/SettingsPage.swift
        src/ui/ipad/Sources/IPadUI/Pages/Settings/SettingsManagementViews.swift
        src/ui/ipad/Sources/IPadUI/Pages/Settings/SettingsTransferViews.swift
    )
    # 055-P4-1：专注与缺口提醒的协议及适配器。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Bridging/FocusBridging.swift
        src/ui/ipad/Sources/IPadCore/Bridging/GapReminderBridging.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Bridges/FocusBridgeAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/GapReminderBridgeAdapter.swift)
    # 055-P4-1：提前合并点 A 的共用任务表单、行与显示格式。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/TaskEditorStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/TaskCategoryStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/TaskCompletionNoteStore.swift
        # 10-12 对齐提醒事项：任务行的行内编辑（各页共用一份）。
        src/ui/ipad/Sources/IPadCore/Stores/InlineTaskEditor.swift
        src/ui/ipad/Sources/IPadCore/Format/Duration.swift
        src/ui/ipad/Sources/IPadCore/Format/DashboardFormat.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Components/Task/TaskRow.swift
        src/ui/ipad/Sources/IPadUI/Components/Task/TaskCategoryPicker.swift
        src/ui/ipad/Sources/IPadUI/Components/Task/TaskDetailSheet.swift
        src/ui/ipad/Sources/IPadUI/Components/Task/TaskCompletionNoteSheet.swift)
    # 055-P4-1 步骤 4–5：专注计时与仪表盘。
    target_sources(IPadCore PRIVATE src/ui/ipad/Sources/IPadCore/Stores/FocusStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/DashboardStore.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Pages/Focus/FocusView.swift
        src/ui/ipad/Sources/IPadUI/Pages/Focus/FocusClockText.swift
        src/ui/ipad/Sources/IPadUI/Pages/Focus/FocusRingView.swift
        src/ui/ipad/Sources/IPadUI/Pages/Focus/FocusSheets.swift
        src/ui/ipad/Sources/IPadUI/Pages/Focus/FocusImmersiveView.swift
        src/ui/ipad/Sources/IPadUI/Pages/Dashboard/DashboardView.swift)
    # 055-P4-1 步骤 3：今日任务（Store 与页面）。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/TodayStore.swift
        src/ui/ipad/Sources/IPadCore/Stores/TodayToolsStore.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Pages/Today/TodayView.swift
        src/ui/ipad/Sources/IPadUI/Pages/Today/TodayBanners.swift
        src/ui/ipad/Sources/IPadUI/Pages/Today/TodaySheets.swift
        src/ui/ipad/Sources/IPadUI/Pages/Today/TodayToolsSheet.swift)
    # 055-P4-3：内容桥接与协议、适配器。
    target_sources(PomodoroTodo PRIVATE
        src/platform/ios/bridge/PTKnowledgeGapBridge.h src/platform/ios/bridge/PTKnowledgeGapBridge.mm
        src/platform/ios/bridge/PTMemoBridge.h src/platform/ios/bridge/PTMemoBridge.mm
        src/platform/ios/bridge/PTCountdownBridge.h src/platform/ios/bridge/PTCountdownBridge.mm
    )
    set_source_files_properties(
        src/platform/ios/bridge/PTKnowledgeGapBridge.mm
        src/platform/ios/bridge/PTMemoBridge.mm
        src/platform/ios/bridge/PTCountdownBridge.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    # 055-P4-3：Swift 内容协议与适配器分层登记。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Bridging/KnowledgeGapBridging.swift
        src/ui/ipad/Sources/IPadCore/Bridging/MemoBridging.swift
        src/ui/ipad/Sources/IPadCore/Bridging/CountdownBridging.swift
    )
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Bridges/KnowledgeGapAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/MemoAdapter.swift
        src/ui/ipad/Sources/IPadUI/Bridges/CountdownAdapter.swift
    )
    # 055-P4-3：知识缺口列表、详情与展示 Store。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/GapStore.swift
        src/ui/ipad/Sources/IPadCore/Format/GapFormat.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Pages/KnowledgeGap/KnowledgeGapPage.swift)
    # 055-P4-3：备忘录编辑会话和组合保护标题，正文复用 P3A 编辑器。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/MemoStore.swift
        src/ui/ipad/Sources/IPadCore/Format/MemoFormat.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Pages/Memo/MemoPage.swift
        src/ui/ipad/Sources/IPadUI/Pages/Memo/MemoTitleEditor.swift)
    # 055-P4-3：主目标、系统列表和倒计时表单。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/CountdownStore.swift
        src/ui/ipad/Sources/IPadCore/Format/CountdownFormat.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Pages/Countdown/CountdownPage.swift)
    # 055-P4-3：两种表单共用 ISO 日期投影，不共享领域 Store 或业务判断。
    target_sources(IPadCore PRIVATE src/ui/ipad/Sources/IPadCore/Format/ContentDateFormat.swift)

    # 055-P4-4：原生专注历史数据层、格式与月历，不改 Mac 的 QML 路径。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/HistoryStore.swift
        src/ui/ipad/Sources/IPadCore/Format/MonthGoalFormat.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Pages/History/HistoryView.swift
        src/ui/ipad/Sources/IPadUI/Pages/History/MonthGrid.swift)

    # 055-P4-4：原生数据统计、系统图表与周复盘。
    target_sources(IPadCore PRIVATE
        src/ui/ipad/Sources/IPadCore/Stores/StatsStore.swift
        src/ui/ipad/Sources/IPadCore/Format/StatisticsFormat.swift)
    target_sources(IPadUI PRIVATE
        src/ui/ipad/Sources/IPadUI/Pages/Statistics/StatisticsView.swift
        src/ui/ipad/Sources/IPadUI/Pages/Statistics/StatisticsCharts.swift
        src/ui/ipad/Sources/IPadUI/Pages/Statistics/WeeklyReviewCard.swift)

    foreach(swift_target IN ITEMS IPadCore IPadUI)
        # 纯 Swift 目标关闭 Qt 的自动生成，否则空的 moc 编译单元会触发 libtool 告警。
        # Xcode 下用 SWIFT_VERSION，Swift_LANGUAGE_VERSION 会与工程默认的 4.0 冲突。
        set_target_properties(${swift_target} PROPERTIES
            AUTOMOC OFF AUTORCC OFF
            XCODE_ATTRIBUTE_SWIFT_VERSION "6.0"
            XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "26.0")
    endforeach()
    set_target_properties(IPadUI PROPERTIES
        XCODE_ATTRIBUTE_SWIFT_INCLUDE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}/src/platform/ios/bridge")
    # 055-R1：原生窗口的系统/主题颜色环境，不进入 Mac 或 iPhone QML。
    target_sources(IPadUI PRIVATE src/ui/ipad/Sources/IPadUI/Theme/ThemeAppearance.swift)
    # 055-R4：调试巡检，只有带 --ipad-ui-tour 启动参数时截图。
    target_sources(IPadUI PRIVATE src/ui/ipad/Sources/IPadUI/Shell/UITour.swift)
    # 10-12：调试测速，只有带 --ipad-ui-tour-perf 启动参数时记录主线程占用。
    target_sources(IPadUI PRIVATE src/ui/ipad/Sources/IPadUI/Shell/UIPerfProbe.swift)
    # 055-R4：按定稿 CSS 的公共样式（卡片、胶囊、页头、数字混排）。
    target_sources(IPadUI PRIVATE src/ui/ipad/Sources/IPadUI/Components/DesignKit.swift)
    # 055-R4：定稿侧栏顶部的搜索（任务与知识缺口都走服务现成搜索）。
    target_sources(IPadCore PRIVATE src/ui/ipad/Sources/IPadCore/Stores/SearchStore.swift)
    target_sources(IPadUI PRIVATE src/ui/ipad/Sources/IPadUI/Pages/Search/SearchPage.swift)
    target_link_libraries(IPadUI PRIVATE IPadCore)
    # 055-P3A：颜色资源属于应用包，Swift 按 Bundle.main 获取；壁纸继续只用 Qt 已打包的资源。
    target_sources(PomodoroTodo PRIVATE src/ui/ipad/Sources/IPadUI/Resources/Colors.xcassets)
    set_source_files_properties(src/ui/ipad/Sources/IPadUI/Resources/Colors.xcassets
        PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    target_link_libraries(PomodoroTodo PRIVATE IPadUI)
    set_target_properties(PomodoroTodo PROPERTIES
        XCODE_ATTRIBUTE_SWIFT_VERSION "6.0"
        XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "26.0")

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

if(APPLE)
    # 文件执行器链接核心业务库，只提供 stdio 文件协议，不加载 QML 或主应用偏好域。
    qt_add_executable(PomodoroTodoBackupExecutor src/entry/mac/backup-executor/main.cpp)
    target_compile_definitions(PomodoroTodoBackupExecutor PRIVATE
        POMODORO_TODO_VERSION="${PROJECT_VERSION}")
    target_link_libraries(PomodoroTodoBackupExecutor PRIVATE PTCore)
    pomodoro_todo_enable_warnings(PomodoroTodoBackupExecutor)
    add_dependencies(PomodoroTodo PomodoroTodoBackupExecutor)
    add_custom_target(bundle-backup-executor ALL
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:PomodoroTodoBackupExecutor>"
            "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/MacOS/PomodoroTodoBackupExecutor"
        DEPENDS PomodoroTodo PomodoroTodoBackupExecutor VERBATIM)
    if(TARGET deploy-local-app)
        add_dependencies(deploy-local-app bundle-backup-executor)
    endif()
endif()

include(cmake/PomodoroTodoTests.cmake)

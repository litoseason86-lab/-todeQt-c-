cmake_minimum_required(VERSION 3.16)

project(PomodoroTodo VERSION 0.1.0 LANGUAGES CXX)

# 菜单栏与系统通知走 macOS 原生 API（NSStatusItem / UNUserNotificationCenter），
# 需要 Objective-C++ 编译能力。平台只有 macOS 与 iOS 两个：iOS 构建只产出应用本体，
# 菜单栏、全局热键、外部 AI 接入、测试与本机部署都只属于 macOS（见下方 if(IOS) 分支）。
enable_language(OBJCXX)
# 055-P3A：SwiftUI 只在 iOS 编译。Qt 函数保留定义时的策略，故须在 find_package 前设默认值。
# CMake 4.0.2 + Xcode 27 实测：CMP0142 OLD 会生成不存在的 Swift 库搜索路径副本。
if(IOS)
    enable_language(Swift)
    set(CMAKE_POLICY_DEFAULT_CMP0142 NEW)
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
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp
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


enable_testing()

# 架构门禁与原生偏好测试的退出后清理均依赖 Python；iOS 已在上方返回。
find_package(Python3 COMPONENTS Interpreter REQUIRED)

function(pomodoro_todo_add_native_preferences_test target)
    add_test(NAME ${target}
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/run_native_preferences_test.py"
            "$<TARGET_FILE:${target}>")
endfunction()

add_executable(PomodoroTodoTests
    tests/ServiceTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
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
pomodoro_todo_add_native_preferences_test(PomodoroTodoTests)

add_executable(CoreLogicTests
    tests/CoreLogicTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
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
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
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
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
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
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    src/services/TrashStore.h src/services/TrashStore.cpp
)

target_link_libraries(KnowledgeGapServiceTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(KnowledgeGapServiceTests)
pomodoro_todo_add_native_preferences_test(KnowledgeGapServiceTests)

# 备忘录只依赖数据库，不引入任务或计时服务，保证纯文本记录不影响专注统计。
add_executable(MemoServiceTests
    tests/MemoServiceTests.cpp
    src/services/DatabaseManager.h src/services/DatabaseManager.cpp
    src/services/SyncSchema.h src/services/SyncSchema.cpp
    src/services/MemoService.h src/services/MemoService.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
)
target_link_libraries(MemoServiceTests PRIVATE Qt6::Core Qt6::Sql Qt6::Test)
pomodoro_todo_enable_warnings(MemoServiceTests)
add_test(NAME MemoServiceTests COMMAND MemoServiceTests)
set_tests_properties(MemoServiceTests PROPERTIES TIMEOUT 90)

# 课表：只验证存储与「按周次筛选」两件事。日期到周次的换算不在这里——
# 它在 QML 侧的 ScheduleWeeks.js，由 QML 测试覆盖。
# 不引入 TaskManager/FocusTimer：课表项与任务、专注记录之间没有任何写入关系，
# 把它们连进来只会让「课表不影响统计」这条不变量变得难以断言。
add_executable(ScheduleServiceTests
    tests/ScheduleServiceTests.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    # AppSettings 只为一条用例引入：它把「学期总周数上限」与
    # ScheduleService::kMaxWeekIndex 钉死在一起，两处常量不能各改各的。
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
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
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    src/services/TrashStore.h src/services/TrashStore.cpp
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
add_executable(AppleNotificationBackendTests
    tests/AppleNotificationBackendTests.cpp
    src/services/NotificationService.h
    src/services/NotificationService.cpp
    src/platform/apple/AppleNotificationBackend.h
    src/platform/apple/AppleNotificationBackend.mm
)

target_link_libraries(AppleNotificationBackendTests PRIVATE
    Qt6::Core
    Qt6::Test
    "-framework Foundation"
    "-framework UserNotifications"
)

pomodoro_todo_enable_warnings(AppleNotificationBackendTests)
add_test(NAME AppleNotificationBackendTests COMMAND AppleNotificationBackendTests)

# 偏好清理直接读写 CoreFoundation 偏好：用例只写专用测试偏好域，系统全局域只读不写。
# 启动脚本在进程退出后删除文件，避免偏好守护进程在退出阶段重新写回空 plist。
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
pomodoro_todo_add_native_preferences_test(MacPreferencesCleanupTests)

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
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    src/services/TrashStore.h src/services/TrashStore.cpp
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
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    src/services/TrashStore.h src/services/TrashStore.cpp
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
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
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
    src/services/PhaseCompletionNotifier.h
    src/services/PhaseCompletionNotifier.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
)

target_link_libraries(PhaseAlarmCoordinatorTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(PhaseAlarmCoordinatorTests)
add_test(NAME PhaseAlarmCoordinatorTests COMMAND PhaseAlarmCoordinatorTests)

# 设备间同步（050）：v18 结构与触发器、两台设备各用一个临时库的合并场景。
# 用真实的建表逻辑（DatabaseManager），不手写简化表：简化表会漏掉真实约束。
add_executable(SyncTests
    tests/SyncTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp
    src/services/SyncNotifier.h
    src/services/SyncNotifier.cpp
    src/services/SyncedSettings.h
    src/services/SyncedSettings.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/FocusSessionRules.h
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/MemoService.h
    src/services/MemoService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    # 跨设备用例要在设备上调用 TrashService（读列表、恢复、彻底删除、清空、清理过期项）。
    src/services/TrashStore.h src/services/TrashStore.cpp
    src/services/TrashService.h src/services/TrashService.cpp
)

target_link_libraries(SyncTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(SyncTests)
add_test(NAME SyncTests COMMAND SyncTests)

# 废纸篓（054 阶段 1）：放进、恢复、清理、迁移与备份契约。源文件以 SyncTests 为基础，
# 因为恢复会走 SyncNotifier 的按表发信号，连带各服务；仍用真实建表逻辑，不手写简化表。
add_executable(TrashServiceTests
    tests/TrashServiceTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp
    src/services/SyncNotifier.h
    src/services/SyncNotifier.cpp
    src/services/SyncedSettings.h
    src/services/SyncedSettings.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/FocusSessionRules.h
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/MemoService.h
    src/services/MemoService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/TrashStore.h
    src/services/TrashStore.cpp
    src/services/TrashService.h
    src/services/TrashService.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
)
target_link_libraries(TrashServiceTests PRIVATE Qt6::Core Qt6::Sql Qt6::Test)
pomodoro_todo_enable_warnings(TrashServiceTests)
pomodoro_todo_add_native_preferences_test(TrashServiceTests)
set_tests_properties(TrashServiceTests PROPERTIES TIMEOUT 90)

# 单槽撤销删除（055 阶段 2）：计时提交、撤销、提前提交、被别处删掉时退场、失败回报。
# 删除走真实的 TaskManager / FocusHistoryService 和真实建表逻辑的临时库，源文件清单照 TrashServiceTests。
add_executable(PendingDeletionTests
    tests/PendingDeletionTests.cpp
    src/services/PendingDeletion.h
    src/services/PendingDeletion.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp
    src/services/SyncNotifier.h
    src/services/SyncNotifier.cpp
    src/services/SyncedSettings.h
    src/services/SyncedSettings.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/FocusSessionRules.h
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/MemoService.h
    src/services/MemoService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/TrashStore.h
    src/services/TrashStore.cpp
    src/services/TrashService.h
    src/services/TrashService.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
)
target_link_libraries(PendingDeletionTests PRIVATE Qt6::Core Qt6::Sql Qt6::Test)
pomodoro_todo_enable_warnings(PendingDeletionTests)
add_test(NAME PendingDeletionTests COMMAND PendingDeletionTests)
set_tests_properties(PendingDeletionTests PROPERTIES TIMEOUT 90)

# 055-P2A：专注计时控制器的业务规则（结束同口径、超长自由专注确认与修正）。
# 用真实的 FocusTimer（注入假时钟）和临时库，源文件清单照 PendingDeletionTests。
add_executable(FocusSessionControllerTests
    tests/FocusSessionControllerTests.cpp
    src/services/FocusSessionController.h
    src/services/FocusSessionController.cpp
    src/services/PendingDeletion.h
    src/services/PendingDeletion.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp
    src/services/SyncNotifier.h
    src/services/SyncNotifier.cpp
    src/services/SyncedSettings.h
    src/services/SyncedSettings.cpp
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/FocusSessionRules.h
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/MemoService.h
    src/services/MemoService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/services/TrashStore.h
    src/services/TrashStore.cpp
    src/services/TrashService.h
    src/services/TrashService.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
)
target_link_libraries(FocusSessionControllerTests PRIVATE Qt6::Core Qt6::Sql Qt6::Test)
pomodoro_todo_enable_warnings(FocusSessionControllerTests)
add_test(NAME FocusSessionControllerTests COMMAND FocusSessionControllerTests)
set_tests_properties(FocusSessionControllerTests PROPERTIES TIMEOUT 90)

# 055-P3A：数据桥接仅依赖 Foundation 与 Qt，可在 macOS 测类型转换和信号生命周期。
get_target_property(PT_SHELL_TEST_SOURCES TrashServiceTests SOURCES)
list(REMOVE_ITEM PT_SHELL_TEST_SOURCES tests/TrashServiceTests.cpp)
add_executable(PTShellBridgeTests ${PT_SHELL_TEST_SOURCES}
    resources/wallpapers.qrc
    tests/PTShellBridgeTests.mm
    src/platform/ios/bridge/PTBridgeSupport.h src/platform/ios/bridge/PTBridgeSupport.mm
    src/platform/ios/bridge/PTTaskBridge.h src/platform/ios/bridge/PTTaskBridge.mm
    src/platform/ios/native/IPadUiPreferences.h
    src/platform/ios/native/IPadShellPreferences.h
    src/platform/ios/native/IPadShellPreferences.cpp
    src/platform/ios/bridge/PTShellBridge.h src/platform/ios/bridge/PTShellBridge.mm
    src/platform/ios/bridge/PTLifecycleBridge.h src/platform/ios/bridge/PTLifecycleBridge.mm
    src/services/StatisticsService.h src/services/StatisticsService.cpp
    src/services/BackupService.h src/services/BackupService.cpp
    src/services/BackupOperations.h src/services/BackupOperations.cpp
    src/services/LogicalDayService.h src/services/LogicalDayService.cpp)
set_source_files_properties(tests/PTShellBridgeTests.mm
    src/platform/ios/bridge/PTShellBridge.mm src/platform/ios/bridge/PTLifecycleBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(PTShellBridgeTests PRIVATE Qt6::Core Qt6::Gui Qt6::Sql Qt6::Concurrent Qt6::Test "-framework Foundation")
pomodoro_todo_enable_warnings(PTShellBridgeTests)
add_test(NAME PTShellBridgeTests COMMAND PTShellBridgeTests)
set_tests_properties(PTShellBridgeTests PROPERTIES TIMEOUT 90
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 055-P3B：核心数据桥接在 Mac 测试，源文件沿用废纸篓测试的服务装配。
get_target_property(PT_CORE_TEST_SOURCES TrashServiceTests SOURCES)
list(REMOVE_ITEM PT_CORE_TEST_SOURCES tests/TrashServiceTests.cpp)
add_executable(PTCoreBridgeTests ${PT_CORE_TEST_SOURCES}
    tests/PTCoreBridgeTests.mm
    src/platform/ios/bridge/PTBridgeSupport.h src/platform/ios/bridge/PTBridgeSupport.mm
    src/services/PendingDeletion.h src/services/PendingDeletion.cpp
    src/services/TaskInteractionCoordinator.h src/services/TaskInteractionCoordinator.cpp)
set_source_files_properties(tests/PTCoreBridgeTests.mm src/platform/ios/bridge/PTBridgeSupport.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(PTCoreBridgeTests PRIVATE Qt6::Core Qt6::Gui Qt6::Sql Qt6::Concurrent Qt6::Test "-framework Foundation")
pomodoro_todo_enable_warnings(PTCoreBridgeTests)
add_test(NAME PTCoreBridgeTests COMMAND PTCoreBridgeTests)
set_tests_properties(PTCoreBridgeTests PROPERTIES TIMEOUT 90
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 055-P3B：任务、撤销删除与交互令牌接入同一个测试目标。
target_sources(PTCoreBridgeTests PRIVATE
        src/platform/ios/bridge/PTTaskBridge.h src/platform/ios/bridge/PTTaskBridge.mm
        src/platform/ios/bridge/PTPendingDeletionBridge.h src/platform/ios/bridge/PTPendingDeletionBridge.mm
        src/platform/ios/bridge/PTInteractionBridge.h src/platform/ios/bridge/PTInteractionBridge.mm
)
set_source_files_properties(
    src/platform/ios/bridge/PTTaskBridge.mm
    src/platform/ios/bridge/PTPendingDeletionBridge.mm
    src/platform/ios/bridge/PTInteractionBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

# 055-P4-1：专注与到期提醒桥接沿用隔离服务装配，不依赖 UIKit。
add_executable(PTFocusBridgeTests ${PT_CORE_TEST_SOURCES}
    tests/PTFocusBridgeTests.mm
    src/platform/ios/bridge/PTBridgeSupport.h src/platform/ios/bridge/PTBridgeSupport.mm
    src/platform/ios/bridge/PTFocusBridge.h src/platform/ios/bridge/PTFocusBridge.mm
    src/platform/ios/bridge/PTGapReminderBridge.h src/platform/ios/bridge/PTGapReminderBridge.mm
    src/services/PendingDeletion.h src/services/PendingDeletion.cpp
    src/services/FocusSessionController.h src/services/FocusSessionController.cpp
    # 055-P4-1 步骤 4：提醒信号转发需要真实的通知服务与预约协调器。
    src/services/NotificationService.h src/services/NotificationService.cpp
    src/services/PhaseAlarmCoordinator.h src/services/PhaseAlarmCoordinator.cpp)
set_source_files_properties(tests/PTFocusBridgeTests.mm
    src/platform/ios/bridge/PTFocusBridge.mm src/platform/ios/bridge/PTGapReminderBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(PTFocusBridgeTests PRIVATE Qt6::Core Qt6::Gui Qt6::Sql Qt6::Concurrent Qt6::Test "-framework Foundation")
pomodoro_todo_enable_warnings(PTFocusBridgeTests)
add_test(NAME PTFocusBridgeTests COMMAND PTFocusBridgeTests)
set_tests_properties(PTFocusBridgeTests PROPERTIES TIMEOUT 90
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 设备间同步的云盘传输（050 阶段 3）：文件格式、文件夹读写、同步引擎。
# 两台设备各用一个真实结构的临时库，云盘用临时文件夹模拟，可以注入延迟、乱序、坏文件和读写失败。
add_executable(SyncTransportTests
    tests/SyncTransportTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp
    src/services/SyncNotifier.h
    src/services/SyncNotifier.cpp
    src/services/SyncedSettings.h
    src/services/SyncedSettings.cpp
    src/services/SyncFiles.h
    src/services/SyncFiles.cpp
    src/services/SyncFolder.h
    src/services/LocalSyncFolder.h
    src/services/LocalSyncFolder.cpp
    src/services/SyncWorker.h
    src/services/SyncWorker.cpp
    src/services/SyncEngine.h
    src/services/SyncEngine.cpp
    src/platform/macos/MacSyncFolder.h
    src/platform/macos/MacSyncFolder.cpp
    src/platform/apple/AppleUbiquitousItem.h
    src/platform/apple/AppleUbiquitousItem.mm
    src/platform/apple/AppleCoordinatedFiles.h
    src/platform/apple/AppleCoordinatedFiles.mm
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/FocusSessionRules.h
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/MemoService.h
    src/services/MemoService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
)

target_link_libraries(SyncTransportTests PRIVATE
    Qt6::Concurrent
    Qt6::Core
    Qt6::Sql
    Qt6::Test
    "-framework Foundation"
)

pomodoro_todo_enable_warnings(SyncTransportTests)
add_test(NAME SyncTransportTests COMMAND SyncTransportTests)

# 单独验证 Mac 文件协调与跨线程取消，真实文件呈现者仅登记在临时目录中。
add_executable(MacSyncFolderTests
    tests/MacSyncFolderTests.mm
    src/platform/macos/MacSyncFolder.h src/platform/macos/MacSyncFolder.cpp
    src/platform/apple/AppleUbiquitousItem.h src/platform/apple/AppleUbiquitousItem.mm
    src/platform/apple/AppleCoordinatedFiles.h src/platform/apple/AppleCoordinatedFiles.mm
)
set_source_files_properties(tests/MacSyncFolderTests.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(MacSyncFolderTests PRIVATE PTCore Qt6::Core Qt6::Concurrent Qt6::Test "-framework Foundation")
pomodoro_todo_enable_warnings(MacSyncFolderTests)
add_test(NAME MacSyncFolderTests COMMAND MacSyncFolderTests)
set_tests_properties(MacSyncFolderTests PROPERTIES TIMEOUT 30
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 设备间同步接进应用（050 阶段 4）：开关与书签、恢复备份与逻辑日起点的衔接、iPad 选文件夹、同步日志。
# 平台差异（文件夹怎么建、怎么选）由测试注入，同步文件夹用临时目录，不碰真实的 iCloud 云盘。
add_executable(SyncControllerTests
    tests/SyncControllerTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp
    src/services/SyncNotifier.h
    src/services/SyncNotifier.cpp
    src/services/SyncedSettings.h
    src/services/SyncedSettings.cpp
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
    src/services/FocusTimer.h
    src/services/FocusTimer.cpp
    src/services/MonotonicClock.h
    src/services/MonotonicClock.cpp
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    # 055-P2B：投入取档与使用它的服务同目标链接。
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/CategoryManager.h
    src/services/CategoryManager.cpp
    src/services/TaskManager.h
    src/services/TaskManager.cpp
    src/services/RoutineManager.h
    src/services/RoutineManager.cpp
    src/services/RoutineRules.h
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
    src/services/FocusSessionRules.h
    src/services/ScheduleService.h
    src/services/ScheduleService.cpp
    # 055-P2B：周次纯函数与使用它的服务同目标链接。
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/KnowledgeGapService.h
    src/services/KnowledgeGapService.cpp
    src/services/MemoService.h
    src/services/MemoService.cpp
    src/services/CountdownService.h
    src/services/CountdownService.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.h
    src/models/CountdownModel.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp
)

target_link_libraries(SyncControllerTests PRIVATE
    Qt6::Concurrent
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

pomodoro_todo_enable_warnings(SyncControllerTests)
add_test(NAME SyncControllerTests COMMAND SyncControllerTests)

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
)
pomodoro_todo_add_glass_shader(ShaderAssetsTests test_glass_shader)

target_link_libraries(ShaderAssetsTests PRIVATE
    Qt6::Core
    Qt6::Test
)
target_compile_definitions(ShaderAssetsTests PRIVATE
    "POMODORO_SHADER_SOURCE=\"${CMAKE_CURRENT_SOURCE_DIR}/shaders/liquid_glass.frag\""
    "POMODORO_SHADER_BAKER=\"$<TARGET_FILE:Qt6::qsb>\""
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
    src/services/SyncSchema.h src/services/SyncSchema.cpp
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
    src/services/TrashStore.h src/services/TrashStore.cpp
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
if(Python3_FOUND)
    if(APPLE)
        add_test(NAME McpBundleSmoke
            COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/check_mcp_bundle.py"
                "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/MacOS/PomodoroTodoMcp")
        add_test(NAME DeployLocalAppTests
            COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/DeployLocalAppTests.py")
    endif()
    # 055-P3A：原生颜色与 QML 的语义令牌必须同源。
    add_test(NAME IPadThemeGate COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/ipad_theme_gate.py")
    set_tests_properties(IPadThemeGate PROPERTIES TIMEOUT 30)
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

# 055-P3A：全量 ctest 包含 Swift 数据层；构建产物留在当前构建目录里。
find_program(POMODORO_TODO_SWIFT swift REQUIRED)
add_test(NAME IPadSwiftTests COMMAND ${POMODORO_TODO_SWIFT} test
    --package-path "${CMAKE_CURRENT_SOURCE_DIR}/src/ui/ipad"
    --scratch-path "${CMAKE_CURRENT_BINARY_DIR}/ipad-swift")
set_tests_properties(IPadSwiftTests PROPERTIES TIMEOUT 120)

# 055-P2B：纯规则读表测试与真实服务包装的 QML 接线宿主。
add_executable(CaliberTests tests/CaliberTests.cpp src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/StatisticsPeriod.h src/services/StatisticsPeriod.cpp)
target_link_libraries(CaliberTests PRIVATE Qt6::Core Qt6::Test)
target_compile_definitions(CaliberTests PRIVATE CALIBERS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/calibers")
pomodoro_todo_enable_warnings(CaliberTests)
add_test(NAME CaliberTests COMMAND CaliberTests)
set_tests_properties(CaliberTests PROPERTIES TIMEOUT 60 ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

add_executable(CaliberQuickTests tests/CaliberQuickTests.cpp
    src/services/FocusHistoryService.h src/services/FocusHistoryService.cpp
    src/services/HeatmapBands.h src/services/HeatmapBands.cpp
    src/services/AppSettings.h src/services/AppSettings.cpp
    src/services/ScheduleService.h src/services/ScheduleService.cpp
    src/services/ScheduleWeeks.h src/services/ScheduleWeeks.cpp
    src/services/DatabaseManager.h src/services/DatabaseManager.cpp
    src/services/SyncSchema.h src/services/SyncSchema.cpp
    src/services/TrashStore.h src/services/TrashStore.cpp)
target_link_libraries(CaliberQuickTests PRIVATE Qt6::QuickTest Qt6::Quick Qt6::Sql)
pomodoro_todo_enable_warnings(CaliberQuickTests)
set(POMODORO_TODO_CALIBER_QML_TESTS contrast_audit page_scrollbars focus_start_flow week_keyboard_entry heatmap_bands month_heatmap_bar month_cleanup_confirm schedule_weeks schedule_view schedule_grid_tap page_activation_failure dialog_smoke dialog_close_guard)

add_executable(MemoQuickTests tests/MemoQuickTests.cpp)
target_link_libraries(MemoQuickTests PRIVATE PTQml Qt6::QuickTest Qt6::Quick)
pomodoro_todo_enable_warnings(MemoQuickTests)

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
    set(qml_test_runner Qt6::qmltestrunner)
    if(qml_test_name STREQUAL "memo_view")
        set(qml_test_runner MemoQuickTests)
    elseif(qml_test_name IN_LIST POMODORO_TODO_CALIBER_QML_TESTS)
        set(qml_test_runner CaliberQuickTests)
    endif()
    add_test(
        NAME QmlTest.${qml_test_name}
        COMMAND ${qml_test_runner} -input "${qml_test_file}"
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
        #   ReferenceError                绑定里引用了不存在的名字（改名、删 id 后漏改），同样当场中断
        #   RangeError                    JavaScript 栈溢出：递归失控，或组件在不对的作用域里创建
        #                                 （截图脚本漏写 ComponentBehavior: Bound 时出现过，行号是乱的）
        #   Binding loop                  绑定反复求值，界面可能停在中间态
        # 实测本仓曾同时存在三处：ExportDialog 的 busy 决定导出期间能否关窗却停在旧值；
        # MonthGoalView.formatDuration 抛 TypeError，跳过了它自己写的兜底格式化。
        #
        # 挂在已有条目上而不是新加一条门禁：串行重跑全部 QML 测试实测 63s，
        # 会让全量从 22s 涨到三倍以上，而这里是零额外开销。
        # 某条测试确实需要故意触发告警时，单独覆盖它的 FAIL_REGULAR_EXPRESSION。
        FAIL_REGULAR_EXPRESSION "Unable to assign;TypeError;is not a function;ReferenceError;RangeError;Binding loop"
    )
    # 055-P2B：只有读表用例允许本地 XHR，生产与其它测试不放宽权限。
    if(qml_test_name STREQUAL "schedule_weeks" OR qml_test_name STREQUAL "heatmap_bands" OR qml_test_name STREQUAL "caliber_shared" OR qml_test_name STREQUAL "caliber_display")
        set_property(TEST QmlTest.${qml_test_name} APPEND PROPERTY ENVIRONMENT "QML_XHR_ALLOW_FILE_READ=1")
    endif()
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
    SyncTests
    # 同步引擎在工作线程里读写文件：万一卡死，到点就报出来，不让全套一直挂着。
    SyncTransportTests
    SyncControllerTests
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
    AppleNotificationBackendTests
    MacPreferencesCleanupTests
    MacGlobalHotkeyTests
    PROPERTIES TIMEOUT 30
)

# 055-P3B：科目、逻辑日与设置的 Mac 桥接测试。
target_sources(PTCoreBridgeTests PRIVATE
    src/platform/ios/bridge/PTCategoryBridge.h src/platform/ios/bridge/PTCategoryBridge.mm
    src/platform/ios/bridge/PTLogicalDayBridge.h src/platform/ios/bridge/PTLogicalDayBridge.mm
    src/platform/ios/bridge/PTSettingsBridge.h src/platform/ios/bridge/PTSettingsBridge.mm
    src/services/StatisticsPeriod.h src/services/StatisticsPeriod.cpp
)
set_source_files_properties(
    src/platform/ios/bridge/PTCategoryBridge.mm
    src/platform/ios/bridge/PTLogicalDayBridge.mm
    src/platform/ios/bridge/PTSettingsBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

# 055-P3B：统计与专注历史加入核心桥接测试。
target_sources(PTCoreBridgeTests PRIVATE
    src/services/StatisticsService.h src/services/StatisticsService.cpp
    src/platform/ios/bridge/PTStatisticsBridge.h src/platform/ios/bridge/PTStatisticsBridge.mm
    src/platform/ios/bridge/PTFocusHistoryBridge.h src/platform/ios/bridge/PTFocusHistoryBridge.mm
)
set_source_files_properties(
    src/platform/ios/bridge/PTStatisticsBridge.mm
    src/platform/ios/bridge/PTFocusHistoryBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

# 055-P4-2：课表桥接在 Mac 用 Foundation + Qt Test 测，复用同领域服务源清单。
get_target_property(PT_SCHEDULE_TEST_SOURCES ScheduleServiceTests SOURCES)
list(REMOVE_ITEM PT_SCHEDULE_TEST_SOURCES tests/ScheduleServiceTests.cpp)
add_executable(PTScheduleBridgeTests ${PT_SCHEDULE_TEST_SOURCES}
    tests/PTScheduleBridgeTests.mm
    src/platform/ios/bridge/PTScheduleBridge.h src/platform/ios/bridge/PTScheduleBridge.mm
    src/platform/ios/bridge/PTBridgeSupport.h src/platform/ios/bridge/PTBridgeSupport.mm)
set_source_files_properties(tests/PTScheduleBridgeTests.mm src/platform/ios/bridge/PTScheduleBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_compile_definitions(PTScheduleBridgeTests PRIVATE PT_CALIBERS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/calibers")
target_link_libraries(PTScheduleBridgeTests PRIVATE Qt6::Core Qt6::Sql Qt6::Test "-framework Foundation")
pomodoro_todo_enable_warnings(PTScheduleBridgeTests)
add_test(NAME PTScheduleBridgeTests COMMAND PTScheduleBridgeTests)
set_tests_properties(PTScheduleBridgeTests PROPERTIES TIMEOUT 90
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 055-P4-5：独立数据桥接目标；P3B 的核心桥接目标与用例保持原样。
get_target_property(PT_DATA_TEST_SOURCES TrashServiceTests SOURCES)
list(REMOVE_ITEM PT_DATA_TEST_SOURCES tests/TrashServiceTests.cpp)
add_executable(PTDataBridgeTests ${PT_DATA_TEST_SOURCES}
    tests/PTDataBridgeTests.mm
    src/platform/ios/bridge/PTBridgeSupport.h src/platform/ios/bridge/PTBridgeSupport.mm
    # 055-P4-5：桥接所依赖的服务实现；沿用 TrashServiceTests 的隔离数据库装配。
    src/services/BackupOperations.h src/services/BackupOperations.cpp
    src/services/BackupService.h src/services/BackupService.cpp
    src/services/SnapshotRetention.h
    src/services/ExportService.h src/services/ExportService.cpp
    src/services/SyncFiles.h src/services/SyncFiles.cpp
    src/services/SyncFolder.h
    src/services/LocalSyncFolder.h src/services/LocalSyncFolder.cpp
    src/services/SyncWorker.h src/services/SyncWorker.cpp
    src/services/SyncEngine.h src/services/SyncEngine.cpp
    src/services/SyncController.h src/services/SyncController.cpp
    src/services/ServiceReadResult.h
    src/platform/ios/bridge/PTTrashBridge.h src/platform/ios/bridge/PTTrashBridge.mm
    src/platform/ios/bridge/PTSyncBridge.h src/platform/ios/bridge/PTSyncBridge.mm
    src/platform/ios/bridge/PTBackupBridge.h src/platform/ios/bridge/PTBackupBridge.mm
    src/platform/ios/bridge/PTExportBridge.h src/platform/ios/bridge/PTExportBridge.mm
    src/platform/ios/bridge/PTRoutineBridge.h src/platform/ios/bridge/PTRoutineBridge.mm
)
set_source_files_properties(tests/PTDataBridgeTests.mm
    src/platform/ios/bridge/PTTrashBridge.mm
    src/platform/ios/bridge/PTSyncBridge.mm
    src/platform/ios/bridge/PTBackupBridge.mm
    src/platform/ios/bridge/PTExportBridge.mm
    src/platform/ios/bridge/PTRoutineBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(PTDataBridgeTests PRIVATE Qt6::Core Qt6::Gui Qt6::Sql Qt6::Concurrent Qt6::Test "-framework Foundation")
pomodoro_todo_enable_warnings(PTDataBridgeTests)
add_test(NAME PTDataBridgeTests COMMAND PTDataBridgeTests)
set_tests_properties(PTDataBridgeTests PROPERTIES TIMEOUT 90
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 055-P4-3：三个内容桥接在 Mac 上共用一个测试目标。
get_target_property(PT_CONTENT_TEST_SOURCES TrashServiceTests SOURCES)
list(REMOVE_ITEM PT_CONTENT_TEST_SOURCES tests/TrashServiceTests.cpp)
add_executable(PTContentBridgeTests ${PT_CONTENT_TEST_SOURCES}
    tests/PTContentBridgeTests.mm
    src/platform/ios/bridge/PTBridgeSupport.mm
    src/platform/ios/bridge/PTKnowledgeGapBridge.h src/platform/ios/bridge/PTKnowledgeGapBridge.mm
    src/platform/ios/bridge/PTMemoBridge.h src/platform/ios/bridge/PTMemoBridge.mm
    src/platform/ios/bridge/PTCountdownBridge.h src/platform/ios/bridge/PTCountdownBridge.mm
)
set_source_files_properties(tests/PTContentBridgeTests.mm
    src/platform/ios/bridge/PTKnowledgeGapBridge.mm
    src/platform/ios/bridge/PTMemoBridge.mm
    src/platform/ios/bridge/PTCountdownBridge.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(PTContentBridgeTests PRIVATE Qt6::Core Qt6::Gui Qt6::Sql Qt6::Concurrent Qt6::Test "-framework Foundation")
pomodoro_todo_enable_warnings(PTContentBridgeTests)
add_test(NAME PTContentBridgeTests COMMAND PTContentBridgeTests)
set_tests_properties(PTContentBridgeTests PROPERTIES TIMEOUT 90
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 057-B：新增共享装配与生命周期测试目标 SharedAppTests
add_executable(SharedAppTests
    tests/SharedAppTests.cpp
    src/mcp/common/McpPaths.cpp
)
target_link_libraries(SharedAppTests PRIVATE
    PTApp
    Qt6::Core
    Qt6::Gui
    Qt6::GuiPrivate
    Qt6::Sql
    Qt6::Concurrent
    Qt6::Test
)
pomodoro_todo_enable_warnings(SharedAppTests)
add_test(NAME SharedAppTests COMMAND SharedAppTests)
set_tests_properties(SharedAppTests PROPERTIES TIMEOUT 60
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 057-C：新增 QML 上下文属性安装测试目标 QmlFacadeTests
add_executable(QmlFacadeTests
    tests/QmlFacadeTests.cpp
    src/mcp/common/McpPaths.cpp
    resources/fonts.qrc
)
target_link_libraries(QmlFacadeTests PRIVATE
    PTQml
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::Sql
    Qt6::Test
)
pomodoro_todo_enable_warnings(QmlFacadeTests)
add_test(NAME QmlFacadeTests COMMAND QmlFacadeTests)
set_tests_properties(QmlFacadeTests PROPERTIES TIMEOUT 60
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 057-C：新增 iOS 界面路由纯函数测试目标 UiRouterTests
add_executable(UiRouterTests
    tests/UiRouterTests.cpp
    src/entry/ios/UiRouter.cpp
    src/entry/ios/UiRouter.h
    src/platform/ios/native/IPadUiPreferences.h
)
target_include_directories(UiRouterTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(UiRouterTests PRIVATE
    Qt6::Core
    Qt6::Test
)
pomodoro_todo_enable_warnings(UiRouterTests)
add_test(NAME UiRouterTests COMMAND UiRouterTests)
set_tests_properties(UiRouterTests PROPERTIES TIMEOUT 60
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 057-A：测试与联调宿主改链 PTCore。只从目标删除已经属于 PTCore 的源文件；
# PlainTextLayout、SingleInstanceGuard 和平台桥接源码不在 PTCore，保留它们各自的测试边界。
get_property(POMODORO_TODO_ALL_TARGETS DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
foreach(pt_target IN LISTS POMODORO_TODO_ALL_TARGETS)
    if(pt_target STREQUAL "PTCore" OR pt_target STREQUAL "PTApp" OR pt_target STREQUAL "PTQml"
       OR pt_target STREQUAL "PomodoroTodo" OR pt_target STREQUAL "PomodoroTodoMcp"
       OR pt_target STREQUAL "McpTestHelper" OR pt_target STREQUAL "SharedAppTests"
       OR pt_target STREQUAL "QmlFacadeTests" OR pt_target STREQUAL "UiRouterTests")
        continue()
    endif()
    get_target_property(pt_target_type ${pt_target} TYPE)
    if(NOT pt_target_type STREQUAL "EXECUTABLE")
        continue()
    endif()
    get_target_property(pt_target_sources ${pt_target} SOURCES)
    if(NOT pt_target_sources)
        continue()
    endif()
    set(pt_target_used_core FALSE)
    foreach(pt_source IN LISTS pt_target_sources)
        set(pt_source_is_core FALSE)
        foreach(ptcore_source IN LISTS PTCORE_SOURCES)
            if(pt_source STREQUAL "${ptcore_source}" OR pt_source STREQUAL "${CMAKE_CURRENT_SOURCE_DIR}/${ptcore_source}")
                set(pt_source_is_core TRUE)
                break()
            endif()
        endforeach()
        if(pt_source_is_core)
            list(REMOVE_ITEM pt_target_sources "${pt_source}")
            set(pt_target_used_core TRUE)
        endif()
    endforeach()
    if(pt_target_used_core)
        set_property(TARGET ${pt_target} PROPERTY SOURCES "${pt_target_sources}")
        target_link_libraries(${pt_target} PRIVATE PTCore)
    endif()
endforeach()

if(APPLE AND NOT IOS)
    add_executable(SqliteRuntimeTests tests/SqliteRuntimeTests.cpp)
    target_link_libraries(SqliteRuntimeTests PRIVATE PTMacSqliteRuntime Qt6::Test SQLite::SQLite3)
    target_compile_definitions(SqliteRuntimeTests PRIVATE
        POMODORO_SQLITE_TEST_PLUGIN_PATH="$<TARGET_FILE:PTSqliteDriver>"
        POMODORO_SQLITE_APP_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/PlugIns/sqldrivers/$<TARGET_FILE_NAME:PTSqliteDriver>")
    add_dependencies(SqliteRuntimeTests PTSqliteDriver)
    pomodoro_todo_enable_warnings(SqliteRuntimeTests)
    pomodoro_todo_enable_warnings(PTMacSqliteRuntime)
    add_test(NAME SqliteRuntimeTests COMMAND SqliteRuntimeTests)
    set_tests_properties(SqliteRuntimeTests PROPERTIES TIMEOUT 60
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

    target_link_libraries(PomodoroTodo PRIVATE PTMacSqliteRuntime)
    # 插件单独重编也必须更新包内副本，不能只依赖应用重新链接时的POST_BUILD。
    add_custom_target(bundle-sqlite-runtime ALL
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/PlugIns/sqldrivers"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:PTSqliteDriver>"
            "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/PlugIns/sqldrivers/$<TARGET_FILE_NAME:PTSqliteDriver>"
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${pt_sqlite_source_root}/LICENSES"
            "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/Resources/licenses/qt-sqlite"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_BINARY_DIR}/pt-sqlite/source.json"
            "$<TARGET_BUNDLE_DIR:PomodoroTodo>/Contents/Resources/licenses/qt-sqlite/source.json"
        DEPENDS PomodoroTodo PTSqliteDriver VERBATIM)
    add_dependencies(SqliteRuntimeTests bundle-sqlite-runtime)
    if(TARGET deploy-local-app)
        add_dependencies(deploy-local-app bundle-sqlite-runtime)
    endif()

    # 同一装配覆盖直接编译服务及改链PTCore的测试／隔离宿主；MCP协议helper保持不链接SQL。
    get_property(pt_sqlite_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
    foreach(pt_sqlite_target IN LISTS pt_sqlite_targets)
        get_target_property(pt_sqlite_type ${pt_sqlite_target} TYPE)
        if(NOT pt_sqlite_type STREQUAL "EXECUTABLE" OR pt_sqlite_target STREQUAL "PomodoroTodo"
           OR pt_sqlite_target STREQUAL "SqliteRuntimeTests")
            continue()
        endif()
        get_target_property(pt_sqlite_links ${pt_sqlite_target} LINK_LIBRARIES)
        if(pt_sqlite_links MATCHES "(^|;)(PTCore|PTApp|PTQml|Qt6::Sql)(;|$)")
            target_sources(${pt_sqlite_target} PRIVATE tests/SqliteRuntimeTestBootstrap.cpp)
            target_link_libraries(${pt_sqlite_target} PRIVATE PTMacSqliteRuntime)
            target_compile_definitions(${pt_sqlite_target} PRIVATE
                POMODORO_SQLITE_TEST_PLUGIN_PATH="$<TARGET_FILE:PTSqliteDriver>")
            add_dependencies(${pt_sqlite_target} PTSqliteDriver)
        endif()
    endforeach()
endif()

# ArchitectureGate 在配置阶段读取目标的源码，避免带入生成阶段 AUTOMOC 追加的构建规则文件。
# TARGET_PROPERTY 的结果不递归求值，保留 LINK_ONLY 等表达式交给门禁判断；直接插值会让
# file(GENERATE) 提前求值，在门禁运行前就因 LINK_ONLY 只能用于链接而失败。
get_target_property(PTCORE_MANIFEST_SOURCES PTCore SOURCES)
string(REPLACE ";" "\",\"" PTCORE_MANIFEST_SOURCES "${PTCORE_MANIFEST_SOURCES}")
get_target_property(PTAPP_MANIFEST_SOURCES PTApp SOURCES)
string(REPLACE ";" "\",\"" PTAPP_MANIFEST_SOURCES "${PTAPP_MANIFEST_SOURCES}")
get_target_property(PTQML_MANIFEST_SOURCES PTQml SOURCES)
string(REPLACE ";" "\",\"" PTQML_MANIFEST_SOURCES "${PTQML_MANIFEST_SOURCES}")
string(CONFIGURE [=[
{
  "PTCore": {
    "sources": ["@PTCORE_MANIFEST_SOURCES@"],
    "link_libraries": ["$<JOIN:$<TARGET_PROPERTY:PTCore,LINK_LIBRARIES>,",">"],
    "interface_link_libraries": ["$<JOIN:$<TARGET_PROPERTY:PTCore,INTERFACE_LINK_LIBRARIES>,",">"]
  },
  "PTApp": {
    "sources": ["@PTAPP_MANIFEST_SOURCES@"],
    "link_libraries": ["$<JOIN:$<TARGET_PROPERTY:PTApp,LINK_LIBRARIES>,",">"],
    "interface_link_libraries": ["$<JOIN:$<TARGET_PROPERTY:PTApp,INTERFACE_LINK_LIBRARIES>,",">"]
  },
  "PTQml": {
    "sources": ["@PTQML_MANIFEST_SOURCES@"],
    "link_libraries": ["$<JOIN:$<TARGET_PROPERTY:PTQml,LINK_LIBRARIES>,",">"],
    "interface_link_libraries": ["$<JOIN:$<TARGET_PROPERTY:PTQml,INTERFACE_LINK_LIBRARIES>,",">"]
  }
}
]=] PT_ARCHITECTURE_MANIFEST @ONLY)
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/architecture-manifest.json"
    CONTENT "${PT_ARCHITECTURE_MANIFEST}")

if(NOT IOS AND Python3_FOUND)
    add_test(NAME ArchitectureGate
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/architecture_gate.py"
            "${CMAKE_CURRENT_BINARY_DIR}/architecture-manifest.json"
            "${CMAKE_CURRENT_SOURCE_DIR}")
    set_tests_properties(ArchitectureGate PROPERTIES TIMEOUT 30)

    add_test(NAME ArchitectureGateR8
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_architecture_gate_r8.py")
    set_tests_properties(ArchitectureGateR8 PROPERTIES TIMEOUT 30)
endif()

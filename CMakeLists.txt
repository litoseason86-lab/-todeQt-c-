cmake_minimum_required(VERSION 3.16)

project(PomodoroTodo VERSION 0.1.0 LANGUAGES CXX)

# 菜单栏与系统通知走 macOS 原生 API（NSStatusItem / UNUserNotificationCenter），
# 需要 Objective-C++ 编译能力。本项目只面向 macOS，不做其它平台分支。
enable_language(OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Concurrent Core Gui Network Quick QuickControls2 QuickLayouts QuickTest Sql Test)

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
    src/platform/macos/MacStatusBarController.h
    src/platform/macos/MacStatusBarController.mm
    src/platform/macos/MacNotificationBackend.h
    src/platform/macos/MacNotificationBackend.mm
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
set_source_files_properties(
    src/platform/macos/MacStatusBarController.mm
    src/platform/macos/MacNotificationBackend.mm
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

if(APPLE AND POMODORO_TODO_DEPLOY_LOCAL)
    set(POMODORO_TODO_LOCAL_APP_PATH "/Applications/番茄Todo.app" CACHE PATH
        "本机固定启动入口，构建后会用最新包覆盖这里"
    )
    set(POMODORO_TODO_LSREGISTER
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    )

    add_custom_target(deploy-local-app ALL
        COMMAND ${CMAKE_COMMAND} -E echo "Deploying PomodoroTodo to ${POMODORO_TODO_LOCAL_APP_PATH}"
        COMMAND /bin/rm -rf "${POMODORO_TODO_LOCAL_APP_PATH}"
        COMMAND ${CMAKE_COMMAND} -E copy_directory "$<TARGET_BUNDLE_DIR:PomodoroTodo>" "${POMODORO_TODO_LOCAL_APP_PATH}"
        # LaunchOS 依赖系统应用索引；复制后主动刷新固定入口。build 目录里的临时包可能从未注册，
        # lsregister -u 在这种情况下会返回错误码，因此撤销临时包索引只能作为尽力而为步骤。
        COMMAND /bin/sh -c "'${POMODORO_TODO_LSREGISTER}' -u '$<TARGET_BUNDLE_DIR:PomodoroTodo>' >/dev/null 2>&1 || true"
        COMMAND "${POMODORO_TODO_LSREGISTER}" -f "${POMODORO_TODO_LOCAL_APP_PATH}"
        DEPENDS PomodoroTodo
        VERBATIM
    )
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

add_test(NAME CountdownServiceTests COMMAND CountdownServiceTests)

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

add_test(NAME PlatformControlTests COMMAND PlatformControlTests)

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

add_test(NAME TimingRobustnessTests COMMAND TimingRobustnessTests)

add_executable(FontAssetsTests
    tests/FontAssetsTests.cpp
    resources/fonts.qrc
)

target_link_libraries(FontAssetsTests PRIVATE
    Qt6::Gui
    Qt6::Test
)

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

add_test(NAME ShaderAssetsTests COMMAND ShaderAssetsTests)

add_test(
    NAME PomodoroTodoQmlTests
    COMMAND Qt6::qmltestrunner -input ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml
)
set_tests_properties(PomodoroTodoQmlTests PROPERTIES
    # 测试固定离屏平台与 Basic 风格，后台验证不得创建真实应用窗口。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic"
)

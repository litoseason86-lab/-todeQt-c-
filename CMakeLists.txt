cmake_minimum_required(VERSION 3.16)

project(PomodoroTodo VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick QuickControls2 QuickLayouts QuickTest Sql Test)

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
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.cpp
    src/services/ExportService.cpp
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    src/services/StatisticsService.cpp
    src/services/FocusSessionRules.h
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
    src/services/CountdownService.cpp
    resources/qml.qrc
)

add_executable(PomodoroTodo ${APP_SOURCES})

option(POMODORO_TODO_ENABLE_QML_DEBUG "Enable QML debugging and profiling hooks" ON)
if(POMODORO_TODO_ENABLE_QML_DEBUG)
    # 通过配置项控制 QML 调试钩子，避免为了调试改动发布源码。
    target_compile_definitions(PomodoroTodo PRIVATE QT_QML_DEBUG)
endif()

target_link_libraries(PomodoroTodo PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::QuickLayouts
    Qt6::Sql
)

set_target_properties(PomodoroTodo PROPERTIES
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

enable_testing()

add_executable(PomodoroTodoTests
    tests/ServiceTests.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.cpp
    src/services/CategoryManager.cpp
    src/services/ExportService.cpp
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    src/services/StatisticsService.cpp
    src/services/FocusHistoryService.cpp
)

target_link_libraries(PomodoroTodoTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

add_test(NAME PomodoroTodoTests COMMAND PomodoroTodoTests)

add_executable(CountdownServiceTests
    tests/CountdownServiceTests.cpp
    src/models/CountdownGoal.cpp
    src/models/CountdownModel.cpp
    src/services/DatabaseManager.cpp
    src/services/CountdownService.cpp
)

target_link_libraries(CountdownServiceTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

add_test(NAME CountdownServiceTests COMMAND CountdownServiceTests)

add_test(
    NAME PomodoroTodoQmlTests
    COMMAND Qt6::qmltestrunner -input ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml
)
set_tests_properties(PomodoroTodoQmlTests PROPERTIES
    # 与应用的 Basic 风格保持一致，避免视觉和布局断言随宿主平台变化。
    ENVIRONMENT "QT_QUICK_CONTROLS_STYLE=Basic"
)

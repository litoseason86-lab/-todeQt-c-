cmake_minimum_required(VERSION 3.16)

project(PomodoroTodo VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick QuickControls2 QuickLayouts Sql Test)

set(APP_SOURCES
    src/main.cpp
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.cpp
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    src/services/StatisticsService.cpp
    resources/qml.qrc
)

add_executable(PomodoroTodo ${APP_SOURCES})

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
    src/services/TaskManager.cpp
    src/services/FocusTimer.cpp
    src/services/StatisticsService.cpp
)

target_link_libraries(PomodoroTodoTests PRIVATE
    Qt6::Core
    Qt6::Sql
    Qt6::Test
)

add_test(NAME PomodoroTodoTests COMMAND PomodoroTodoTests)

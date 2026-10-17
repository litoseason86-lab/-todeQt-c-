# 测试目标与门禁从主配置原样搬入；include 保持原目录及变量作用域，方便独立维护测试接线。
enable_testing()

if(APPLE)
    add_executable(MacExitWatchdogTests tests/MacExitWatchdogTests.cpp
        src/platform/macos/MacExitWatchdog.h src/platform/macos/MacExitWatchdog.cpp)
    target_include_directories(MacExitWatchdogTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_link_libraries(MacExitWatchdogTests PRIVATE Qt6::Core Qt6::Test)
    pomodoro_todo_enable_warnings(MacExitWatchdogTests)
    add_test(NAME MacExitWatchdogTests COMMAND MacExitWatchdogTests)
    set_tests_properties(MacExitWatchdogTests PROPERTIES TIMEOUT 30
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

    add_executable(BackupExecutorStub tests/support/BackupExecutorStub.cpp)
    target_link_libraries(BackupExecutorStub PRIVATE Qt6::Core)
    pomodoro_todo_enable_warnings(BackupExecutorStub)
    add_executable(MacBackupExecutorTests tests/MacBackupExecutorTests.cpp
        src/platform/macos/MacBackupExecutor.h src/platform/macos/MacBackupExecutor.cpp)
    target_link_libraries(MacBackupExecutorTests PRIVATE PTCore Qt6::Test)
    target_compile_definitions(MacBackupExecutorTests PRIVATE
        POMODORO_TODO_VERSION="${PROJECT_VERSION}"
        POMODORO_BACKUP_EXECUTOR_PATH="$<TARGET_FILE:PomodoroTodoBackupExecutor>"
        POMODORO_BACKUP_STUB_PATH="$<TARGET_FILE:BackupExecutorStub>"
        POMODORO_BACKUP_MEASUREMENT_ROOT="${CMAKE_BINARY_DIR}")
    add_dependencies(MacBackupExecutorTests PomodoroTodoBackupExecutor BackupExecutorStub)
    pomodoro_todo_enable_warnings(MacBackupExecutorTests)
    add_test(NAME MacBackupExecutorTests COMMAND MacBackupExecutorTests)
    set_tests_properties(MacBackupExecutorTests PROPERTIES TIMEOUT 120
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic;POMODORO_MEASURE_BACKUP_EXECUTOR=0")
endif()

add_executable(BackupExecutorProtocolTests tests/BackupExecutorProtocolTests.cpp)
target_link_libraries(BackupExecutorProtocolTests PRIVATE PTCore Qt6::Test)
pomodoro_todo_enable_warnings(BackupExecutorProtocolTests)
add_test(NAME BackupExecutorProtocolTests COMMAND BackupExecutorProtocolTests)
set_tests_properties(BackupExecutorProtocolTests PROPERTIES TIMEOUT 60
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_CONTROLS_STYLE=Basic")

# 架构门禁与原生偏好测试的退出后清理均依赖 Python；iOS 已在上方返回。
find_package(Python3 COMPONENTS Interpreter REQUIRED)

function(pomodoro_todo_add_native_preferences_test target)
    add_test(NAME ${target}
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/run_native_preferences_test.py"
            "$<TARGET_FILE:${target}>")
endfunction()

add_executable(PomodoroTodoTests
    tests/ServiceTests.cpp
    tests/support/NativePreferenceDomain.h
    src/models/Task.cpp
    src/models/FocusSession.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    tests/support/NativePreferenceDomain.h
    src/models/Task.h
    src/models/Task.cpp
    src/services/DatabaseManager.h
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.h src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    tests/support/NativePreferenceDomain.h
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp src/services/SyncApplier.h src/services/SyncApplier.cpp
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
    tests/support/NativePreferenceDomain.h
    src/models/Task.cpp
    src/models/FocusSession.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp src/services/SyncApplier.h src/services/SyncApplier.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp src/services/SyncApplier.h src/services/SyncApplier.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp src/services/SyncApplier.h src/services/SyncApplier.cpp
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
    src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
    src/services/SyncSchema.h
    src/services/SyncSchema.cpp
    src/services/SyncRecord.h
    src/services/SyncRecord.cpp
    src/services/SyncStore.h
    src/services/SyncStore.cpp src/services/SyncApplier.h src/services/SyncApplier.cpp
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
    src/services/DatabaseManager.h src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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

    # 固定等待门禁（062 A059）：tests/qml 下不直接写 wait()/qWait()。固定时长要么白等，要么在并行负载下不够长；
    # 等状态用 tryCompare / tryVerify，确需时间窗（确认没发生、让计时器下一拍走完）走 TestWaits.js 并写明原因。
    add_test(NAME QmlFixedWaitGate
             COMMAND ${Python3_EXECUTABLE}
                     ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml_fixed_wait_gate.py
                     ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml)
    set_tests_properties(QmlFixedWaitGate PROPERTIES TIMEOUT 60)
    # 门禁自身的自检：每种直接等待写法都拦、注释与字符串不误报、TestWaits 调用必须写原因。
    add_test(NAME QmlFixedWaitGateTests
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_qml_fixed_wait_gate.py)
    set_tests_properties(QmlFixedWaitGateTests PROPERTIES TIMEOUT 30)

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
    src/services/DatabaseManager.h src/services/DatabaseManager.cpp src/services/DatabaseMigrations.cpp
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
           OR pt_sqlite_target STREQUAL "SqliteRuntimeTests"
           OR pt_sqlite_target STREQUAL "PomodoroTodoBackupExecutor")
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

    # R9 检查器自身的反例与正例，并核对单例白名单与现有代码一一对应（062 A057）。
    add_test(NAME ArchitectureGateR9
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_architecture_gate_r9.py")
    set_tests_properties(ArchitectureGateR9 PROPERTIES TIMEOUT 30)

    # 原生偏好测试的清理脚本自检：读域名文件、白名单拒绝、缺文件不清理与退出码传播（062 A060）。
    add_test(NAME NativePreferencesRunnerTests
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_run_native_preferences.py")
    set_tests_properties(NativePreferencesRunnerTests PROPERTIES TIMEOUT 30)
endif()

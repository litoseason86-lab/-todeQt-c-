# 外部 AI 辅助程序的链接门禁（plans/047）。
#
# 辅助程序由 AI 客户端直接拉起，只负责 MCP 协议与转发；数据库、业务服务和界面都在主应用里。
# 它一旦链接了 Qt Sql / Gui / QML，就说明业务代码被带进了辅助程序，
# 权限边界“所有读写都经主应用执行前检查”就可能被绕开。这里读取实际的动态库依赖来判断。
#
# 用法：cmake -DHELPER_BINARY=<辅助程序路径> -P CheckMcpHelperLinks.cmake

if(NOT DEFINED HELPER_BINARY OR NOT EXISTS "${HELPER_BINARY}")
    message(FATAL_ERROR "找不到辅助程序可执行文件：${HELPER_BINARY}")
endif()

execute_process(
    COMMAND otool -L "${HELPER_BINARY}"
    OUTPUT_VARIABLE helper_links
    ERROR_VARIABLE helper_link_errors
    RESULT_VARIABLE helper_link_result
)
if(NOT helper_link_result EQUAL 0)
    message(FATAL_ERROR "otool -L 执行失败（${helper_link_result}）：${helper_link_errors}")
endif()

# 先确认确实读到了 Qt 依赖：otool 输出格式一旦变化、下面的匹配全部落空，门禁会“永远通过”。
if(NOT helper_links MATCHES "QtCore[.]framework|libQt6Core[.]")
    message(FATAL_ERROR "没有在辅助程序的依赖里找到 QtCore，门禁无法判断：\n${helper_links}")
endif()

# 框架形式（QtGui.framework）、动态库形式（libQt6Gui.6.dylib）以及系统 libsqlite3 都要拦。
# 采用 Qt 模块白名单（只允许 QtCore 与 QtNetwork），自动拦下 QtWebEngine / QtShaderTools / QtOpenGL 等任意其他 Qt 模块。
set(violations "")
string(REGEX MATCHALL "(Qt|libQt6)[A-Za-z0-9_]+[.]" qt_matched "${helper_links}")
foreach(qt_dep IN LISTS qt_matched)
    if(NOT qt_dep MATCHES "^(Qt|libQt6)(Core|Network)[.]")
        list(APPEND violations "${qt_dep}")
    endif()
endforeach()

string(REGEX MATCHALL "(libsqlite3|sqlite3)[A-Za-z0-9._-]*[.]dylib" sqlite_matched "${helper_links}")
if(sqlite_matched)
    list(APPEND violations ${sqlite_matched})
endif()

if(violations)
    list(REMOVE_DUPLICATES violations)
    string(REPLACE ";" ", " violation_text "${violations}")
    message(FATAL_ERROR
        "辅助程序链接了不允许的模块或 SQLite 库：${violation_text}\n"
        "它只能链接 Qt Core 与 Qt Network；业务服务、SQL 与界面必须留在主应用。\n"
        "完整依赖：\n${helper_links}")
endif()

# 再检查符号表，拦下通过静态库或直接把业务/SQLite 源码编进 helper 的绕过。
execute_process(
    COMMAND nm "${HELPER_BINARY}"
    OUTPUT_VARIABLE helper_symbols
    ERROR_VARIABLE helper_symbol_errors
    RESULT_VARIABLE helper_symbol_result
)
if(NOT helper_symbol_result EQUAL 0 OR "${helper_symbols}" STREQUAL "")
    message(FATAL_ERROR "nm 无法读取辅助程序符号表（${helper_symbol_result}）：${helper_symbol_errors}")
endif()

set(forbidden_symbol_re
    "(^|[^A-Za-z0-9_])_?(sqlite3_[A-Za-z0-9_]+|[A-Za-z0-9_]*(DatabaseManager|TaskManager|CategoryManager|RoutineManager|FocusTimer|FocusHistoryService|StatisticsService|KnowledgeGapService|MemoService|CountdownService|ScheduleService|TrashService|TrashStore|ExportService|BackupService|SyncController|SyncEngine|SyncStore|SyncApplier|AppSettings|SharedApp|QmlFacade|QSqlDatabase|QSqlQuery|QGuiApplication|QQmlEngine|QQuickView)[A-Za-z0-9_]*)"
)
string(REGEX MATCHALL "${forbidden_symbol_re}" forbidden_symbols "${helper_symbols}")
if(forbidden_symbols)
    list(REMOVE_DUPLICATES forbidden_symbols)
    list(SUBLIST forbidden_symbols 0 5 forbidden_preview)
    string(REPLACE ";" ", " symbol_text "${forbidden_preview}")
    message(FATAL_ERROR
        "辅助程序符号表包含禁止的 SQLite 或业务/界面符号（可能静态链接或直接编入了业务源码）：${symbol_text}")
endif()

message(STATUS "辅助程序链接门禁通过：只依赖允许的 Qt 模块且无静态业务/SQLite 符号")

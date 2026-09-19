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

# 框架形式（QtGui.framework）与动态库形式（libQt6Gui.6.dylib）都要拦。
set(forbidden_modules Gui Sql Widgets Concurrent Qml Quick)
set(violations "")
foreach(module IN LISTS forbidden_modules)
    # Qml、Quick 带上后缀变体（QmlModels、QuickControls2 等）。
    if(module STREQUAL "Qml" OR module STREQUAL "Quick")
        set(pattern "(Qt|libQt6)${module}[A-Za-z0-9]*[.]")
    else()
        set(pattern "(Qt|libQt6)${module}[.]")
    endif()
    string(REGEX MATCHALL "${pattern}" matched "${helper_links}")
    if(matched)
        list(APPEND violations ${matched})
    endif()
endforeach()

if(violations)
    list(REMOVE_DUPLICATES violations)
    string(REPLACE ";" ", " violation_text "${violations}")
    message(FATAL_ERROR
        "辅助程序链接了不允许的模块：${violation_text}\n"
        "它只能链接 Qt Core 与 Qt Network；业务服务、SQL 与界面必须留在主应用。\n"
        "完整依赖：\n${helper_links}")
endif()

message(STATUS "辅助程序链接门禁通过：只依赖允许的 Qt 模块")

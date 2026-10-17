cmake_minimum_required(VERSION 3.16)

# 本机部署：把新构建的应用包切换到固定启动入口（默认 /Applications/番茄Todo.app）。
# 顺序固定为：复制到同目录的暂存包 → 校验主程序与辅助程序 → 旧包改名备份 → rename 换上新包
# → 删除备份并用 lsregister 刷新 LaunchServices（macOS 记录应用位置与打开方式的系统索引）。
# 不得改成「先删旧包再复制新包」：中途失败会让用户既没有旧包也没有新包。
# DeployLocalAppTests 用伪应用包验证新包不完整时旧包原样保留，改这里后必须让它通过。

# 包身份先于任何复制或移动核对；仅凭 .app 后缀不能证明目标是本项目。
# PlistBuddy 同时支持文本和二进制 plist，不以文件名或可执行文件名冒充身份。
function(pomodoro_todo_check_bundle_identity bundle)
    execute_process(
        COMMAND /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${bundle}/Contents/Info.plist"
        RESULT_VARIABLE identity_result
        OUTPUT_VARIABLE bundle_identity
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(NOT identity_result EQUAL 0 OR NOT bundle_identity STREQUAL "com.zerionlito.pomodorotodo")
        message(FATAL_ERROR "应用包身份不符或无法读取，拒绝部署：${bundle}")
    endif()
endfunction()

function(pomodoro_todo_deploy_local_app)
    foreach(required_variable SOURCE_APP DESTINATION_APP BUNDLE_EXECUTABLE)
        if(NOT DEFINED ${required_variable} OR "${${required_variable}}" STREQUAL "")
            message(FATAL_ERROR "部署参数 ${required_variable} 未设置")
        endif()
    endforeach()

    get_filename_component(source_app "${SOURCE_APP}" ABSOLUTE)
    get_filename_component(destination_app "${DESTINATION_APP}" ABSOLUTE)
    get_filename_component(destination_parent "${destination_app}" DIRECTORY)

    if(NOT IS_DIRECTORY "${source_app}")
        message(FATAL_ERROR "待部署应用包不存在：${source_app}")
    endif()
    if(NOT destination_app MATCHES "\\.app$")
        message(FATAL_ERROR "部署目标必须是 .app 应用包：${destination_app}")
    endif()
    if(destination_parent STREQUAL "" OR destination_parent STREQUAL "/")
        message(FATAL_ERROR "拒绝在根目录直接切换应用包：${destination_app}")
    endif()
    if(NOT IS_DIRECTORY "${destination_parent}")
        message(FATAL_ERROR "部署目录不存在：${destination_parent}")
    endif()
    if(IS_SYMLINK "${destination_app}")
        message(FATAL_ERROR "部署目标不能是符号链接：${destination_app}")
    endif()
    get_filename_component(source_real "${source_app}" REALPATH)
    get_filename_component(destination_real "${destination_app}" REALPATH)
    if(source_real STREQUAL destination_real)
        message(FATAL_ERROR "部署源和目标不能是同一个应用包")
    endif()
    pomodoro_todo_check_bundle_identity("${source_app}")
    if(EXISTS "${destination_app}")
        pomodoro_todo_check_bundle_identity("${destination_app}")
    endif()

    string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef deploy_token)
    set(staging_app "${destination_app}.staging-${deploy_token}")
    set(previous_app "${destination_app}.previous-${deploy_token}")
    if(EXISTS "${staging_app}" OR EXISTS "${previous_app}")
        message(FATAL_ERROR "部署临时路径冲突，请重试")
    endif()

    # 先在目标文件系统中完整复制新包。复制失败时，旧应用仍在原位。
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${source_app}" "${staging_app}"
        RESULT_VARIABLE copy_result
    )
    if(NOT copy_result EQUAL 0)
        execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_app}")
        message(FATAL_ERROR "复制新应用包失败，旧应用未改动")
    endif()

    # 复制期间源包可能被其它构建替换，移动旧包前再核对实际暂存内容。
    execute_process(
        COMMAND /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${staging_app}/Contents/Info.plist"
        RESULT_VARIABLE staging_identity_result
        OUTPUT_VARIABLE staging_identity
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(NOT staging_identity_result EQUAL 0 OR NOT staging_identity STREQUAL "com.zerionlito.pomodorotodo")
        execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_app}")
        message(FATAL_ERROR "暂存应用包身份不符或无法读取，旧应用未改动")
    endif()

    set(staging_executable "${staging_app}/Contents/MacOS/${BUNDLE_EXECUTABLE}")
    if(NOT EXISTS "${staging_executable}" OR IS_DIRECTORY "${staging_executable}")
        execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_app}")
        message(FATAL_ERROR "新应用包缺少主二进制，旧应用未改动：${staging_executable}")
    endif()

    # 主程序、MCP helper 和备份执行器必须一起交付；在挪走旧包以前逐项验证存在且可执行。
    set(required_executables "${BUNDLE_EXECUTABLE}")
    if(DEFINED HELPER_EXECUTABLE)
        list(APPEND required_executables "${HELPER_EXECUTABLE}")
    endif()
    if(DEFINED BACKUP_EXECUTOR)
        list(APPEND required_executables "${BACKUP_EXECUTOR}")
    endif()
    foreach(executable IN LISTS required_executables)
        set(candidate "${staging_app}/Contents/MacOS/${executable}")
        execute_process(COMMAND /bin/test -f "${candidate}" RESULT_VARIABLE file_result)
        execute_process(COMMAND /bin/test -x "${candidate}" RESULT_VARIABLE executable_result)
        if(NOT file_result EQUAL 0 OR NOT executable_result EQUAL 0)
            execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_app}")
            message(FATAL_ERROR "新应用包缺少可执行文件，旧应用未改动：${candidate}")
        endif()
    endforeach()

    set(had_previous_app FALSE)
    if(EXISTS "${destination_app}")
        execute_process(
            COMMAND "${CMAKE_COMMAND}" -E rename "${destination_app}" "${previous_app}"
            RESULT_VARIABLE preserve_result
        )
        if(NOT preserve_result EQUAL 0)
            execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_app}")
            message(FATAL_ERROR "无法保留旧应用，已取消部署")
        endif()
        set(had_previous_app TRUE)
    endif()

    # 同一文件系统内的 rename 是原子切换；若切换失败，立即把旧包放回原位。
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E rename "${staging_app}" "${destination_app}"
        RESULT_VARIABLE activate_result
    )
    if(NOT activate_result EQUAL 0)
        if(had_previous_app)
            execute_process(
                COMMAND "${CMAKE_COMMAND}" -E rename "${previous_app}" "${destination_app}"
                RESULT_VARIABLE rollback_result
            )
            if(NOT rollback_result EQUAL 0)
                message(FATAL_ERROR
                    "新应用切换失败，且自动回滚失败；旧包仍保存在 ${previous_app}")
            endif()
        endif()
        execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_app}")
        message(FATAL_ERROR "新应用切换失败，已恢复旧应用")
    endif()

    if(had_previous_app)
        execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${previous_app}")
    endif()

    if(DEFINED LSREGISTER AND EXISTS "${LSREGISTER}")
        # 临时构建包可能从未注册，撤销失败不影响已完成的原子部署。
        execute_process(
            COMMAND "${LSREGISTER}" -u "${source_app}"
            OUTPUT_QUIET ERROR_QUIET
        )
        execute_process(
            COMMAND "${LSREGISTER}" -f "${destination_app}"
            RESULT_VARIABLE register_result
        )
        if(NOT register_result EQUAL 0)
            message(FATAL_ERROR "应用已部署，但 LaunchServices 索引刷新失败")
        endif()
    endif()

    message(STATUS "已部署到 ${destination_app}")
endfunction()

pomodoro_todo_deploy_local_app()

cmake_minimum_required(VERSION 3.16)

# 本机部署：把新构建的应用包切换到固定启动入口（默认 /Applications/番茄Todo.app）。
# 顺序固定为：复制到同目录的暂存包 → 校验主程序与辅助程序 → 旧包改名备份 → rename 换上新包
# → 删除备份并用 lsregister 刷新 LaunchServices（macOS 记录应用位置与打开方式的系统索引）。
# 不得改成「先删旧包再复制新包」：中途失败会让用户既没有旧包也没有新包。
# DeployLocalAppTests 用伪应用包验证新包不完整时旧包原样保留，改这里后必须让它通过。

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

    set(staging_executable "${staging_app}/Contents/MacOS/${BUNDLE_EXECUTABLE}")
    if(NOT EXISTS "${staging_executable}" OR IS_DIRECTORY "${staging_executable}")
        execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_app}")
        message(FATAL_ERROR "新应用包缺少主二进制，旧应用未改动：${staging_executable}")
    endif()

    # 辅助程序与主程序必须一起交付；在挪走旧包以前验证两者存在且可执行。
    set(required_executables "${BUNDLE_EXECUTABLE}")
    if(DEFINED HELPER_EXECUTABLE)
        list(APPEND required_executables "${HELPER_EXECUTABLE}")
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

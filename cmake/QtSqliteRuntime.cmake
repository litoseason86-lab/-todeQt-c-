# 061固定官方驱动源码和Qt私有ABI，只让应用自己的插件与备份连接共用系统SQLite。
# 下载缓存属于构建输入，放在仓库忽略目录；不改SDK插件，不把源码或日志塞进构建目录。
if(NOT Qt6_VERSION VERSION_EQUAL "6.10.3")
    message(FATAL_ERROR "应用SQLite驱动固定为Qt 6.10.3，请先更新同源驱动与锁回归再更换SDK")
endif()
# 私有ABI已由上面的精确版本约束锁定，不重复输出Qt的通用版本不兼容提示。
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Qt6 6.10.3 EXACT REQUIRED COMPONENTS CorePrivate SqlPrivate)
set(pt_sqlite_cache "${CMAKE_SOURCE_DIR}/.cache/qt-sqlite-6.10.3")
set(pt_sqlite_archive "${pt_sqlite_cache}/qtbase.tar.xz")
set(pt_sqlite_archive_hash "383dc907816338f0cba72088a524c07458dfc69ce684ca9132fcc4fe91c24b0b")
file(MAKE_DIRECTORY "${pt_sqlite_cache}")
file(DOWNLOAD
    "https://download.qt.io/official_releases/qt/6.10/6.10.3/submodules/qtbase-everywhere-src-6.10.3.tar.xz"
    "${pt_sqlite_archive}"
    EXPECTED_HASH "SHA256=${pt_sqlite_archive_hash}"
    TLS_VERIFY ON STATUS pt_sqlite_download_status)
list(GET pt_sqlite_download_status 0 pt_sqlite_download_code)
if(NOT pt_sqlite_download_code EQUAL 0)
    message(FATAL_ERROR "无法取得固定Qt SQLite驱动源码：${pt_sqlite_download_status}")
endif()
set(pt_sqlite_source_root "${pt_sqlite_cache}/qtbase-everywhere-src-6.10.3")
set(pt_sqlite_driver_source "${pt_sqlite_source_root}/src/plugins/sqldrivers/sqlite")
# 每次配置从已校验归档恢复官方文件，避免缓存中的手改文件变成交付输入。
execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${pt_sqlite_archive}" --
    qtbase-everywhere-src-6.10.3/src/plugins/sqldrivers/sqlite
    qtbase-everywhere-src-6.10.3/LICENSES
    WORKING_DIRECTORY "${pt_sqlite_cache}" RESULT_VARIABLE pt_sqlite_extract_code)
if(NOT pt_sqlite_extract_code EQUAL 0)
    message(FATAL_ERROR "无法展开固定Qt SQLite驱动源码")
endif()

# 只编译官方驱动适配代码，不编译其中的sqlite3.c。独立MODULE直接继承应用架构，
# 避免Qt内部通用驱动构建对系统库目标的Intel降级逻辑，也不改SDK构建脚本。
add_library(PTSqliteDriver MODULE
    "${pt_sqlite_driver_source}/qsql_sqlite.cpp"
    "${pt_sqlite_driver_source}/qsql_sqlite_p.h"
    "${pt_sqlite_driver_source}/qsql_sqlite_vfs.cpp"
    "${pt_sqlite_driver_source}/qsql_sqlite_vfs_p.h"
    "${pt_sqlite_driver_source}/smain.cpp")
target_link_libraries(PTSqliteDriver PRIVATE Qt6::CorePrivate Qt6::SqlPrivate
    Qt6::PlatformPluginInternal SQLite::SQLite3)
target_compile_definitions(PTSqliteDriver PRIVATE QT_PLUGIN QT_NO_CAST_FROM_ASCII
    QT_NO_CAST_TO_ASCII QT_NO_CONTEXTLESS_CONNECT)
set_target_properties(PTSqliteDriver PROPERTIES OUTPUT_NAME ptqsqlite SUFFIX ".dylib"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/pt-sqlite/sqldrivers")
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/pt-sqlite/source.json" CONTENT
    "{\n  \"qt_version\": \"6.10.3\",\n  \"sqlite_runtime\": \"system\",\n  \"source_url\": \"https://download.qt.io/official_releases/qt/6.10/6.10.3/submodules/qtbase-everywhere-src-6.10.3.tar.xz\",\n  \"archive_sha256\": \"${pt_sqlite_archive_hash}\"\n}\n")

add_library(PTMacSqliteRuntime STATIC
    "${CMAKE_SOURCE_DIR}/src/platform/macos/SqliteRuntime.h"
    "${CMAKE_SOURCE_DIR}/src/platform/macos/SqliteRuntime.cpp")
target_include_directories(PTMacSqliteRuntime PUBLIC "${CMAKE_SOURCE_DIR}/src")
target_link_libraries(PTMacSqliteRuntime PUBLIC Qt6::Core Qt6::Sql)

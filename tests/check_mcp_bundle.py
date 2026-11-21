#!/usr/bin/env python3
"""在非构建工作目录、干净环境下验证包内辅助程序；核对全部 10 个精确工具契约与包内运行时完整性。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

EXPECTED_MCP_TOOLS = {
    "pomodoro_get_status": set(),
    "pomodoro_list_categories": set(),
    "pomodoro_list_tasks": {"completion_state", "end_date", "limit", "start_date"},
    "pomodoro_get_task": {"task_id"},
    "pomodoro_get_focus_summary": {"end_date", "start_date"},
    "pomodoro_list_knowledge_gaps": {"after_id", "category_id", "due_from", "due_state", "due_to", "limit", "search_text", "status"},
    "pomodoro_create_task": {"app_session_id", "category_id", "date", "estimated_minutes", "idempotency_key", "notes", "title"},
    "pomodoro_update_task": {"app_session_id", "category_id", "estimated_minutes", "expected_state_token", "notes", "task_id", "title"},
    "pomodoro_reschedule_task": {"app_session_id", "date", "expected_state_token", "task_id"},
    "pomodoro_set_task_completed": {"app_session_id", "completed", "expected_state_token", "task_id"},
}

args = [a for a in sys.argv[1:] if a != "--expect-bundle"]
expect_bundle = "--expect-bundle" in sys.argv[1:]
assert len(args) == 1, f"用法: check_mcp_bundle.py [--expect-bundle] <helper-path>"
helper = Path(args[0]).resolve()
assert helper.is_file() and os.access(helper, os.X_OK), helper

# 若传入 --expect-bundle 或 helper 位于 .app 包路径下，强制核对 Info.plist、备份执行器与自建 SQLite 驱动插件均随包到位。
in_app_bundle = expect_bundle or any(part.endswith(".app") for part in helper.parts)
if in_app_bundle:
    assert helper.parent.name == "MacOS", f"包内辅助程序必须位于 Contents/MacOS 下: {helper}"
    contents_dir = helper.parent.parent
    info_plist = contents_dir / "Info.plist"
    assert info_plist.is_file(), f"应用包缺少 Contents/Info.plist: {info_plist}"
    backup_executor = helper.parent / "PomodoroTodoBackupExecutor"
    assert backup_executor.is_file() and os.access(backup_executor, os.X_OK), f"包内缺少可执行备份执行器: {backup_executor}"
    sqlite_plugin = contents_dir / "PlugIns" / "sqldrivers" / "libptqsqlite.dylib"
    assert sqlite_plugin.is_file() and sqlite_plugin.stat().st_size > 0, f"包内缺少内置 SQLite 插件: {sqlite_plugin}"

clean_env = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"}
for san_key in ("ASAN_OPTIONS", "UBSAN_OPTIONS"):
    if san_key in os.environ:
        clean_env[san_key] = os.environ[san_key]

for version in ("2025-11-25", "2025-06-18"):
    frames = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "bundle-smoke", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]
    with tempfile.TemporaryDirectory(prefix="mcp-bundle-") as directory:
        result = subprocess.run([str(helper)], cwd=directory, env=clean_env,
                                input="".join(json.dumps(frame) + "\n" for frame in frames),
                                capture_output=True, text=True, timeout=10, check=True)
    replies = {reply["id"]: reply for reply in map(json.loads, result.stdout.splitlines())}
    assert replies[1]["result"]["protocolVersion"] == version
    tools = replies[2]["result"]["tools"]
    assert len(tools) == len(EXPECTED_MCP_TOOLS), f"期望 {len(EXPECTED_MCP_TOOLS)} 个工具，实际 {len(tools)}"
    by_name = {t["name"]: t for t in tools}
    assert set(by_name) == set(EXPECTED_MCP_TOOLS), f"MCP 工具名单偏离：{set(by_name) ^ set(EXPECTED_MCP_TOOLS)}"
    for name, expected_props in EXPECTED_MCP_TOOLS.items():
        tool = by_name[name]
        assert isinstance(tool.get("description"), str) and tool["description"].strip(), name
        schema = tool.get("inputSchema")
        assert isinstance(schema, dict) and schema.get("type") == "object", name
        props = schema.get("properties")
        assert isinstance(props, dict) and set(props.keys()) == expected_props, f"{name}: {props}"
        out_schema = tool.get("outputSchema")
        assert isinstance(out_schema, dict) and out_schema.get("type") == "object" and "$schema" not in out_schema, f"{name} outputSchema: {out_schema}"
    assert not result.stderr, result.stderr
print("包内辅助程序：干净环境、非构建目录、10 个精确工具 schema 与包内运行时组件通过")

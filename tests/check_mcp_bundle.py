#!/usr/bin/env python3
"""在非构建工作目录、干净环境下验证包内辅助程序；仅发现工具，绝不连接业务端点。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helper = Path(sys.argv[1]).resolve()
assert helper.is_file() and os.access(helper, os.X_OK), helper
for version in ("2025-11-25", "2025-06-18"):
    frames = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "bundle-smoke", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]
    with tempfile.TemporaryDirectory(prefix="mcp-bundle-") as directory:
        result = subprocess.run([str(helper)], cwd=directory, env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"},
                                input="".join(json.dumps(frame) + "\n" for frame in frames),
                                capture_output=True, text=True, timeout=10, check=True)
    replies = {reply["id"]: reply for reply in map(json.loads, result.stdout.splitlines())}
    assert replies[1]["result"]["protocolVersion"] == version
    assert len(replies[2]["result"]["tools"]) == 10
    assert not result.stderr, result.stderr
print("包内辅助程序：干净环境、非构建目录、两个协议版本发现 10 工具通过")

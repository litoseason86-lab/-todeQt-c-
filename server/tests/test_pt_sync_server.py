#!/usr/bin/env python3
"""同步中转服务器的进程内与子进程测试。"""

import contextlib
import hashlib
import http.client
import io
import json
import os
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import tracemalloc
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock


ROOT_DIRECTORY = Path(__file__).resolve().parents[2]
SERVER_DIRECTORY = ROOT_DIRECTORY / "server"
SERVER_SCRIPT = SERVER_DIRECTORY / "pt_sync_server.py"
sys.path.insert(0, str(SERVER_DIRECTORY))

import pt_sync_server  # noqa: E402


class ServerTestCase(unittest.TestCase):
    """每个用例独占状态目录和服务器实例，避免测试间共享 rev 与临时文件。"""

    enroll_secret = "enroll-secret-for-tests-only"
    access_token = "access-token-for-tests-only"
    space_id = "space-1234567890abcd"

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="pt-sync-server-test-"
        )
        self.state_directory = Path(self.temporary_directory.name) / "state"
        self.enroll_hash_file = (
            Path(self.temporary_directory.name) / "enroll.sha256"
        )
        self.enroll_hash_file.write_text(
            hashlib.sha256(self.enroll_secret.encode("utf-8")).hexdigest(),
            encoding="utf-8",
        )
        self.access_log = []
        self.server = None
        self.server_thread = None
        self._start_server()

    def tearDown(self):
        self._stop_server()
        self.temporary_directory.cleanup()

    def _start_server(self):
        self.server = pt_sync_server.create_server(
            "127.0.0.1",
            0,
            self.state_directory,
            self.enroll_hash_file,
            max_spaces=1,
            max_file_bytes=200,
            max_space_bytes=300,
            access_log=self.access_log.append,
        )
        self.server_thread = threading.Thread(
            target=self.server.serve_forever,
            name="pt-sync-test-server",
            daemon=True,
        )
        self.server_thread.start()

    def _stop_server(self):
        if self.server is None:
            return
        self.server.store.wake_all()
        self.server.shutdown()
        self.server.server_close()
        if self.server_thread is not None:
            self.server_thread.join(1.0)
        self.server = None
        self.server_thread = None

    @property
    def port(self):
        return self.server.server_address[1]

    def request(self, method, path, body=None, headers=None, timeout=5.0):
        request_headers = {}
        if headers is not None:
            request_headers.update(headers)
        if isinstance(body, (dict, list)):
            body = json.dumps(
                body, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
            request_headers.setdefault("Content-Type", "application/json")
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.port, timeout=timeout
        )
        try:
            connection.request(method, path, body=body, headers=request_headers)
            response = connection.getresponse()
            content = response.read()
            response_headers = {
                key.lower(): value for key, value in response.getheaders()
            }
            return response.status, content, response_headers
        finally:
            connection.close()

    def create_space(self, space=None, token_hash=None, enroll=None):
        target_space = self.space_id if space is None else space
        target_hash = (
            hashlib.sha256(self.access_token.encode("utf-8")).hexdigest()
            if token_hash is None
            else token_hash
        )
        headers = {}
        if enroll is not False:
            headers["X-PT-Enroll"] = (
                self.enroll_secret if enroll is None else enroll
            )
        body = {"space": target_space, "tokenSha256": target_hash}
        return self.request("POST", "/v1/spaces", body, headers)

    def authorization_headers(self, token=None):
        value = self.access_token if token is None else token
        return {"Authorization": "Bearer " + value}

    def decode_json(self, response):
        return json.loads(response[1].decode("utf-8"))

    def test_create_space_validation(self):
        """保证建空间只接受正确口令、合法编号和合法令牌哈希，并执行空间数量上限。"""

        short_space = self.create_space(space="short")
        self.assertEqual(short_space[0], 400)
        self.assertEqual(self.decode_json(short_space), {"error": "bad_space"})

        bad_hash = self.create_space(token_hash="g" * 64)
        self.assertEqual(bad_hash[0], 400)
        self.assertEqual(self.decode_json(bad_hash), {"error": "bad_request"})

        malformed_json = self.request(
            "POST",
            "/v1/spaces",
            b"{",
            {"X-PT-Enroll": self.enroll_secret},
        )
        self.assertEqual(malformed_json[0], 400)
        self.assertEqual(self.decode_json(malformed_json), {"error": "bad_request"})

        wrong_enroll = self.create_space(enroll="wrong-enroll-secret")
        self.assertEqual(wrong_enroll[0], 403)
        self.assertEqual(self.decode_json(wrong_enroll), {"error": "forbidden"})

        missing_enroll = self.create_space(enroll=False)
        self.assertEqual(missing_enroll[0], 403)
        self.assertEqual(self.decode_json(missing_enroll), {"error": "forbidden"})

        success = self.create_space(
            token_hash=hashlib.sha256(
                self.access_token.encode("utf-8")
            ).hexdigest().upper()
        )
        self.assertEqual(success[0], 201)
        response_json = self.decode_json(success)
        self.assertEqual(response_json, {"space": self.space_id, "rev": 0})

        duplicate = self.create_space()
        self.assertEqual(duplicate[0], 409)
        self.assertEqual(self.decode_json(duplicate), {"error": "space_exists"})

        another_space = self.create_space(space="space-1234567890abce")
        self.assertEqual(another_space[0], 507)
        self.assertEqual(self.decode_json(another_space), {"error": "space_limit"})

        missing_length = http.client.HTTPConnection(
            "127.0.0.1", self.port, timeout=5.0
        )
        try:
            missing_length.putrequest("POST", "/v1/spaces")
            missing_length.putheader("X-PT-Enroll", self.enroll_secret)
            missing_length.endheaders()
            response = missing_length.getresponse()
            content = response.read()
            self.assertEqual(response.status, 411)
            self.assertEqual(
                json.loads(content.decode("utf-8")),
                {"error": "length_required"},
            )
        finally:
            missing_length.close()

    def test_authentication_checks_space_before_token(self):
        """保证不存在的空间优先返回 404，且已有空间只接受正确的 Bearer 令牌。"""

        missing_space = self.request(
            "GET", "/v1/spaces/space-1234567890abcf/tree"
        )
        self.assertEqual(missing_space[0], 404)
        self.assertEqual(
            self.decode_json(missing_space), {"error": "space_not_found"}
        )

        self.assertEqual(self.create_space()[0], 201)

        missing_token = self.request(
            "GET", "/v1/spaces/%s/tree" % self.space_id
        )
        self.assertEqual(missing_token[0], 401)
        self.assertEqual(
            self.decode_json(missing_token), {"error": "unauthorized"}
        )

        wrong_token = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers=self.authorization_headers("wrong-token"),
        )
        self.assertEqual(wrong_token[0], 401)
        self.assertEqual(self.decode_json(wrong_token), {"error": "unauthorized"})

        basic_token = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers={"Authorization": "Basic abc"},
        )
        self.assertEqual(basic_token[0], 401)

        valid_token = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers=self.authorization_headers(),
        )
        self.assertEqual(valid_token[0], 200)

    def test_file_lifecycle_and_tree(self):
        """保证文件覆盖写、删除与树清单遵守同一空间的 rev 和目录语义。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        deep_path = "/v1/spaces/%s/files/devices/dev/cursor.json" % self.space_id

        first_write = self.request(
            "PUT", deep_path, b'{"cursor":1}', common_headers
        )
        self.assertEqual(first_write[0], 200)
        first_rev = self.decode_json(first_write)["rev"]

        read_back = self.request("GET", deep_path, headers=common_headers)
        self.assertEqual(read_back[0], 200)
        self.assertEqual(read_back[1], b'{"cursor":1}')
        self.assertEqual(read_back[2]["content-type"], "application/octet-stream")

        overwrite = self.request(
            "PUT", deep_path, b'{"cursor":2}', common_headers
        )
        self.assertEqual(overwrite[0], 200)
        overwrite_rev = self.decode_json(overwrite)["rev"]
        self.assertEqual(overwrite_rev, first_rev + 1)

        read_overwrite = self.request("GET", deep_path, headers=common_headers)
        self.assertEqual(read_overwrite[1], b'{"cursor":2}')

        tree_response = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers=common_headers,
        )
        self.assertEqual(tree_response[0], 200)
        tree_json = self.decode_json(tree_response)
        self.assertEqual(tree_json["rev"], overwrite_rev)
        entries = {entry["path"]: entry for entry in tree_json["entries"]}
        self.assertEqual(entries["devices"]["type"], "dir")
        self.assertEqual(entries["devices/dev"]["type"], "dir")
        self.assertEqual(entries["devices/dev/cursor.json"]["type"], "file")
        self.assertEqual(entries["devices/dev/cursor.json"]["size"], 12)

        missing_delete_path = (
            "/v1/spaces/%s/files/devices/dev/missing.json" % self.space_id
        )
        missing_delete = self.request(
            "DELETE", missing_delete_path, headers=common_headers
        )
        self.assertEqual(missing_delete[0], 200)
        self.assertEqual(self.decode_json(missing_delete)["rev"], overwrite_rev)

        actual_delete = self.request(
            "DELETE", deep_path, headers=common_headers
        )
        self.assertEqual(actual_delete[0], 200)
        self.assertEqual(
            self.decode_json(actual_delete)["rev"], overwrite_rev + 1
        )

        missing_read = self.request("GET", deep_path, headers=common_headers)
        self.assertEqual(missing_read[0], 404)
        self.assertEqual(
            self.decode_json(missing_read), {"error": "file_not_found"}
        )

        tree_after_delete = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers=common_headers,
        )
        empty_directories = {
            entry["path"]: entry
            for entry in self.decode_json(tree_after_delete)["entries"]
        }
        self.assertEqual(empty_directories["devices"]["type"], "dir")
        self.assertEqual(empty_directories["devices/dev"]["type"], "dir")
        self.assertNotIn("devices/dev/cursor.json", empty_directories)

    def test_utf8_path_and_path_rejections(self):
        """保证中文同步文件名可原样保存，同时拒绝穿越、非法段和外部符号链接。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        chinese_name = "番茄Todo同步.json"
        encoded_name = urllib.parse.quote(chinese_name, safe="")
        chinese_url = "/v1/spaces/%s/files/%s" % (
            self.space_id,
            encoded_name,
        )

        write_chinese = self.request(
            "PUT", chinese_url, b"marker", common_headers
        )
        self.assertEqual(write_chinese[0], 200)
        read_chinese = self.request("GET", chinese_url, headers=common_headers)
        self.assertEqual(read_chinese[0], 200)
        self.assertEqual(read_chinese[1], b"marker")

        tree_response = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers=common_headers,
        )
        paths = [
            entry["path"]
            for entry in self.decode_json(tree_response)["entries"]
        ]
        self.assertIn(chinese_name, paths)

        invalid_paths = [
            "..",
            ".",
            "a//b",
            "/absolute",
            "trailing/",
            "a\\b",
            "x" * 129,
            "one/two/three/four/five",
            ".pt-tmp-file",
            "%2e%2e",
        ]
        for invalid_path in invalid_paths:
            with self.subTest(path=invalid_path):
                if invalid_path == "%2e%2e":
                    url_path = invalid_path
                else:
                    url_path = urllib.parse.quote(invalid_path, safe="/\\.%")
                response = self.request(
                    "PUT",
                    "/v1/spaces/%s/files/%s" % (self.space_id, url_path),
                    b"x",
                    common_headers,
                )
                self.assertEqual(response[0], 400)
                self.assertEqual(
                    self.decode_json(response), {"error": "bad_path"}
                )

        outside_directory = Path(self.temporary_directory.name) / "outside"
        outside_directory.mkdir()
        files_directory = Path(
            self.server.store.files_directory(self.space_id)
        )
        os.symlink(str(outside_directory), str(files_directory / "escape"))
        escaped_write = self.request(
            "PUT",
            "/v1/spaces/%s/files/escape/leak.json" % self.space_id,
            b"leak",
            common_headers,
        )
        self.assertEqual(escaped_write[0], 400)
        self.assertEqual(
            self.decode_json(escaped_write), {"error": "bad_path"}
        )

    def test_upload_limits_preserve_previous_files(self):
        """保证单文件与空间配额超限时，同路径旧文件和已成功写入的文件都不变。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        first_path = "/v1/spaces/%s/files/first.bin" % self.space_id
        second_path = "/v1/spaces/%s/files/second.bin" % self.space_id
        third_path = "/v1/spaces/%s/files/third.bin" % self.space_id

        first_write = self.request(
            "PUT", first_path, b"a" * 100, common_headers
        )
        self.assertEqual(first_write[0], 200)

        oversized_replace = self.request(
            "PUT", first_path, b"b" * 201, common_headers
        )
        self.assertEqual(oversized_replace[0], 413)
        self.assertEqual(
            self.decode_json(oversized_replace), {"error": "file_too_large"}
        )
        old_first = self.request("GET", first_path, headers=common_headers)
        self.assertEqual(old_first[1], b"a" * 100)

        second_write = self.request(
            "PUT", second_path, b"c" * 200, common_headers
        )
        self.assertEqual(second_write[0], 200)

        quota_failure = self.request(
            "PUT", third_path, b"d" * 10, common_headers
        )
        self.assertEqual(quota_failure[0], 507)
        self.assertEqual(
            self.decode_json(quota_failure), {"error": "quota_exceeded"}
        )

        first_after_quota = self.request(
            "GET", first_path, headers=common_headers
        )
        second_after_quota = self.request(
            "GET", second_path, headers=common_headers
        )
        self.assertEqual(first_after_quota[1], b"a" * 100)
        self.assertEqual(second_after_quota[1], b"c" * 200)

    def test_atomic_failure_and_restart_cleanup(self):
        """保证提交点前失败保留旧内容与旧版本、提交点后失败前滚收敛一致，并能跨实例清理残留临时文件。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        path = "/v1/spaces/%s/files/stable.json" % self.space_id
        self.assertEqual(
            self.request("PUT", path, b"old-content", common_headers)[0], 200
        )
        space_directory = Path(
            self.server.store.space_directory(self.space_id)
        )
        files_directory = Path(
            self.server.store.files_directory(self.space_id)
        )
        # macOS 的 /var 是 /private/var 的符号链接；服务器会先 realpath，
        # 测试也必须比较解析后的路径才能精确拦截目标文件替换。
        target_path = Path(os.path.realpath(str(files_directory / "stable.json")))
        real_replace = pt_sync_server.os.replace

        # 阶段 1：提交点 commit.json 落盘前失败，旧文件与旧 rev 必须完好且无残留暂存文件。
        def fail_commit_replace(source, target):
            if Path(str(target)).name == pt_sync_server.COMMIT_FILE_NAME:
                raise OSError("injected commit replace failure")
            return real_replace(source, target)

        with mock.patch.object(
            pt_sync_server.os, "replace", side_effect=fail_commit_replace
        ):
            failed_pre_commit = self.request(
                "PUT", path, b"pre-commit-content", common_headers
            )
        self.assertEqual(failed_pre_commit[0], 500)
        old_read = self.request("GET", path, headers=common_headers)
        self.assertEqual(old_read[1], b"old-content")
        self.assertEqual(
            self.decode_json(
                self.request(
                    "GET",
                    "/v1/spaces/%s/tree" % self.space_id,
                    headers=common_headers,
                )
            )["rev"],
            1,
        )
        self.assertEqual(
            [
                p.name
                for p in space_directory.rglob("*")
                if pt_sync_server.is_ephemeral_name(p.name)
                or p.name == pt_sync_server.COMMIT_FILE_NAME
            ],
            [],
        )

        # 阶段 2：提交点已落盘但目标文件替换失败，下一次访问必须自动前滚到新内容与新 rev。
        def fail_target_replace(source, target):
            if os.path.abspath(str(target)) == os.path.abspath(str(target_path)):
                raise OSError("injected target replace failure")
            return real_replace(source, target)

        with mock.patch.object(
            pt_sync_server.os, "replace", side_effect=fail_target_replace
        ):
            failed_write = self.request(
                "PUT", path, b"new-content", common_headers
            )
        self.assertEqual(failed_write[0], 500)
        rolled_read = self.request("GET", path, headers=common_headers)
        self.assertEqual(rolled_read[1], b"new-content")
        self.assertEqual(
            self.decode_json(
                self.request(
                    "GET",
                    "/v1/spaces/%s/tree" % self.space_id,
                    headers=common_headers,
                )
            )["rev"],
            2,
        )

        # 阶段 3：提交点与目标文件均已落盘但 meta.json 改名失败，后续读取前滚推进 rev 保持一致。
        def fail_metadata_replace(source, target):
            if Path(str(target)).name == pt_sync_server.META_FILE_NAME:
                raise OSError("injected metadata replace failure")
            return real_replace(source, target)

        with mock.patch.object(
            pt_sync_server.os,
            "replace",
            side_effect=fail_metadata_replace,
        ):
            failed_metadata_write = self.request(
                "PUT", path, b"committed-v3-content", common_headers
            )
        self.assertEqual(failed_metadata_write[0], 500)
        content_after_metadata_failure = self.request(
            "GET", path, headers=common_headers
        )
        self.assertEqual(
            content_after_metadata_failure[1], b"committed-v3-content"
        )
        tree_after_metadata_failure = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )
        self.assertEqual(tree_after_metadata_failure["rev"], 3)
        self.assertEqual(
            [
                p.name
                for p in space_directory.rglob("*")
                if pt_sync_server.is_ephemeral_name(p.name)
                or p.name == pt_sync_server.COMMIT_FILE_NAME
            ],
            [],
        )

        rev_before_restart = tree_after_metadata_failure["rev"]
        self._stop_server()
        (files_directory / (pt_sync_server.TEMP_PREFIX + "leftover")).write_bytes(
            b"partial"
        )
        (space_directory / (pt_sync_server.STAGE_PREFIX + "orphan")).write_bytes(
            b"orphan-stage"
        )
        self._start_server()
        self.assertFalse(
            (files_directory / (pt_sync_server.TEMP_PREFIX + "leftover")).exists()
        )
        self.assertFalse(
            (space_directory / (pt_sync_server.STAGE_PREFIX + "orphan")).exists()
        )
        tree_after_restart = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers=common_headers,
        )
        self.assertEqual(
            self.decode_json(tree_after_restart)["rev"], rev_before_restart
        )

    def test_watch_immediate_change_timeout_and_validation(self):
        """保证 watch 既能看到 rev 回退，也会在写入后及时唤醒并按期限超时。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        watch_path = "/v1/spaces/%s/watch" % self.space_id
        file_path = "/v1/spaces/%s/files/watch.json" % self.space_id

        immediate = self.request(
            "GET", watch_path + "?rev=999&timeout=0", headers=common_headers
        )
        self.assertEqual(immediate[0], 200)
        self.assertEqual(self.decode_json(immediate)["rev"], 0)

        writer_errors = []

        def delayed_write():
            try:
                # 这个延迟只负责让 watch 先进入等待；结果仍靠请求返回和
                # 2 秒截止时间判断，不把固定 sleep 当成同步成功的证据。
                time.sleep(0.3)
                response = self.request(
                    "PUT", file_path, b"change", common_headers
                )
                if response[0] != 200:
                    writer_errors.append(response)
            except Exception as exc:  # pragma: no cover - 失败时由断言报告
                writer_errors.append(exc)

        writer = threading.Thread(target=delayed_write, daemon=True)
        writer.start()
        started = time.monotonic()
        changed = self.request(
            "GET", watch_path + "?rev=0&timeout=2", headers=common_headers
        )
        elapsed = time.monotonic() - started
        writer.join(1.0)
        self.assertEqual(writer_errors, [])
        self.assertEqual(changed[0], 200)
        self.assertEqual(self.decode_json(changed)["rev"], 1)
        self.assertLess(elapsed, 1.0)

        started = time.monotonic()
        unchanged = self.request(
            "GET", watch_path + "?rev=1&timeout=1", headers=common_headers
        )
        elapsed = time.monotonic() - started
        self.assertEqual(unchanged[0], 200)
        self.assertEqual(self.decode_json(unchanged)["rev"], 1)
        self.assertGreaterEqual(elapsed, 0.9)
        self.assertLessEqual(elapsed, 2.5)

        invalid_queries = [
            "?rev=1&timeout=not-a-number",
            "?rev=1&timeout=",
            "?rev=1&timeout=-1",
            "?rev=1&timeout=26",
            "?rev=not-a-number&timeout=0",
            "?timeout=0",
        ]
        for query in invalid_queries:
            with self.subTest(query=query):
                response = self.request(
                    "GET", watch_path + query, headers=common_headers
                )
                self.assertEqual(response[0], 400)
                self.assertEqual(
                    self.decode_json(response), {"error": "bad_request"}
                )

    def test_access_log_redacts_headers_body_and_query(self):
        """保证访问日志只保留方法、去查询串路径和状态码，不泄露秘密或请求体。"""

        self.access_log[:] = []
        token_hash = hashlib.sha256(
            self.access_token.encode("utf-8")
        ).hexdigest()
        create_response = self.create_space(token_hash=token_hash)
        self.assertEqual(create_response[0], 201)

        tree_query = (
            "/v1/spaces/%s/tree?leak=%s"
            % (self.space_id, urllib.parse.quote(self.access_token, safe=""))
        )
        tree_response = self.request(
            "GET", tree_query, headers=self.authorization_headers()
        )
        self.assertEqual(tree_response[0], 200)

        combined_log = "\n".join(self.access_log)
        self.assertNotIn(self.access_token, combined_log)
        self.assertNotIn(self.enroll_secret, combined_log)
        self.assertNotIn(token_hash, combined_log)
        self.assertNotIn("?leak=", combined_log)
        for line in self.access_log:
            if line.startswith("PT_SYNC_INTERNAL"):
                continue
            parts = line.split(" ")
            self.assertEqual(len(parts), 4)
            self.assertEqual(parts[0], "PT_SYNC")
            self.assertIn(parts[1], ("POST", "GET"))
            self.assertTrue(parts[2].startswith("/v1/"))

    def test_management_commands_list_and_delete(self):
        """保证管理命令能列出空间并从状态目录删除指定空间，不存在时返回失败。"""

        self.assertEqual(self.create_space()[0], 201)
        space_directory = (
            self.state_directory / "spaces" / self.space_id
        )
        self._stop_server()

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = pt_sync_server.main(
                ["list-spaces", "--state-dir", str(self.state_directory)]
            )
        self.assertEqual(result, 0)
        listed = output.getvalue().strip().split("\t")
        self.assertEqual(listed[0], self.space_id)
        self.assertEqual(listed[1], "0")
        self.assertEqual(listed[2], "0")
        self.assertEqual(listed[3], "0")

        with contextlib.redirect_stdout(io.StringIO()):
            result = pt_sync_server.main(
                [
                    "delete-space",
                    "--state-dir",
                    str(self.state_directory),
                    "--space",
                    self.space_id,
                ]
            )
        self.assertEqual(result, 0)
        self.assertFalse(space_directory.exists())

        with contextlib.redirect_stderr(io.StringIO()):
            missing_result = pt_sync_server.main(
                [
                    "delete-space",
                    "--state-dir",
                    str(self.state_directory),
                    "--space",
                    self.space_id,
                ]
            )
        self.assertNotEqual(missing_result, 0)

    def test_subprocess_readiness_http_round_trip_and_sigterm(self):
        """保证独立进程会报告实际端口，能完成建空间与文件读写，并在 SIGTERM 后正常退出。"""

        with tempfile.TemporaryDirectory(
            prefix="pt-sync-server-subprocess-test-"
        ) as temporary_name:
            state_directory = Path(temporary_name) / "state"
            enroll_hash_file = Path(temporary_name) / "enroll.sha256"
            enroll_hash_file.write_text(
                hashlib.sha256(self.enroll_secret.encode("utf-8")).hexdigest(),
                encoding="utf-8",
            )
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-I",
                    str(SERVER_SCRIPT),
                    "serve",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    "0",
                    "--state-dir",
                    str(state_directory),
                    "--enroll-hash-file",
                    str(enroll_hash_file),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            ready_queue = queue.Queue()

            def read_stdout():
                for line in process.stdout:
                    ready_queue.put(line.strip())

            stdout_reader = threading.Thread(target=read_stdout, daemon=True)
            stdout_reader.start()
            try:
                ready_line = ready_queue.get(timeout=5.0)
                prefix = "PT_SYNC_READY "
                self.assertTrue(ready_line.startswith(prefix))
                port = int(ready_line[len(prefix) :])

                token_hash = hashlib.sha256(
                    self.access_token.encode("utf-8")
                ).hexdigest()
                create_body = json.dumps(
                    {"space": self.space_id, "tokenSha256": token_hash},
                    separators=(",", ":"),
                ).encode("utf-8")
                connection = http.client.HTTPConnection(
                    "127.0.0.1", port, timeout=5.0
                )
                try:
                    connection.request(
                        "POST",
                        "/v1/spaces",
                        body=create_body,
                        headers={
                            "Content-Type": "application/json",
                            "X-PT-Enroll": self.enroll_secret,
                        },
                    )
                    response = connection.getresponse()
                    response.read()
                    self.assertEqual(response.status, 201)
                finally:
                    connection.close()

                connection = http.client.HTTPConnection(
                    "127.0.0.1", port, timeout=5.0
                )
                try:
                    connection.request(
                        "PUT",
                        "/v1/spaces/%s/files/ready.json" % self.space_id,
                        body=b"ready",
                        headers=self.authorization_headers(),
                    )
                    response = connection.getresponse()
                    response.read()
                    self.assertEqual(response.status, 200)

                    connection.request(
                        "GET",
                        "/v1/spaces/%s/files/ready.json" % self.space_id,
                        headers=self.authorization_headers(),
                    )
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), b"ready")
                finally:
                    connection.close()
                # 在挂起长轮询 watch 时连续发送两次 SIGTERM，验证信号处理仅置位事件不死锁且正常退出。
                watch_done = threading.Event()

                def hanging_watch():
                    conn = http.client.HTTPConnection(
                        "127.0.0.1", port, timeout=5.0
                    )
                    try:
                        conn.request(
                            "GET",
                            "/v1/spaces/%s/watch?rev=1&timeout=20"
                            % self.space_id,
                            headers=self.authorization_headers(),
                        )
                        resp = conn.getresponse()
                        resp.read()
                    except Exception:
                        pass
                    finally:
                        conn.close()
                        watch_done.set()

                watcher = threading.Thread(target=hanging_watch, daemon=True)
                watcher.start()
                time.sleep(0.15)
            finally:
                process.send_signal(signal.SIGTERM)
                time.sleep(0.02)
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                try:
                    _stdout, _stderr = process.communicate(timeout=5.0)
                    self.assertEqual(process.returncode, 0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    self.fail("服务器收到连续 SIGTERM 后 5 秒内没有退出")

    def test_concurrent_list_tree_never_returns_new_rev_with_stale_files(self):
        """保证并发写入期间枚举目录树时，绝不会返回新 rev 搭配旧文件列表的撕裂快照。"""

        self.assertEqual(self.create_space()[0], 201)
        initial_rev, initial_entries = self.server.store.list_tree(
            self.space_id
        )
        self.assertEqual(initial_rev, 0)
        self.assertEqual(initial_entries, [])

        files_root = os.path.abspath(
            self.server.store.files_directory(self.space_id)
        )
        scandir_entered = threading.Event()
        writer_finished = threading.Event()
        writer_finished_during_read = [False]
        real_scandir = pt_sync_server.os.scandir
        reader_ident = [None]
        hook_triggered = [False]

        def hooked_scandir(path):
            if (
                threading.get_ident() == reader_ident[0]
                and not hook_triggered[0]
                and os.path.abspath(str(path)) == files_root
            ):
                hook_triggered[0] = True
                # 同步点设在已读完 rev 之后、真正枚举目录之前：
                # 若 list_tree 未持空间锁，写线程会立刻提交新文件并推进 rev，
                # 既会让 writer_finished_during_read 变真，也会让读线程随后枚举出新文件配旧 rev=0。
                scandir_entered.set()
                writer_finished_during_read[0] = writer_finished.wait(
                    timeout=0.15
                )
            return real_scandir(path)

        observed = {}

        def run_list_tree():
            reader_ident[0] = threading.get_ident()
            rev, entries = self.server.store.list_tree(self.space_id)
            observed["rev"] = rev
            observed["entries"] = entries

        def run_write():
            scandir_entered.wait(timeout=2.0)
            self.server.store.write_file(
                self.space_id, "changes/batch-001.bin", b"cipher-1"
            )
            writer_finished.set()

        with mock.patch.object(
            pt_sync_server.os, "scandir", side_effect=hooked_scandir
        ):
            reader = threading.Thread(target=run_list_tree, daemon=True)
            writer = threading.Thread(target=run_write, daemon=True)
            reader.start()
            writer.start()
            reader.join(timeout=3.0)
            writer.join(timeout=3.0)

        self.assertFalse(reader.is_alive())
        self.assertFalse(writer.is_alive())
        self.assertTrue(hook_triggered[0])
        self.assertFalse(
            writer_finished_during_read[0],
            "list_tree 持锁期间写线程不应完成提交",
        )
        file_entries = [
            item["path"]
            for item in observed["entries"]
            if item["type"] == "file"
        ]
        self.assertEqual(observed["rev"], 0)
        self.assertEqual(file_entries, [])

        final_rev, final_entries = self.server.store.list_tree(self.space_id)
        self.assertEqual(final_rev, 1)
        self.assertEqual(
            [item["path"] for item in final_entries if item["type"] == "file"],
            ["changes/batch-001.bin"],
        )

    def test_read_file_never_reads_uncommitted_bytes_before_rollback(self):
        """保证覆写文件在提交点失败前，并发读取绝不会读到未提交的脏字节；提交点后失败也会等锁并前滚一致。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        file_url = "/v1/spaces/%s/files/changes/batch-001.bin" % self.space_id
        self.assertEqual(
            self.request("PUT", file_url, b"committed-v1", common_headers)[0],
            200,
        )
        self.assertEqual(
            self.server.store.read_file(self.space_id, "changes/batch-001.bin"),
            b"committed-v1",
        )

        in_uncommitted_window = threading.Event()
        allow_fail = threading.Event()
        real_atomic_write_json = pt_sync_server.atomic_write_json

        def fail_commit_write(target, value):
            if (
                Path(str(target)).name == pt_sync_server.COMMIT_FILE_NAME
                and isinstance(value, dict)
                and value.get("target_rev") == 2
            ):
                in_uncommitted_window.set()
                allow_fail.wait(timeout=2.0)
                raise OSError("injected commit.json write failure")
            return real_atomic_write_json(target, value)

        writer_status = []
        store_read_results = []
        http_read_results = []

        def failing_writer():
            response = self.request(
                "PUT", file_url, b"UNCOMMITTED-DIRTY-V2", common_headers
            )
            writer_status.append(response[0])

        def concurrent_store_reader():
            store_read_results.append(
                self.server.store.read_file(
                    self.space_id, "changes/batch-001.bin"
                )
            )

        def concurrent_http_reader():
            http_read_results.append(
                self.request("GET", file_url, headers=common_headers)
            )

        with mock.patch.object(
            pt_sync_server, "atomic_write_json", side_effect=fail_commit_write
        ):
            writer = threading.Thread(target=failing_writer, daemon=True)
            writer.start()
            self.assertTrue(in_uncommitted_window.wait(timeout=2.0))

            store_reader = threading.Thread(
                target=concurrent_store_reader, daemon=True
            )
            http_reader = threading.Thread(
                target=concurrent_http_reader, daemon=True
            )
            store_reader.start()
            http_reader.start()
            # 写线程持空间锁期间并发读被阻塞；提交点失败后释放锁，读者只能读到旧版本 v1。
            store_reader.join(timeout=0.15)
            allow_fail.set()

            writer.join(timeout=3.0)
            store_reader.join(timeout=3.0)
            http_reader.join(timeout=3.0)

        self.assertEqual(writer_status, [500])
        self.assertEqual(store_read_results, [b"committed-v1"])
        self.assertEqual(len(http_read_results), 1)
        self.assertEqual(http_read_results[0][0], 200)
        self.assertEqual(http_read_results[0][1], b"committed-v1")
        self.assertEqual(
            self.server.store.read_metadata(self.space_id)["rev"], 1
        )

    def test_delete_file_restores_target_when_meta_write_fails(self):
        """保证删除文件在提交点前失败保留原文件与旧版本，在提交点后失败经前滚收敛为已删除且版本前进。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        file_url = "/v1/spaces/%s/files/devices/keep.bin" % self.space_id
        write_resp = self.request(
            "PUT", file_url, b"important-cipher", common_headers
        )
        self.assertEqual(write_resp[0], 200)
        self.assertEqual(self.decode_json(write_resp)["rev"], 1)

        real_replace = pt_sync_server.os.replace

        # 提交点前失败：文件完整保留，rev 停在 1。
        def fail_commit_replace(source, target):
            if Path(str(target)).name == pt_sync_server.COMMIT_FILE_NAME:
                raise OSError("injected delete commit replace failure")
            return real_replace(source, target)

        with mock.patch.object(
            pt_sync_server.os, "replace", side_effect=fail_commit_replace
        ):
            failed_pre_delete = self.request(
                "DELETE", file_url, headers=common_headers
            )
        self.assertEqual(failed_pre_delete[0], 500)
        preserved_read = self.request("GET", file_url, headers=common_headers)
        self.assertEqual(preserved_read[0], 200)
        self.assertEqual(preserved_read[1], b"important-cipher")
        tree_before = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )
        self.assertEqual(tree_before["rev"], 1)
        self.assertIn(
            "devices/keep.bin",
            {entry["path"] for entry in tree_before["entries"]},
        )

        # 提交点后失败（meta.json 改名失败）：后续访问自动前滚完成删除并推进 rev=2。
        def fail_metadata_replace(source, target):
            if Path(str(target)).name == pt_sync_server.META_FILE_NAME:
                raise OSError("injected delete metadata replace failure")
            return real_replace(source, target)

        with mock.patch.object(
            pt_sync_server.os, "replace", side_effect=fail_metadata_replace
        ):
            failed_delete = self.request(
                "DELETE", file_url, headers=common_headers
            )
        self.assertEqual(failed_delete[0], 500)

        after_rollforward_read = self.request(
            "GET", file_url, headers=common_headers
        )
        self.assertEqual(after_rollforward_read[0], 404)

        tree_resp = self.request(
            "GET",
            "/v1/spaces/%s/tree" % self.space_id,
            headers=common_headers,
        )
        tree_json = self.decode_json(tree_resp)
        self.assertEqual(tree_json["rev"], 2)
        self.assertNotIn(
            "devices/keep.bin",
            {entry["path"] for entry in tree_json["entries"]},
        )

        space_dir = Path(self.server.store.space_directory(self.space_id))
        leftover_files = [
            path.name
            for path in space_dir.rglob("*")
            if pt_sync_server.is_ephemeral_name(path.name)
            or path.name == pt_sync_server.COMMIT_FILE_NAME
        ]
        self.assertEqual(leftover_files, [])

    def test_keepalive_rejects_body_on_get_delete_and_transfer_encoding_and_closes(
        self,
    ):
        """保证 Keep-Alive 连接拒绝带请求体的 GET/DELETE 与任何 Transfer-Encoding 并立即断开，防止请求走私，且配置空闲读超时。"""

        self.assertEqual(self.create_space()[0], 201)
        auth = "Bearer " + self.access_token

        def send_raw_and_collect(raw_bytes):
            with socket.create_connection(
                ("127.0.0.1", self.port), timeout=3.0
            ) as sock:
                sock.sendall(raw_bytes)
                sock.settimeout(0.5)
                chunks = []
                closed_by_peer = False
                while True:
                    try:
                        data = sock.recv(4096)
                    except socket.timeout:
                        break
                    if not data:
                        closed_by_peer = True
                        break
                    chunks.append(data)
            text = b"".join(chunks).decode("utf-8", errors="replace")
            status_lines = [
                line
                for line in text.splitlines()
                if line.startswith("HTTP/1.1 ")
            ]
            return status_lines, closed_by_peer, text

        smuggled_put = (
            "PUT /v1/spaces/%s/files/smuggled.bin HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Authorization: %s\r\n"
            "Content-Length: 5\r\n"
            "\r\n"
            "pwned" % (self.space_id, self.port, auth)
        ).encode("ascii")

        get_with_body = (
            "GET /v1/spaces/%s/tree HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Authorization: %s\r\n"
            "Content-Length: %d\r\n"
            "\r\n" % (self.space_id, self.port, auth, len(smuggled_put))
        ).encode("ascii") + smuggled_put
        status_lines, closed_by_peer, _ = send_raw_and_collect(get_with_body)
        self.assertEqual(len(status_lines), 1, status_lines)
        self.assertTrue(
            status_lines[0].startswith("HTTP/1.1 400 "), status_lines
        )
        self.assertTrue(closed_by_peer)

        delete_with_body = (
            "DELETE /v1/spaces/%s/files/missing.bin HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Authorization: %s\r\n"
            "Content-Length: %d\r\n"
            "\r\n" % (self.space_id, self.port, auth, len(smuggled_put))
        ).encode("ascii") + smuggled_put
        status_lines, closed_by_peer, _ = send_raw_and_collect(delete_with_body)
        self.assertEqual(len(status_lines), 1, status_lines)
        self.assertTrue(
            status_lines[0].startswith("HTTP/1.1 400 "), status_lines
        )
        self.assertTrue(closed_by_peer)

        chunked_request = (
            "GET /v1/spaces/%s/tree HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Authorization: %s\r\n"
            "Transfer-Encoding: chunked\r\n"
            "\r\n"
            "0\r\n\r\n" % (self.space_id, self.port, auth)
        ).encode("ascii") + smuggled_put
        status_lines, closed_by_peer, _ = send_raw_and_collect(chunked_request)
        self.assertEqual(len(status_lines), 1, status_lines)
        self.assertTrue(
            status_lines[0].startswith("HTTP/1.1 400 ")
            or status_lines[0].startswith("HTTP/1.1 501 "),
            status_lines,
        )
        self.assertTrue(closed_by_peer)

        chunked_put = (
            "PUT /v1/spaces/%s/files/chunked.bin HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Authorization: %s\r\n"
            "Transfer-Encoding: chunked\r\n"
            "\r\n"
            "5\r\npwned\r\n0\r\n\r\n" % (self.space_id, self.port, auth)
        ).encode("ascii") + smuggled_put
        status_lines, closed_by_peer, _ = send_raw_and_collect(chunked_put)
        self.assertEqual(len(status_lines), 1, status_lines)
        self.assertTrue(
            status_lines[0].startswith("HTTP/1.1 400 ")
            or status_lines[0].startswith("HTTP/1.1 501 "),
            status_lines,
        )
        self.assertTrue(closed_by_peer)

        invalid_cl_get = (
            "GET /v1/spaces/%s/tree HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\n"
            "Authorization: %s\r\n"
            "Content-Length: invalid\r\n"
            "\r\n" % (self.space_id, self.port, auth)
        ).encode("ascii") + smuggled_put
        status_lines, closed_by_peer, _ = send_raw_and_collect(invalid_cl_get)
        self.assertEqual(len(status_lines), 1, status_lines)
        self.assertTrue(
            status_lines[0].startswith("HTTP/1.1 400 "), status_lines
        )
        self.assertTrue(closed_by_peer)

        # 正常的无体 Keep-Alive 请求与 Content-Length: 0 仍可正常复用同一连接。
        keepalive_conn = http.client.HTTPConnection(
            "127.0.0.1", self.port, timeout=3.0
        )
        try:
            keepalive_conn.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers={"Authorization": auth},
            )
            first_resp = keepalive_conn.getresponse()
            first_resp.read()
            self.assertEqual(first_resp.status, 200)
            first_sock = keepalive_conn.sock
            self.assertIsNotNone(first_sock)

            keepalive_conn.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers={"Authorization": auth, "Content-Length": "0"},
            )
            second_resp = keepalive_conn.getresponse()
            second_resp.read()
            self.assertEqual(second_resp.status, 200)
            self.assertIs(keepalive_conn.sock, first_sock)
        finally:
            keepalive_conn.close()

        smuggled_check = self.request(
            "GET",
            "/v1/spaces/%s/files/smuggled.bin" % self.space_id,
            headers=self.authorization_headers(),
        )
        self.assertEqual(smuggled_check[0], 404)
        self.assertIsInstance(
            pt_sync_server.SyncRequestHandler.timeout, (int, float)
        )
        self.assertGreater(pt_sync_server.SyncRequestHandler.timeout, 0)

    def test_streaming_put_keeps_python_heap_peak_low(self):
        """保证流式上传数 MiB 同步文件时 Python 堆内存峰值远低于文件体积，且沿用 systemd 256M 内存上限。"""

        with tempfile.TemporaryDirectory(
            prefix="pt-sync-stream-test-"
        ) as temp_dir:
            temp_root = Path(temp_dir)
            large_server = pt_sync_server.create_server(
                "127.0.0.1",
                0,
                temp_root / "state",
                self.enroll_hash_file,
                max_spaces=2,
                max_file_bytes=70 * 1024 * 1024,
                max_space_bytes=512 * 1024 * 1024,
                access_log=lambda _line: None,
            )
            server_thread = threading.Thread(
                target=large_server.serve_forever, daemon=True
            )
            server_thread.start()
            try:
                token_hash = hashlib.sha256(
                    self.access_token.encode("utf-8")
                ).hexdigest()
                large_server.store.create_space(
                    self.space_id, token_hash, "2026-11-18T00:00:00Z"
                )
                port = large_server.server_address[1]
                chunk = b"S" * (64 * 1024)
                chunk_count = 128  # 8 MiB
                total_bytes = len(chunk) * chunk_count
                expected_hasher = hashlib.sha256()
                for _ in range(chunk_count):
                    expected_hasher.update(chunk)
                expected_sha256 = expected_hasher.hexdigest()

                request_header = (
                    "PUT /v1/spaces/%s/files/snapshots/full.bin HTTP/1.1\r\n"
                    "Host: 127.0.0.1:%d\r\n"
                    "Authorization: Bearer %s\r\n"
                    "Content-Type: application/octet-stream\r\n"
                    "Content-Length: %d\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    % (self.space_id, port, self.access_token, total_bytes)
                ).encode("ascii")

                tracemalloc.start()
                try:
                    with socket.create_connection(
                        ("127.0.0.1", port), timeout=10.0
                    ) as sock:
                        sock.sendall(request_header)
                        for _ in range(chunk_count):
                            sock.sendall(chunk)
                        response_bytes = b""
                        while True:
                            piece = sock.recv(4096)
                            if not piece:
                                break
                            response_bytes += piece
                    _current_bytes, peak_bytes = tracemalloc.get_traced_memory()
                finally:
                    tracemalloc.stop()

                header_part, body_part = response_bytes.split(b"\r\n\r\n", 1)
                self.assertIn(b"HTTP/1.1 200 ", header_part)
                self.assertEqual(
                    json.loads(body_part.decode("utf-8")), {"rev": 1}
                )
                self.assertLess(
                    peak_bytes,
                    int(1.5 * 1024 * 1024),
                    "8 MiB 上传的 Python 堆峰值过高: %d bytes" % peak_bytes,
                )

                stored_path = (
                    Path(large_server.store.files_directory(self.space_id))
                    / "snapshots"
                    / "full.bin"
                )
                self.assertEqual(stored_path.stat().st_size, total_bytes)
                digest = hashlib.sha256()
                with open(stored_path, "rb") as handle:
                    while True:
                        block = handle.read(64 * 1024)
                        if not block:
                            break
                        digest.update(block)
                self.assertEqual(digest.hexdigest(), expected_sha256)

                # 上传中途 EOF 不足 Content-Length 字节时，应返回 400、关闭连接且不留临时文件。
                truncated_header = (
                    "PUT /v1/spaces/%s/files/snapshots/truncated.bin HTTP/1.1\r\n"
                    "Host: 127.0.0.1:%d\r\n"
                    "Authorization: Bearer %s\r\n"
                    "Content-Length: %d\r\n"
                    "\r\n"
                    % (self.space_id, port, self.access_token, 128 * 1024)
                ).encode("ascii")
                with socket.create_connection(
                    ("127.0.0.1", port), timeout=5.0
                ) as sock:
                    sock.sendall(truncated_header)
                    sock.sendall(b"T" * 1024)
                    sock.shutdown(socket.SHUT_WR)
                    truncated_resp = b""
                    while True:
                        piece = sock.recv(4096)
                        if not piece:
                            break
                        truncated_resp += piece
                self.assertIn(b"HTTP/1.1 400 ", truncated_resp)
                space_dir = Path(
                    large_server.store.space_directory(self.space_id)
                )
                leftover = [
                    p.name
                    for p in space_dir.rglob("*")
                    if p.name.startswith(pt_sync_server.TEMP_PREFIX)
                ]
                self.assertEqual(leftover, [])
            finally:
                large_server.store.wake_all()
                large_server.shutdown()
                large_server.server_close()
                server_thread.join(1.0)

        service_unit = (
            SERVER_DIRECTORY / "deploy" / "pt-sync.service"
        ).read_text(encoding="utf-8")
        # 上传与下载都按 64 KiB 分块流式处理，单请求堆峰值约 1 MiB 量级；沿用线上 256M 上限即可，不必放宽。
        self.assertIn("MemoryMax=256M", service_unit)

    def test_watch_returns_404_when_space_deleted_while_waiting(self):
        """保证客户端长轮询 watch 等待期间若同步空间被删除，服务器返回 404 space_not_found 而非 500。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        watch_url = "/v1/spaces/%s/watch?rev=0&timeout=1.5" % self.space_id

        cli_watch_result = []

        def run_cli_deleted_watch():
            cli_watch_result.append(
                self.request(
                    "GET", watch_url, headers=common_headers, timeout=5.0
                )
            )

        watcher = threading.Thread(target=run_cli_deleted_watch, daemon=True)
        watcher.start()
        time.sleep(0.2)
        started = time.monotonic()
        with contextlib.redirect_stdout(io.StringIO()):
            delete_rc = pt_sync_server.main(
                [
                    "delete-space",
                    "--state-dir",
                    str(self.state_directory),
                    "--space",
                    self.space_id,
                ]
            )
        self.assertEqual(delete_rc, 0)
        watcher.join(timeout=4.0)
        cli_elapsed = time.monotonic() - started
        self.assertFalse(watcher.is_alive())
        self.assertEqual(cli_watch_result[0][0], 404)
        self.assertEqual(
            self.decode_json(cli_watch_result[0]), {"error": "space_not_found"}
        )
        self.assertLess(cli_elapsed, 1.5)

        # 同进程调用 SpaceStore.delete_space 也应立即通过条件变量唤醒 watch 并返回 404。
        self.assertEqual(self.create_space()[0], 201)
        long_watch_url = "/v1/spaces/%s/watch?rev=0&timeout=5" % self.space_id
        inproc_watch_result = []

        def run_inproc_deleted_watch():
            inproc_watch_result.append(
                self.request(
                    "GET", long_watch_url, headers=common_headers, timeout=6.0
                )
            )

        inproc_watcher = threading.Thread(
            target=run_inproc_deleted_watch, daemon=True
        )
        inproc_watcher.start()
        time.sleep(0.2)
        started = time.monotonic()
        self.server.store.delete_space(self.space_id)
        inproc_watcher.join(timeout=2.0)
        inproc_elapsed = time.monotonic() - started
        self.assertFalse(inproc_watcher.is_alive())
        self.assertEqual(inproc_watch_result[0][0], 404)
        self.assertEqual(
            self.decode_json(inproc_watch_result[0]),
            {"error": "space_not_found"},
        )
        self.assertLess(inproc_elapsed, 1.0)

    def test_put_fsync_failure_after_meta_replace_never_splits_content_and_rev(
        self,
    ):
        """保证 PUT 在 meta.json 改名后目录刷写失败时，绝不把内容回滚成旧值而版本停在新值，内容、版本与长轮询保持一致。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        file_url = "/v1/spaces/%s/files/stable.json" % self.space_id
        watch_url = "/v1/spaces/%s/watch" % self.space_id
        self.assertEqual(
            self.request("PUT", file_url, b"v1-content", common_headers)[0],
            200,
        )
        self.assertEqual(
            self.decode_json(
                self.request(
                    "GET",
                    "/v1/spaces/%s/tree" % self.space_id,
                    headers=common_headers,
                )
            )["rev"],
            1,
        )

        space_dir = os.path.abspath(
            self.server.store.space_directory(self.space_id)
        )
        real_fsync_directory = pt_sync_server.fsync_directory
        injected = [False]

        def fail_fsync_after_meta_replace(path):
            # 等 meta.json 已经推进到 rev=2 后再注入目录刷写失败，精确复现 074 P2 窗口。
            if (
                not injected[0]
                and os.path.abspath(str(path)) == space_dir
                and self.server.store.read_metadata(self.space_id)["rev"] == 2
            ):
                injected[0] = True
                raise OSError("injected space_dir fsync failure after meta replace")
            return real_fsync_directory(path)

        with mock.patch.object(
            pt_sync_server,
            "fsync_directory",
            side_effect=fail_fsync_after_meta_replace,
        ):
            failed = self.request(
                "PUT", file_url, b"v2-content", common_headers
            )
        self.assertTrue(injected[0])
        self.assertEqual(failed[0], 500)

        # 内容、tree 版本、watch 长轮询三者必须严格一致（同为 v2 与 rev=2）。
        after_get = self.request("GET", file_url, headers=common_headers)
        self.assertEqual(after_get[0], 200)
        after_tree = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )
        after_watch = self.decode_json(
            self.request(
                "GET", watch_url + "?rev=1&timeout=0", headers=common_headers
            )
        )
        self.assertEqual(after_tree["rev"], 2)
        self.assertEqual(after_watch["rev"], 2)
        self.assertEqual(after_get[1], b"v2-content")

    def test_delete_fsync_failure_after_meta_replace_never_splits_file_and_rev(
        self,
    ):
        """保证 DELETE 在 meta.json 改名后目录刷写失败时，绝不把已删文件还原而版本停在新值。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        file_url = "/v1/spaces/%s/files/devices/keep.bin" % self.space_id
        watch_url = "/v1/spaces/%s/watch" % self.space_id
        self.assertEqual(
            self.request("PUT", file_url, b"v1-data", common_headers)[0], 200
        )

        space_dir = os.path.abspath(
            self.server.store.space_directory(self.space_id)
        )
        real_fsync_directory = pt_sync_server.fsync_directory
        injected = [False]

        def fail_fsync_after_meta_replace(path):
            if (
                not injected[0]
                and os.path.abspath(str(path)) == space_dir
                and self.server.store.read_metadata(self.space_id)["rev"] == 2
            ):
                injected[0] = True
                raise OSError("injected fsync failure after delete meta replace")
            return real_fsync_directory(path)

        with mock.patch.object(
            pt_sync_server,
            "fsync_directory",
            side_effect=fail_fsync_after_meta_replace,
        ):
            failed = self.request("DELETE", file_url, headers=common_headers)
        self.assertTrue(injected[0])
        self.assertEqual(failed[0], 500)

        after_get = self.request("GET", file_url, headers=common_headers)
        after_tree = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )
        after_watch = self.decode_json(
            self.request(
                "GET", watch_url + "?rev=1&timeout=0", headers=common_headers
            )
        )
        self.assertEqual(after_get[0], 404)
        self.assertEqual(after_tree["rev"], 2)
        self.assertEqual(after_watch["rev"], 2)

    def test_one_unrecoverable_space_does_not_block_startup_or_other_spaces(self):
        """保证某个空间的提交日志损坏时服务照常启动、其它空间照常读写，且该空间的暂存文件不被启动清理删掉。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        file_url = "/v1/spaces/%s/files/devices/ok.bin" % self.space_id
        self.assertEqual(
            self.request("PUT", file_url, b"healthy", common_headers)[0], 200
        )
        self._stop_server()

        # 手工造出第二个空间：元数据正常，但 commit.json 不是合法 JSON，旁边留着它要前滚的暂存文件。
        broken_space = "space-broken-0000000"
        broken_dir = self.state_directory / "spaces" / broken_space
        (broken_dir / pt_sync_server.FILES_DIR_NAME).mkdir(parents=True)
        (broken_dir / pt_sync_server.META_FILE_NAME).write_text(
            json.dumps(
                {
                    "token_sha256": hashlib.sha256(
                        self.access_token.encode("utf-8")
                    ).hexdigest(),
                    "rev": 3,
                    "created_at": "2026-11-21T00:00:00Z",
                }
            ),
            encoding="utf-8",
        )
        (broken_dir / pt_sync_server.COMMIT_FILE_NAME).write_text(
            "{not json", encoding="utf-8"
        )
        stage_file = broken_dir / (pt_sync_server.STAGE_PREFIX + "pending")
        stage_file.write_bytes(b"staged-bytes")

        # 启动不能因为这一个空间失败；健康空间读写照旧。
        self._start_server()
        healthy_get = self.request("GET", file_url, headers=common_headers)
        self.assertEqual(healthy_get[0], 200)
        self.assertEqual(healthy_get[1], b"healthy")
        self.assertEqual(
            self.request("PUT", file_url, b"healthy-2", common_headers)[0], 200
        )

        # 坏空间每次访问都重试前滚并报存储错误，不会被当成「没有待恢复提交」静默放行。
        broken_tree = self.request(
            "GET", "/v1/spaces/%s/tree" % broken_space, headers=common_headers
        )
        self.assertEqual(broken_tree[0], 500)
        # 暂存文件要留到人工处理，启动清理不能删掉前滚所需的内容。
        self.assertTrue(stage_file.exists())
        self.assertTrue((broken_dir / pt_sync_server.COMMIT_FILE_NAME).exists())

    def test_interrupted_commit_replays_on_restart_for_put_and_delete(self):
        """保证进程在提交日志落盘后、元数据落盘前崩溃重启时，PUT 与 DELETE 均前滚收敛且内容/版本/watch 一致。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        file_url = "/v1/spaces/%s/files/devices/crash.bin" % self.space_id
        watch_url = "/v1/spaces/%s/watch" % self.space_id
        self.assertEqual(
            self.request("PUT", file_url, b"before-crash", common_headers)[0],
            200,
        )

        # 场景 1：PUT 替换目标文件后、写 meta.json 前中断重启。
        real_replace = pt_sync_server.os.replace

        def fail_meta_write(source, target):
            if Path(str(target)).name == pt_sync_server.META_FILE_NAME:
                raise OSError("simulated crash before meta replace")
            return real_replace(source, target)

        with mock.patch.object(
            pt_sync_server.os, "replace", side_effect=fail_meta_write
        ):
            failed_put = self.request(
                "PUT", file_url, b"after-crash-put", common_headers
            )
        self.assertEqual(failed_put[0], 500)

        # 重启服务：启动恢复必须重放 commit.json 前滚到新内容与 rev=2。
        self._stop_server()
        self._start_server()

        get_after_put = self.request("GET", file_url, headers=common_headers)
        tree_after_put = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )
        watch_after_put = self.decode_json(
            self.request(
                "GET", watch_url + "?rev=1&timeout=0", headers=common_headers
            )
        )
        self.assertEqual(get_after_put[0], 200)
        self.assertEqual(get_after_put[1], b"after-crash-put")
        self.assertEqual(tree_after_put["rev"], 2)
        self.assertEqual(watch_after_put["rev"], 2)

        # 场景 2：DELETE 删除目标文件后、写 meta.json 前中断重启。
        with mock.patch.object(
            pt_sync_server.os, "replace", side_effect=fail_meta_write
        ):
            failed_delete = self.request(
                "DELETE", file_url, headers=common_headers
            )
        self.assertEqual(failed_delete[0], 500)

        self._stop_server()
        self._start_server()

        get_after_del = self.request("GET", file_url, headers=common_headers)
        tree_after_del = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )
        watch_after_del = self.decode_json(
            self.request(
                "GET", watch_url + "?rev=2&timeout=0", headers=common_headers
            )
        )
        self.assertEqual(get_after_del[0], 404)
        self.assertEqual(tree_after_del["rev"], 3)
        self.assertEqual(watch_after_del["rev"], 3)

    def test_delete_file_rejects_symlink_inside_space(self):
        """保证 DELETE 拒绝删除空间目录内指向目标文件的符号链接。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        real_url = "/v1/spaces/%s/files/real.bin" % self.space_id
        self.assertEqual(
            self.request("PUT", real_url, b"payload", common_headers)[0], 200
        )
        files_dir = Path(self.server.store.files_directory(self.space_id))
        link_path = files_dir / "alias.bin"
        os.symlink(str(files_dir / "real.bin"), str(link_path))

        resp = self.request(
            "DELETE",
            "/v1/spaces/%s/files/alias.bin" % self.space_id,
            headers=common_headers,
        )
        self.assertEqual(resp[0], 400)
        self.assertEqual(self.decode_json(resp), {"error": "bad_path"})
        self.assertTrue(os.path.islink(link_path))

    def test_quota_cache_avoids_rescan_and_stays_consistent_across_ops(self):
        """保证 PUT 配额缓存避免每次全扫目录，且在覆盖、超限、失败、删除与重启后计数准确。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        first = "/v1/spaces/%s/files/a.bin" % self.space_id
        second = "/v1/spaces/%s/files/b.bin" % self.space_id

        real_usage = pt_sync_server.directory_usage
        usage_calls = [0]

        def counting_usage(root):
            usage_calls[0] += 1
            return real_usage(root)

        with mock.patch.object(
            pt_sync_server, "directory_usage", side_effect=counting_usage
        ):
            # 首次 PUT 触发一次初始化扫描，后续覆盖/新增/删除均走 O(1) 缓存。
            self.assertEqual(
                self.request("PUT", first, b"1" * 120, common_headers)[0], 200
            )
            self.assertEqual(
                self.request("PUT", first, b"2" * 150, common_headers)[0], 200
            )
            self.assertEqual(
                self.request("PUT", second, b"3" * 150, common_headers)[0], 200
            )
            # 此时正好 300 字节（等于 max_space_bytes=300），扩大 1 字节必须 507 拒绝。
            self.assertEqual(
                self.request("PUT", second, b"4" * 151, common_headers)[0], 507
            )
            # 缩小 first 腾出 50 字节后，second 可以写到 200 字节。
            self.assertEqual(
                self.request("PUT", first, b"5" * 100, common_headers)[0], 200
            )
            self.assertEqual(
                self.request("PUT", second, b"6" * 200, common_headers)[0], 200
            )
            # 删除 first 后腾出 100 字节。
            self.assertEqual(
                self.request("DELETE", first, headers=common_headers)[0], 200
            )
            self.assertEqual(
                self.request("PUT", first, b"7" * 100, common_headers)[0], 200
            )
            self.assertEqual(usage_calls[0], 1)

        # 重启后重新计算配额仍然准确（当前 300 字节，多 1 字节拒收）。
        self._stop_server()
        self._start_server()
        self.assertEqual(
            self.request("PUT", first, b"8" * 101, common_headers)[0], 507
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)

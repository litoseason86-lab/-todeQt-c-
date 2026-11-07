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
import subprocess
import sys
import tempfile
import threading
import time
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
        """保证写到一半失败时旧文件完整、无临时残留，并能跨实例清理上次残留。"""

        self.assertEqual(self.create_space()[0], 201)
        common_headers = self.authorization_headers()
        path = "/v1/spaces/%s/files/stable.json" % self.space_id
        self.assertEqual(
            self.request("PUT", path, b"old-content", common_headers)[0], 200
        )
        files_directory = Path(
            self.server.store.files_directory(self.space_id)
        )
        # macOS 的 /var 是 /private/var 的符号链接；服务器会先 realpath，
        # 测试也必须比较解析后的路径才能只拦目标文件而不拦元数据写入。
        target_path = Path(os.path.realpath(str(files_directory / "stable.json")))
        real_replace = pt_sync_server.os.replace

        def fail_target_replace(source, target):
            if os.path.abspath(str(target)) == os.path.abspath(str(target_path)):
                raise OSError("injected replace failure")
            return real_replace(source, target)

        with mock.patch.object(
            pt_sync_server.os, "replace", side_effect=fail_target_replace
        ):
            failed_write = self.request(
                "PUT", path, b"new-content", common_headers
            )
        self.assertEqual(failed_write[0], 500)
        old_read = self.request("GET", path, headers=common_headers)
        self.assertEqual(old_read[1], b"old-content")
        self.assertEqual(
            [
                name
                for name in os.listdir(files_directory)
                if name.startswith(pt_sync_server.TEMP_PREFIX)
            ],
            [],
        )

        rev_before_meta_failure = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )["rev"]

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
                "PUT", path, b"uncommitted-content", common_headers
            )
        self.assertEqual(failed_metadata_write[0], 500)
        content_after_metadata_failure = self.request(
            "GET", path, headers=common_headers
        )
        self.assertEqual(content_after_metadata_failure[1], b"old-content")
        tree_after_metadata_failure = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )
        self.assertEqual(
            tree_after_metadata_failure["rev"], rev_before_meta_failure
        )
        self.assertEqual(
            [
                name
                for name in os.listdir(files_directory)
                if name.startswith(pt_sync_server.TEMP_PREFIX)
            ],
            [],
        )

        rev_before_restart = self.decode_json(
            self.request(
                "GET",
                "/v1/spaces/%s/tree" % self.space_id,
                headers=common_headers,
            )
        )["rev"]
        self._stop_server()
        (files_directory / (pt_sync_server.TEMP_PREFIX + "leftover")).write_bytes(
            b"partial"
        )
        self._start_server()
        self.assertFalse((files_directory / (pt_sync_server.TEMP_PREFIX + "leftover")).exists())
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
            finally:
                process.send_signal(signal.SIGTERM)
                try:
                    _stdout, _stderr = process.communicate(timeout=5.0)
                    self.assertEqual(process.returncode, 0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    self.fail("服务器收到 SIGTERM 后 5 秒内没有退出")


if __name__ == "__main__":
    unittest.main(verbosity=2)

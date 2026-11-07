#!/usr/bin/env python3
"""番茄Todo 自建同步中转服务器。

服务器只保存客户端已经加密的同步文件，不理解任务、备忘录等业务内容。
实现刻意只依赖 Python 标准库，兼容 Python 3.9 与线上 Python 3.12。
"""

import argparse
import datetime
import hashlib
import hmac
import json
import math
import os
import re
import shutil
import signal
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer


SPACE_ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{16,64}")
HEX_64_PATTERN = re.compile(r"[0-9A-Fa-f]{64}")
PATH_SEGMENT_PATTERN = re.compile(r"[A-Za-z0-9._\-\u4e00-\u9fff]{1,128}")
TEMP_PREFIX = ".pt-tmp-"
META_FILE_NAME = "meta.json"
FILES_DIR_NAME = "files"
DEFAULT_MAX_SPACES = 8
DEFAULT_MAX_FILE_BYTES = 70 * 1024 * 1024
DEFAULT_MAX_SPACE_BYTES = 512 * 1024 * 1024
DEFAULT_WATCH_TIMEOUT = 25.0
MAX_WATCH_TIMEOUT = 25.0


class ApiError(Exception):
    """带 HTTP 状态码的预期错误。"""

    def __init__(self, status, code, close_connection=False):
        Exception.__init__(self, code)
        self.status = status
        self.code = code
        # 请求体没被完整读走时必须断开连接，否则同一 keep-alive 连接会把
        # 剩下的字节误当成下一条请求。
        self.close_connection = close_connection


class StorageError(Exception):
    """状态目录损坏或无法完成持久化。"""


def utc_now_iso():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.isoformat(timespec="seconds").replace("+00:00", "Z")


def normalize_token_hash(value):
    if not isinstance(value, str) or HEX_64_PATTERN.fullmatch(value) is None:
        return None
    return value.lower()


def load_enroll_hash(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError as exc:
        raise StorageError("无法读取注册口令哈希文件") from exc
    normalized = normalize_token_hash(value)
    if normalized is None:
        raise StorageError("注册口令哈希文件必须是 64 位十六进制")
    return normalized


def fsync_directory(path):
    """把父目录的目录项落盘，保证原子替换在掉电后也有确定结果。"""

    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_bytes(target, content):
    """先写同目录临时文件，再原子替换目标文件。"""

    target = os.path.abspath(str(target))
    parent = os.path.dirname(target)
    os.makedirs(parent, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=TEMP_PREFIX, dir=parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        fsync_directory(parent)
    finally:
        if os.path.lexists(temporary):
            try:
                os.unlink(temporary)
            except OSError:
                pass


def atomic_write_json(target, value):
    content = json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    atomic_write_bytes(target, content)


def cleanup_temporary_files(root):
    """清掉上次进程异常退出后留下的临时文件，不跟随符号链接。"""

    if not os.path.isdir(root):
        return
    for current_root, directories, files in os.walk(root, followlinks=False):
        directories[:] = [
            name
            for name in directories
            if not os.path.islink(os.path.join(current_root, name))
        ]
        for name in files:
            if not name.startswith(TEMP_PREFIX):
                continue
            path = os.path.join(current_root, name)
            if os.path.islink(path):
                continue
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def decode_file_path(raw_path):
    """先做百分号解码，再交给路径规则校验。"""

    try:
        decoded = urllib.parse.unquote_to_bytes(raw_path).decode("utf-8")
    except (UnicodeDecodeError, ValueError) as exc:
        raise ApiError(400, "bad_path") from exc
    return decoded


def validate_file_path(files_root, decoded_path):
    """校验同步文件的相对路径，并解析出真实目标路径。"""

    if not isinstance(decoded_path, str):
        raise ApiError(400, "bad_path")
    if (
        decoded_path == ""
        or decoded_path.startswith("/")
        or decoded_path.endswith("/")
        or "\\" in decoded_path
    ):
        raise ApiError(400, "bad_path")

    segments = decoded_path.split("/")
    if len(segments) < 1 or len(segments) > 4:
        raise ApiError(400, "bad_path")
    for segment in segments:
        if (
            PATH_SEGMENT_PATTERN.fullmatch(segment) is None
            or segment in (".", "..")
            or segment.startswith(TEMP_PREFIX)
        ):
            raise ApiError(400, "bad_path")

    root_real = os.path.realpath(str(files_root))
    target_real = os.path.realpath(os.path.join(root_real, *segments))
    try:
        if os.path.commonpath([root_real, target_real]) != root_real:
            raise ApiError(400, "bad_path")
    except ValueError as exc:
        raise ApiError(400, "bad_path") from exc
    if target_real == root_real:
        raise ApiError(400, "bad_path")

    relative_path = "/".join(segments)
    return relative_path, target_real


def directory_usage(files_root):
    """统计空间占用；符号链接和临时文件不属于同步内容。"""

    count = 0
    total_bytes = 0
    for current_root, directories, files in os.walk(files_root, followlinks=False):
        directories[:] = [
            name
            for name in directories
            if not os.path.islink(os.path.join(current_root, name))
        ]
        for name in files:
            if name.startswith(TEMP_PREFIX):
                continue
            path = os.path.join(current_root, name)
            if os.path.islink(path):
                continue
            try:
                stat_result = os.stat(path, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not os.path.isfile(path):
                continue
            count += 1
            total_bytes += stat_result.st_size
    return count, total_bytes


class SpaceStore:
    """状态目录、空间锁和变化通知的唯一所有者。"""

    def __init__(
        self,
        state_dir,
        enroll_hash,
        max_spaces,
        max_file_bytes,
        max_space_bytes,
    ):
        self.state_dir = os.path.abspath(str(state_dir))
        self.spaces_root = os.path.join(self.state_dir, "spaces")
        self.enroll_hash = enroll_hash
        self.max_spaces = max_spaces
        self.max_file_bytes = max_file_bytes
        self.max_space_bytes = max_space_bytes
        self.shutting_down = threading.Event()
        self._registry_lock = threading.Lock()
        self._conditions = {}

        os.makedirs(self.spaces_root, exist_ok=True)
        cleanup_temporary_files(self.spaces_root)

    def space_directory(self, space_id):
        return os.path.join(self.spaces_root, space_id)

    def files_directory(self, space_id):
        return os.path.join(self.space_directory(space_id), FILES_DIR_NAME)

    def metadata_path(self, space_id):
        return os.path.join(self.space_directory(space_id), META_FILE_NAME)

    def condition_for(self, space_id):
        with self._registry_lock:
            condition = self._conditions.get(space_id)
            if condition is None:
                condition = threading.Condition()
                self._conditions[space_id] = condition
            return condition

    def wake_all(self):
        self.shutting_down.set()
        with self._registry_lock:
            conditions = list(self._conditions.values())
        for condition in conditions:
            with condition:
                condition.notify_all()

    def read_metadata(self, space_id):
        path = self.metadata_path(space_id)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, ValueError) as exc:
            raise StorageError("空间元数据不可读") from exc
        if (
            not isinstance(value, dict)
            or normalize_token_hash(value.get("token_sha256")) is None
            or not isinstance(value.get("rev"), int)
            or value["rev"] < 0
            or not isinstance(value.get("created_at"), str)
        ):
            raise StorageError("空间元数据格式错误")
        value["token_sha256"] = value["token_sha256"].lower()
        return value

    def space_exists(self, space_id):
        return os.path.isdir(self.space_directory(space_id)) and os.path.isfile(
            self.metadata_path(space_id)
        )

    def _space_count(self):
        count = 0
        try:
            entries = os.scandir(self.spaces_root)
        except OSError as exc:
            raise StorageError("无法读取空间目录") from exc
        with entries:
            for entry in entries:
                if not entry.is_dir(follow_symlinks=False):
                    continue
                if os.path.isfile(os.path.join(entry.path, META_FILE_NAME)):
                    count += 1
        return count

    def create_space(self, space_id, token_sha256, created_at):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        normalized_hash = normalize_token_hash(token_sha256)
        if normalized_hash is None:
            raise ApiError(400, "bad_request")

        with self._registry_lock:
            if self.space_exists(space_id):
                raise ApiError(409, "space_exists")
            if self._space_count() >= self.max_spaces:
                raise ApiError(507, "space_limit")

            space_directory = self.space_directory(space_id)
            files_directory = self.files_directory(space_id)
            try:
                os.mkdir(space_directory)
                os.mkdir(files_directory)
                atomic_write_json(
                    self.metadata_path(space_id),
                    {
                        "token_sha256": normalized_hash,
                        "rev": 0,
                        "created_at": created_at,
                    },
                )
            except Exception:
                shutil.rmtree(space_directory, ignore_errors=True)
                raise
            self._conditions.setdefault(space_id, threading.Condition())
        return 0

    def require_space(self, space_id):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        if not self.space_exists(space_id):
            raise ApiError(404, "space_not_found")
        return self.read_metadata(space_id)

    def authenticate(self, space_id, token):
        metadata = self.require_space(space_id)
        actual_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        if not hmac.compare_digest(metadata["token_sha256"], actual_hash):
            raise ApiError(401, "unauthorized")
        return metadata

    def list_tree(self, space_id):
        self.require_space(space_id)
        files_root = self.files_directory(space_id)
        entries = []

        def visit(directory, prefix):
            try:
                children = list(os.scandir(directory))
            except OSError as exc:
                raise StorageError("无法枚举空间文件") from exc
            children.sort(key=lambda item: item.name)
            for child in children:
                if child.is_symlink():
                    continue
                relative = child.name if prefix == "" else prefix + "/" + child.name
                if child.is_dir(follow_symlinks=False):
                    entries.append({"path": relative, "type": "dir"})
                    visit(child.path, relative)
                elif child.is_file(follow_symlinks=False):
                    if child.name.startswith(TEMP_PREFIX):
                        continue
                    try:
                        size = child.stat(follow_symlinks=False).st_size
                    except FileNotFoundError:
                        continue
                    entries.append(
                        {"path": relative, "type": "file", "size": size}
                    )

        visit(files_root, "")
        entries.sort(key=lambda item: item["path"])
        metadata = self.read_metadata(space_id)
        return metadata["rev"], entries

    def read_file(self, space_id, decoded_path):
        self.require_space(space_id)
        _, target = validate_file_path(
            self.files_directory(space_id), decoded_path
        )
        if not os.path.isfile(target):
            raise ApiError(404, "file_not_found")
        try:
            with open(target, "rb") as handle:
                return handle.read()
        except FileNotFoundError as exc:
            raise ApiError(404, "file_not_found") from exc
        except OSError as exc:
            raise StorageError("无法读取同步文件") from exc

    def write_file(self, space_id, decoded_path, content):
        self.require_space(space_id)
        if len(content) > self.max_file_bytes:
            raise ApiError(413, "file_too_large", close_connection=True)

        condition = self.condition_for(space_id)
        with condition:
            relative_path, target = validate_file_path(
                self.files_directory(space_id), decoded_path
            )
            if os.path.isdir(target):
                raise ApiError(409, "is_directory")

            metadata = self.read_metadata(space_id)
            old_size = 0
            if os.path.isfile(target):
                try:
                    old_size = os.stat(target, follow_symlinks=False).st_size
                except FileNotFoundError:
                    old_size = 0

            _, current_total = directory_usage(self.files_directory(space_id))
            if current_total - old_size + len(content) > self.max_space_bytes:
                raise ApiError(507, "quota_exceeded")

            try:
                os.makedirs(os.path.dirname(target), exist_ok=True)
            except (FileExistsError, NotADirectoryError) as exc:
                raise ApiError(409, "is_directory") from exc

            relative_path, target = validate_file_path(
                self.files_directory(space_id), relative_path
            )
            old_file_existed = os.path.isfile(target)
            backup_path = None
            if old_file_existed:
                backup_path = self._link_file_backup(target)
            try:
                atomic_write_bytes(target, content)
                metadata["rev"] += 1
                atomic_write_json(self.metadata_path(space_id), metadata)
            except Exception:
                # 文件与 meta.json 是两次原子替换。若第二次失败，必须把文件恢复
                # 到旧内容，否则客户端收到失败却看到新内容，且 rev 没有前进。
                if self._restore_file_after_failure(
                    target, backup_path, old_file_existed
                ):
                    backup_path = None
                raise
            finally:
                if backup_path is not None and os.path.lexists(backup_path):
                    try:
                        os.unlink(backup_path)
                    except OSError:
                        # 文件与 rev 已经提交；清理失败不能让客户端误以为写入失败。
                        pass
            condition.notify_all()
            return metadata["rev"]

    def _link_file_backup(self, target):
        """在同一目录给旧文件做硬链接，不复制最多 70 MiB 的同步内容。"""

        descriptor, backup_path = tempfile.mkstemp(
            prefix=TEMP_PREFIX, dir=os.path.dirname(target)
        )
        os.close(descriptor)
        os.unlink(backup_path)
        try:
            os.link(target, backup_path)
        except OSError:
            if os.path.lexists(backup_path):
                os.unlink(backup_path)
            raise
        return backup_path

    def _restore_file_after_failure(
        self, target, backup_path, old_file_existed
    ):
        """撤销已替换的文件；回滚失败时保留临时备份，下次启动再清理。"""

        try:
            if old_file_existed and backup_path is not None:
                if os.path.isfile(target) and os.path.samefile(
                    target, backup_path
                ):
                    # 文件替换本身失败时旧目标仍是备份的同一 inode。
                    os.unlink(backup_path)
                else:
                    os.replace(backup_path, target)
                    fsync_directory(os.path.dirname(target))
            elif not old_file_existed and os.path.lexists(target):
                os.unlink(target)
                fsync_directory(os.path.dirname(target))
        except OSError:
            # 原异常更重要；备份仍带 .pt-tmp- 前缀，下一次启动会清理。
            return False
        return True

    def delete_file(self, space_id, decoded_path):
        self.require_space(space_id)
        condition = self.condition_for(space_id)
        with condition:
            _, target = validate_file_path(
                self.files_directory(space_id), decoded_path
            )
            if os.path.isdir(target):
                raise ApiError(409, "is_directory")
            if not os.path.lexists(target):
                return self.read_metadata(space_id)["rev"]
            try:
                os.unlink(target)
                fsync_directory(os.path.dirname(target))
            except FileNotFoundError:
                return self.read_metadata(space_id)["rev"]
            except OSError as exc:
                raise StorageError("无法删除同步文件") from exc

            metadata = self.read_metadata(space_id)
            metadata["rev"] += 1
            atomic_write_json(self.metadata_path(space_id), metadata)
            condition.notify_all()
            return metadata["rev"]

    def watch(self, space_id, known_rev, timeout):
        self.require_space(space_id)
        condition = self.condition_for(space_id)
        deadline = time.monotonic() + timeout
        with condition:
            current_rev = self.read_metadata(space_id)["rev"]
            if current_rev != known_rev:
                return current_rev
            while current_rev == known_rev and not self.shutting_down.is_set():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                condition.wait(remaining)
                current_rev = self.read_metadata(space_id)["rev"]
            return current_rev


class PtSyncHTTPServer(ThreadingHTTPServer):
    """支持 keep-alive 的线程服务器；每个请求线程不阻塞主退出流程。"""

    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, handler_class, store, access_log):
        self.store = store
        self.access_log = access_log
        ThreadingHTTPServer.__init__(self, address, handler_class)


class SyncRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pt-sync/1"
    sys_version = ""

    def log_message(self, format_string, *args):
        message = format_string % args
        self.server.access_log("PT_SYNC " + message)

    def log_error(self, format_string, *args):
        # BaseHTTPRequestHandler 的默认错误日志可能带原始请求行，其中可能包含
        # 查询串。访问日志只由 log_request 输出脱敏后的方法、路径和状态码。
        return

    def log_request(self, code="-", size="-"):
        try:
            safe_path = urllib.parse.urlsplit(self.path).path
        except ValueError:
            safe_path = "-"
        method = self.command if self.command else "-"
        self.log_message("%s %s %s", method, safe_path or "/", code)

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def do_HEAD(self):
        self._dispatch("HEAD")

    def do_OPTIONS(self):
        self._dispatch("OPTIONS")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_TRACE(self):
        self._dispatch("TRACE")

    def _dispatch(self, method):
        try:
            parsed = urllib.parse.urlsplit(self.path)
            path = parsed.path
            if path == "/v1/spaces":
                if method != "POST":
                    raise ApiError(405, "method_not_allowed")
                self._create_space()
                return
            if not path.startswith("/v1/spaces/"):
                raise ApiError(404, "not_found")

            remainder = path[len("/v1/spaces/") :]
            if "/" not in remainder:
                raise ApiError(404, "not_found")
            space_id, operation = remainder.split("/", 1)
            if SPACE_ID_PATTERN.fullmatch(space_id) is None:
                raise ApiError(400, "bad_space")

            if operation == "tree":
                if method != "GET":
                    raise ApiError(405, "method_not_allowed")
                self._get_tree(space_id)
                return
            if operation == "watch":
                if method != "GET":
                    raise ApiError(405, "method_not_allowed")
                self._watch_space(space_id, parsed.query)
                return
            if operation == "files":
                raise ApiError(400, "bad_path")
            if operation.startswith("files/"):
                raw_file_path = operation[len("files/") :]
                if method == "GET":
                    self._read_file(space_id, raw_file_path)
                    return
                if method == "PUT":
                    self._write_file(space_id, raw_file_path)
                    return
                if method == "DELETE":
                    self._delete_file(space_id, raw_file_path)
                    return
                raise ApiError(405, "method_not_allowed")
            raise ApiError(404, "not_found")
        except ApiError as exc:
            self._send_json(
                exc.status,
                {"error": exc.code},
                close_connection=exc.close_connection,
            )
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as exc:
            self._safe_internal_log("请求处理失败: " + exc.__class__.__name__)
            try:
                self._send_json(
                    500, {"error": "internal_error"}, close_connection=True
                )
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True

    def _safe_internal_log(self, message):
        self.server.access_log("PT_SYNC_INTERNAL " + message)

    def _create_space(self):
        enroll = self.headers.get("X-PT-Enroll")
        presented_hash = (
            hashlib.sha256(enroll.encode("utf-8")).hexdigest()
            if enroll is not None
            else ""
        )
        if not hmac.compare_digest(self.server.store.enroll_hash, presented_hash):
            raise ApiError(403, "forbidden")

        body = self._read_body(4096, "request_too_large")
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise ApiError(400, "bad_request") from exc
        if not isinstance(payload, dict):
            raise ApiError(400, "bad_request")
        space_id = payload.get("space")
        token_hash = payload.get("tokenSha256")
        if not isinstance(space_id, str) or SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        normalized_hash = normalize_token_hash(token_hash)
        if normalized_hash is None:
            raise ApiError(400, "bad_request")

        rev = self.server.store.create_space(
            space_id, normalized_hash, utc_now_iso()
        )
        self._send_json(201, {"space": space_id, "rev": rev})

    def _require_authorized_space(self, space_id):
        metadata = self.server.store.require_space(space_id)
        authorization = self.headers.get_all("Authorization")
        if authorization is None or len(authorization) != 1:
            raise ApiError(401, "unauthorized")
        parts = authorization[0].split(" ", 1)
        if len(parts) != 2 or parts[0] != "Bearer" or parts[1] == "":
            raise ApiError(401, "unauthorized")
        self.server.store.authenticate(space_id, parts[1])
        return metadata

    def _get_tree(self, space_id):
        self._require_authorized_space(space_id)
        rev, entries = self.server.store.list_tree(space_id)
        self._send_json(200, {"rev": rev, "entries": entries})

    def _read_file(self, space_id, raw_file_path):
        self._require_authorized_space(space_id)
        decoded_path = decode_file_path(raw_file_path)
        content = self.server.store.read_file(space_id, decoded_path)
        self._send_bytes(200, content)

    def _write_file(self, space_id, raw_file_path):
        self._require_authorized_space(space_id)
        decoded_path = decode_file_path(raw_file_path)
        validate_file_path(
            self.server.store.files_directory(space_id), decoded_path
        )
        content = self._read_body(
            self.server.store.max_file_bytes, "file_too_large"
        )
        rev = self.server.store.write_file(space_id, decoded_path, content)
        self._send_json(200, {"rev": rev})

    def _delete_file(self, space_id, raw_file_path):
        self._require_authorized_space(space_id)
        decoded_path = decode_file_path(raw_file_path)
        rev = self.server.store.delete_file(space_id, decoded_path)
        self._send_json(200, {"rev": rev})

    def _watch_space(self, space_id, query):
        self._require_authorized_space(space_id)
        values = urllib.parse.parse_qs(query, keep_blank_values=True)

        def single_value(name):
            items = values.get(name)
            return items[0] if items is not None and len(items) == 1 else None

        rev_value = single_value("rev")
        if rev_value is None:
            raise ApiError(400, "bad_request")
        try:
            known_rev = int(rev_value, 10)
        except ValueError as exc:
            raise ApiError(400, "bad_request") from exc
        if known_rev < 0:
            raise ApiError(400, "bad_request")

        timeout_value = single_value("timeout")
        if timeout_value is None and "timeout" in values:
            raise ApiError(400, "bad_request")
        if timeout_value is None:
            timeout = DEFAULT_WATCH_TIMEOUT
        else:
            try:
                timeout = float(timeout_value)
            except ValueError as exc:
                raise ApiError(400, "bad_request") from exc
            if (
                not math.isfinite(timeout)
                or timeout < 0
                or timeout > MAX_WATCH_TIMEOUT
            ):
                raise ApiError(400, "bad_request")

        rev = self.server.store.watch(space_id, known_rev, timeout)
        self._send_json(200, {"rev": rev})

    def _require_content_length(self):
        values = self.headers.get_all("Content-Length")
        if values is None:
            raise ApiError(411, "length_required", close_connection=True)
        if len(values) != 1:
            raise ApiError(400, "bad_request", close_connection=True)
        try:
            length = int(values[0], 10)
        except ValueError as exc:
            raise ApiError(400, "bad_request", close_connection=True) from exc
        if length < 0:
            raise ApiError(400, "bad_request", close_connection=True)
        return length

    def _read_body(self, limit, oversize_code):
        length = self._require_content_length()
        if length > limit:
            raise ApiError(413, oversize_code, close_connection=True)
        chunks = []
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 64 * 1024))
            if not chunk:
                raise ApiError(400, "bad_request", close_connection=True)
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _send_json(self, status, value, close_connection=False):
        content = json.dumps(
            value, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        if close_connection or status >= 400:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(content)
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True

    def _send_bytes(self, status, content):
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(content)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True


def stderr_access_log(line):
    print(line, file=sys.stderr, flush=True)


def create_server(
    host,
    port,
    state_dir,
    enroll_hash_file,
    max_spaces=DEFAULT_MAX_SPACES,
    max_file_bytes=DEFAULT_MAX_FILE_BYTES,
    max_space_bytes=DEFAULT_MAX_SPACE_BYTES,
    access_log=None,
):
    """构造已绑定端口的服务器，供 CLI 与进程内测试共用。"""

    if max_spaces <= 0:
        raise ValueError("max_spaces 必须大于 0")
    if max_file_bytes <= 0:
        raise ValueError("max_file_bytes 必须大于 0")
    if max_space_bytes <= 0:
        raise ValueError("max_space_bytes 必须大于 0")
    enroll_hash = load_enroll_hash(enroll_hash_file)
    store = SpaceStore(
        state_dir,
        enroll_hash,
        max_spaces,
        max_file_bytes,
        max_space_bytes,
    )
    sink = access_log if access_log is not None else stderr_access_log
    return PtSyncHTTPServer(
        (host, int(port)),
        SyncRequestHandler,
        store,
        sink,
    )


def run_server(args):
    server = create_server(
        args.host,
        args.port,
        args.state_dir,
        args.enroll_hash_file,
        args.max_spaces,
        args.max_file_bytes,
        args.max_space_bytes,
    )
    serve_thread = threading.Thread(
        target=server.serve_forever,
        name="pt-sync-http",
        daemon=True,
    )

    def request_stop(_signum, _frame):
        server.store.wake_all()
        server.shutdown()

    previous_sigterm = signal.signal(signal.SIGTERM, request_stop)
    previous_sigint = signal.signal(signal.SIGINT, request_stop)
    try:
        serve_thread.start()
        actual_port = server.server_address[1]
        print("PT_SYNC_READY %d" % actual_port, flush=True)
        while serve_thread.is_alive():
            serve_thread.join(0.5)
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        signal.signal(signal.SIGINT, previous_sigint)
        server.store.wake_all()
        if serve_thread.is_alive():
            server.shutdown()
        server.server_close()
    return 0


def command_list_spaces(args):
    spaces_root = os.path.join(os.path.abspath(args.state_dir), "spaces")
    if not os.path.isdir(spaces_root):
        return 0
    entries = []
    for entry in os.scandir(spaces_root):
        if not entry.is_dir(follow_symlinks=False):
            continue
        metadata_path = os.path.join(entry.path, META_FILE_NAME)
        if not os.path.isfile(metadata_path):
            continue
        try:
            with open(metadata_path, "r", encoding="utf-8") as handle:
                metadata = json.load(handle)
            files_count, total_bytes = directory_usage(
                os.path.join(entry.path, FILES_DIR_NAME)
            )
        except (OSError, ValueError):
            raise StorageError("无法读取空间 %s" % entry.name)
        entries.append(
            (
                entry.name,
                metadata.get("rev", "?"),
                files_count,
                total_bytes,
                metadata.get("created_at", "?"),
            )
        )
    entries.sort(key=lambda item: item[0])
    for entry in entries:
        print(
            "%s\t%s\t%s\t%s\t%s"
            % (
                entry[0],
                entry[1],
                entry[2],
                entry[3],
                entry[4],
            )
        )
    return 0


def command_delete_space(args):
    if SPACE_ID_PATTERN.fullmatch(args.space) is None:
        print("错误：空间编号格式不合法", file=sys.stderr)
        return 2
    path = os.path.join(os.path.abspath(args.state_dir), "spaces", args.space)
    if not os.path.isdir(path):
        print("错误：空间不存在", file=sys.stderr)
        return 1
    shutil.rmtree(path)
    print(args.space)
    return 0


def build_argument_parser():
    parser = argparse.ArgumentParser(description="番茄Todo 同步中转服务器")
    subparsers = parser.add_subparsers(dest="command", required=True)

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--host", default="127.0.0.1")
    serve_parser.add_argument("--port", type=int, default=9191)
    serve_parser.add_argument("--state-dir", required=True)
    serve_parser.add_argument("--enroll-hash-file", required=True)
    serve_parser.add_argument(
        "--max-spaces", type=int, default=DEFAULT_MAX_SPACES
    )
    serve_parser.add_argument(
        "--max-file-bytes", type=int, default=DEFAULT_MAX_FILE_BYTES
    )
    serve_parser.add_argument(
        "--max-space-bytes", type=int, default=DEFAULT_MAX_SPACE_BYTES
    )
    serve_parser.set_defaults(handler=run_server)

    list_parser = subparsers.add_parser("list-spaces")
    list_parser.add_argument("--state-dir", required=True)
    list_parser.set_defaults(handler=command_list_spaces)

    delete_parser = subparsers.add_parser("delete-space")
    delete_parser.add_argument("--state-dir", required=True)
    delete_parser.add_argument("--space", required=True)
    delete_parser.set_defaults(handler=command_delete_space)
    return parser


def main(argv=None):
    parser = build_argument_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except StorageError as exc:
        print("错误：%s" % exc, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())

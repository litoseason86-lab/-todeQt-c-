#!/usr/bin/env python3
"""番茄Todo 自建同步中转服务器。

服务器只保存客户端已经加密的同步文件，不理解任务、备忘录等业务内容。
实现刻意只依赖 Python 标准库，兼容 Python 3.9 与线上 Python 3.12。
"""

import argparse
import contextlib
import datetime
import hashlib
import hmac
import io
import json
import math
import os
import re
import shutil
import signal
import socket
import socketserver
import stat
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
CONTENT_LENGTH_PATTERN = re.compile(r"[0-9]+")
TEMP_PREFIX = ".pt-tmp-"
STAGE_PREFIX = ".pt-stage-"
COMMIT_FILE_NAME = "commit.json"
META_FILE_NAME = "meta.json"
FILES_DIR_NAME = "files"
DEFAULT_MAX_SPACES = 8
DEFAULT_MAX_FILE_BYTES = 70 * 1024 * 1024
DEFAULT_MAX_SPACE_BYTES = 512 * 1024 * 1024
DEFAULT_WATCH_TIMEOUT = 25.0
MAX_WATCH_TIMEOUT = 25.0
WATCH_POLL_INTERVAL = 0.25
STREAM_CHUNK_BYTES = 64 * 1024
REQUEST_SOCKET_TIMEOUT = 60


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


def is_ephemeral_name(name):
    return name.startswith(TEMP_PREFIX) or name.startswith(STAGE_PREFIX)


def cleanup_temporary_files(root, preserved_directories=()):
    """清掉上次进程异常退出后留下的临时文件和临时目录，不跟随符号链接。

    preserved_directories 里的目录整棵跳过：它们是启动前滚失败的空间，暂存文件还要留给下次前滚。
    """

    if not os.path.isdir(root):
        return
    preserved = {os.path.normpath(path) for path in preserved_directories}
    for current_root, directories, files in os.walk(root, followlinks=False):
        if os.path.normpath(current_root) in preserved:
            directories[:] = []
            continue
        kept_directories = []
        for name in directories:
            dir_path = os.path.join(current_root, name)
            if os.path.islink(dir_path):
                continue
            if is_ephemeral_name(name):
                shutil.rmtree(dir_path, ignore_errors=True)
                continue
            kept_directories.append(name)
        directories[:] = kept_directories
        for name in files:
            if not is_ephemeral_name(name):
                continue
            path = os.path.join(current_root, name)
            if os.path.islink(path):
                continue
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def remove_space_directory(spaces_root, space_id):
    """先把空间目录同级重命名到临时目录再递归删除，避免并发请求观察到半删状态。"""

    space_dir = os.path.join(spaces_root, space_id)
    if not os.path.isdir(space_dir) or os.path.islink(space_dir):
        return False
    staging_root = tempfile.mkdtemp(prefix=TEMP_PREFIX, dir=spaces_root)
    moved_path = os.path.join(staging_root, "space")
    try:
        os.rename(space_dir, moved_path)
    except FileNotFoundError:
        shutil.rmtree(staging_root, ignore_errors=True)
        return False
    except OSError:
        shutil.rmtree(staging_root, ignore_errors=True)
        raise
    shutil.rmtree(staging_root, ignore_errors=True)
    return True


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
            or is_ephemeral_name(segment)
        ):
            raise ApiError(400, "bad_path")

    root_real = os.path.realpath(str(files_root))
    # 逐段拒绝符号链接：既防越界，也防止空间内符号链接借 realpath 误删或误改目标文件。
    probe = root_real
    for segment in segments:
        probe = os.path.join(probe, segment)
        if os.path.islink(probe):
            raise ApiError(400, "bad_path")
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
    """统计空间占用；用递归 scandir 减少每文件重复 stat，跳过符号链接和临时文件。"""

    if not os.path.isdir(files_root):
        return 0, 0
    count = 0
    total_bytes = 0
    stack = [files_root]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as scan_it:
                for entry in scan_it:
                    name = entry.name
                    if is_ephemeral_name(name):
                        continue
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                        elif entry.is_file(follow_symlinks=False):
                            total_bytes += entry.stat(
                                follow_symlinks=False
                            ).st_size
                            count += 1
                    except FileNotFoundError:
                        continue
        except FileNotFoundError:
            continue
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
        self._cache_lock = threading.Lock()
        self._meta_cache = {}
        self._usage_cache = {}

        os.makedirs(self.spaces_root, exist_ok=True)
        # 必须在清理临时文件之前重放未完成的提交日志，确保上次崩溃前已落盘的 .pt-stage-* 暂存件完成前滚。
        unrecovered = self._recover_all_spaces()
        cleanup_temporary_files(
            self.spaces_root,
            [self.space_directory(space_id) for space_id in unrecovered],
        )

    def space_directory(self, space_id):
        return os.path.join(self.spaces_root, space_id)

    def files_directory(self, space_id):
        return os.path.join(self.space_directory(space_id), FILES_DIR_NAME)

    def metadata_path(self, space_id):
        return os.path.join(self.space_directory(space_id), META_FILE_NAME)

    def commit_path(self, space_id):
        return os.path.join(self.space_directory(space_id), COMMIT_FILE_NAME)

    def _invalidate_caches(self, space_id, usage=True):
        with self._cache_lock:
            self._meta_cache.pop(space_id, None)
            if usage:
                self._usage_cache.pop(space_id, None)

    def _read_metadata_cached(self, space_id):
        path = self.metadata_path(space_id)
        try:
            st = os.stat(path)
        except FileNotFoundError as exc:
            self._invalidate_caches(space_id, usage=True)
            raise ApiError(404, "space_not_found") from exc
        except OSError as exc:
            self._invalidate_caches(space_id, usage=False)
            raise StorageError("空间元数据不可读") from exc
        if not stat.S_ISREG(st.st_mode):
            self._invalidate_caches(space_id, usage=False)
            raise StorageError("空间元数据不可读")
        stat_key = (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)
        with self._cache_lock:
            cached = self._meta_cache.get(space_id)
            if cached is not None and cached[0] == stat_key:
                return dict(cached[1])
        value = self.read_metadata(space_id)
        with self._cache_lock:
            self._meta_cache[space_id] = (stat_key, dict(value))
        return value

    def _space_dir_key(self, space_id):
        try:
            st = os.stat(self.files_directory(space_id))
        except FileNotFoundError as exc:
            self._invalidate_caches(space_id, usage=True)
            raise ApiError(404, "space_not_found") from exc
        except OSError as exc:
            raise StorageError("无法读取空间文件目录") from exc
        return (st.st_dev, st.st_ino)

    def _space_total_bytes(self, space_id):
        """在空间锁内以 O(1) 返回当前空间字节用量；目录变更或缓存失效时自动重算。"""

        dir_key = self._space_dir_key(space_id)
        with self._cache_lock:
            cached = self._usage_cache.get(space_id)
            if cached is not None and cached[0] == dir_key:
                return cached[1]
        _, total = directory_usage(self.files_directory(space_id))
        with self._cache_lock:
            self._usage_cache[space_id] = (dir_key, total)
        return total

    def _adjust_usage_cache(self, space_id, delta_bytes):
        try:
            dir_key = self._space_dir_key(space_id)
        except (ApiError, StorageError):
            with self._cache_lock:
                self._usage_cache.pop(space_id, None)
            return
        with self._cache_lock:
            cached = self._usage_cache.get(space_id)
            if cached is not None and cached[0] == dir_key:
                new_total = cached[1] + delta_bytes
                if new_total >= 0:
                    self._usage_cache[space_id] = (dir_key, new_total)
                else:
                    self._usage_cache.pop(space_id, None)

    def _read_commit_record(self, space_id):
        path = self.commit_path(space_id)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                record = json.load(handle)
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as exc:
            raise StorageError("提交日志不可读") from exc
        if (
            not isinstance(record, dict)
            or record.get("v") != 1
            or record.get("op") not in ("put", "delete")
            or not isinstance(record.get("path"), str)
            or not isinstance(record.get("target_rev"), int)
            or record["target_rev"] < 1
        ):
            raise StorageError("提交日志格式错误")
        stage = record.get("stage")
        if record["op"] == "put":
            if (
                not isinstance(stage, str)
                or not stage.startswith(STAGE_PREFIX)
                or "/" in stage
                or "\\" in stage
            ):
                raise StorageError("提交日志暂存文件名无效")
        elif stage is not None:
            raise StorageError("删除提交日志不应包含暂存文件")
        return record

    def _apply_commit(
        self, space_id, commit_data, condition, old_size=None, update_cache=False
    ):
        """幂等执行已落盘的 commit.json 前滚：应用文件变更、推进 meta.json 版本并清理提交日志。"""

        commit_file = self.commit_path(space_id)
        space_dir = self.space_directory(space_id)
        try:
            _, target = validate_file_path(
                self.files_directory(space_id), commit_data["path"]
            )
            if commit_data["op"] == "put":
                stage_path = os.path.join(space_dir, commit_data["stage"])
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.lexists(stage_path):
                    os.replace(stage_path, target)
                elif not os.path.isfile(target):
                    raise StorageError("提交日志对应的暂存文件缺失")
                fsync_directory(os.path.dirname(target))
            else:
                if os.path.lexists(target):
                    try:
                        os.unlink(target)
                    except FileNotFoundError:
                        pass
                parent_dir = os.path.dirname(target)
                if os.path.isdir(parent_dir):
                    fsync_directory(parent_dir)

            current_meta = self.read_metadata(space_id)
            target_rev = commit_data["target_rev"]
            if current_meta["rev"] < target_rev:
                current_meta["rev"] = target_rev
                atomic_write_json(self.metadata_path(space_id), current_meta)
            else:
                # 上一次可能在 meta.json 改名后、目录刷写前失败；此处补齐刷写。
                fsync_directory(space_dir)

            self._invalidate_caches(space_id, usage=False)
            try:
                os.unlink(commit_file)
            except FileNotFoundError:
                pass
            fsync_directory(space_dir)

            if update_cache and old_size is not None:
                new_size = (
                    commit_data.get("size", 0)
                    if commit_data["op"] == "put"
                    else 0
                )
                self._adjust_usage_cache(space_id, new_size - old_size)
            else:
                self._invalidate_caches(space_id, usage=True)
            condition.notify_all()
            return target_rev
        except Exception:
            self._invalidate_caches(space_id, usage=True)
            # 提交点已过；若此处发生瞬时刷写失败，唤醒观察者以便下次访问立即前滚收敛。
            condition.notify_all()
            raise

    def _recover_pending_commit(self, space_id, condition):
        """在空间锁内检查并前滚未完成的 commit.json；无提交日志时 O(1) 返回。"""

        commit_file = self.commit_path(space_id)
        if not os.path.lexists(commit_file):
            return
        record = self._read_commit_record(space_id)
        if record is None:
            return
        self._apply_commit(
            space_id, record, condition, old_size=None, update_cache=False
        )

    def _recover_all_spaces(self):
        """启动时前滚各空间未完成的提交；返回前滚失败、需要保留暂存文件的空间编号。"""

        unrecovered = []
        try:
            entries = os.scandir(self.spaces_root)
        except OSError as exc:
            raise StorageError("无法扫描空间目录以执行恢复") from exc
        with entries:
            for entry in entries:
                if is_ephemeral_name(entry.name):
                    continue
                if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                    continue
                if SPACE_ID_PATTERN.fullmatch(entry.name) is None:
                    continue
                if not os.path.isfile(os.path.join(entry.path, META_FILE_NAME)):
                    continue
                condition = self.condition_for(entry.name)
                with condition:
                    try:
                        self._recover_pending_commit(entry.name, condition)
                    except (StorageError, ApiError, OSError) as exc:
                        # 单个空间的提交日志损坏或此刻写不进去，不能让整个服务起不来、连累其它空间。
                        # 记下后跳过：该空间每次被访问都会再试前滚并报存储错误，暂存文件留给下次前滚或人工处理。
                        unrecovered.append(entry.name)
                        print(
                            "PT_SYNC_INTERNAL 启动前滚失败，空间 %s 保持待恢复: %s"
                            % (entry.name, exc.__class__.__name__),
                            file=sys.stderr,
                            flush=True,
                        )
        return unrecovered

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
        except FileNotFoundError as exc:
            raise ApiError(404, "space_not_found") from exc
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
                if is_ephemeral_name(entry.name):
                    continue
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

        condition = self.condition_for(space_id)
        with condition:
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
                    fsync_directory(self.spaces_root)
                except Exception:
                    shutil.rmtree(space_directory, ignore_errors=True)
                    raise
            self._invalidate_caches(space_id, usage=True)
        return 0

    def delete_space(self, space_id):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        if not os.path.isdir(self.space_directory(space_id)):
            raise ApiError(404, "space_not_found")

        condition = self.condition_for(space_id)
        with condition:
            with self._registry_lock:
                try:
                    removed = remove_space_directory(self.spaces_root, space_id)
                except OSError as exc:
                    raise StorageError("无法删除同步空间") from exc
            self._invalidate_caches(space_id, usage=True)
            if not removed:
                raise ApiError(404, "space_not_found")
            condition.notify_all()

    def require_space(self, space_id):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        return self._read_metadata_cached(space_id)

    def authenticate(self, space_id, token):
        metadata = self.require_space(space_id)
        actual_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        if not hmac.compare_digest(metadata["token_sha256"], actual_hash):
            raise ApiError(401, "unauthorized")
        return metadata

    def list_tree(self, space_id):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        if not os.path.isdir(self.space_directory(space_id)):
            raise ApiError(404, "space_not_found")

        condition = self.condition_for(space_id)
        with condition:
            # 先前滚任何未完成提交，再在同一把空间锁内读 meta.json 与枚举目录树，
            # 既消除崩溃/异常窗口的半提交视图，也防止并发写入造成新 rev 配旧文件列表。
            self._recover_pending_commit(space_id, condition)
            metadata = self.require_space(space_id)
            files_root = self.files_directory(space_id)
            entries = []

            def visit(directory, prefix):
                try:
                    with os.scandir(directory) as scan_it:
                        children = list(scan_it)
                except FileNotFoundError as exc:
                    if not self.space_exists(space_id):
                        raise ApiError(404, "space_not_found") from exc
                    raise StorageError("无法枚举空间文件") from exc
                except OSError as exc:
                    raise StorageError("无法枚举空间文件") from exc
                children.sort(key=lambda item: item.name)
                for child in children:
                    if child.is_symlink() or is_ephemeral_name(child.name):
                        continue
                    relative = (
                        child.name
                        if prefix == ""
                        else prefix + "/" + child.name
                    )
                    if child.is_dir(follow_symlinks=False):
                        entries.append({"path": relative, "type": "dir"})
                        visit(child.path, relative)
                    elif child.is_file(follow_symlinks=False):
                        try:
                            size = child.stat(follow_symlinks=False).st_size
                        except FileNotFoundError:
                            continue
                        entries.append(
                            {"path": relative, "type": "file", "size": size}
                        )

            visit(files_root, "")
            entries.sort(key=lambda item: item["path"])
            return metadata["rev"], entries

    @contextlib.contextmanager
    def open_file(self, space_id, decoded_path):
        """在空间锁内打开已提交文件的不可变 inode，供锁外流式读取。"""

        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        if not os.path.isdir(self.space_directory(space_id)):
            raise ApiError(404, "space_not_found")

        condition = self.condition_for(space_id)
        handle = None
        with condition:
            self._recover_pending_commit(space_id, condition)
            self.require_space(space_id)
            _, target = validate_file_path(
                self.files_directory(space_id), decoded_path
            )
            if not os.path.isfile(target) or os.path.islink(target):
                raise ApiError(404, "file_not_found")
            try:
                # 服务端所有修改都通过同文件系统暂存文件 os.replace 替换目录项，从不原地覆写已有 inode；
                # 在锁内打开文件句柄即可隔离未提交的写入，且锁外流式发送期间内容恒定不变。
                handle = open(target, "rb")
                stat_result = os.fstat(handle.fileno())
            except FileNotFoundError as exc:
                if handle is not None:
                    handle.close()
                raise ApiError(404, "file_not_found") from exc
            except IsADirectoryError as exc:
                if handle is not None:
                    handle.close()
                raise ApiError(404, "file_not_found") from exc
            except OSError as exc:
                if handle is not None:
                    handle.close()
                raise StorageError("无法读取同步文件") from exc
            if not stat.S_ISREG(stat_result.st_mode):
                handle.close()
                raise ApiError(404, "file_not_found")
            size = stat_result.st_size

        try:
            yield handle, size
        finally:
            handle.close()

    def read_file(self, space_id, decoded_path):
        with self.open_file(space_id, decoded_path) as (handle, _size):
            try:
                return handle.read()
            except OSError as exc:
                raise StorageError("无法读取同步文件") from exc

    def write_file(self, space_id, decoded_path, content):
        return self.write_file_stream(
            space_id, decoded_path, io.BytesIO(content), len(content)
        )

    def write_file_stream(self, space_id, decoded_path, stream, content_length):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space", close_connection=True)
        if not isinstance(content_length, int) or content_length < 0:
            raise ApiError(400, "bad_request", close_connection=True)
        self.require_space(space_id)
        relative_path, preliminary_target = validate_file_path(
            self.files_directory(space_id), decoded_path
        )
        if content_length > self.max_file_bytes:
            raise ApiError(413, "file_too_large", close_connection=True)
        if content_length > self.max_space_bytes:
            raise ApiError(507, "quota_exceeded", close_connection=True)
        if os.path.isdir(preliminary_target):
            raise ApiError(409, "is_directory", close_connection=True)

        # 先在锁外将请求流按 64 KiB 分块写入同空间目录的暂存文件并落盘，
        # 既消除 Python 堆上的双倍整包缓冲，也避免慢速网络上传长期霸占空间锁阻塞 watch 与读请求。
        space_dir = self.space_directory(space_id)
        try:
            descriptor, temporary = tempfile.mkstemp(
                prefix=STAGE_PREFIX, dir=space_dir
            )
        except FileNotFoundError as exc:
            raise ApiError(404, "space_not_found", close_connection=True) from exc
        except OSError as exc:
            raise StorageError("无法创建同步临时文件") from exc

        commit_attempted = False
        try:
            with os.fdopen(descriptor, "wb") as handle:
                remaining = content_length
                while remaining > 0:
                    chunk = stream.read(min(remaining, STREAM_CHUNK_BYTES))
                    if not chunk:
                        raise ApiError(
                            400, "bad_request", close_connection=True
                        )
                    handle.write(chunk)
                    remaining -= len(chunk)
                handle.flush()
                os.fsync(handle.fileno())

            condition = self.condition_for(space_id)
            with condition:
                self._recover_pending_commit(space_id, condition)
                metadata = self.require_space(space_id)
                relative_path, target = validate_file_path(
                    self.files_directory(space_id), relative_path
                )
                if os.path.isdir(target):
                    raise ApiError(409, "is_directory")

                old_size = 0
                if os.path.isfile(target):
                    try:
                        old_size = os.stat(
                            target, follow_symlinks=False
                        ).st_size
                    except FileNotFoundError:
                        old_size = 0

                current_total = self._space_total_bytes(space_id)
                if (
                    current_total - old_size + content_length
                    > self.max_space_bytes
                ):
                    raise ApiError(507, "quota_exceeded")

                try:
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                except (FileExistsError, NotADirectoryError) as exc:
                    raise ApiError(409, "is_directory") from exc

                relative_path, target = validate_file_path(
                    self.files_directory(space_id), relative_path
                )
                commit_file = self.commit_path(space_id)
                commit_data = {
                    "v": 1,
                    "op": "put",
                    "path": relative_path,
                    "stage": os.path.basename(temporary),
                    "target_rev": metadata["rev"] + 1,
                    "size": content_length,
                }
                # commit.json 落盘即唯一提交点：此步之前失败安全回滚（旧文件与旧 rev 不动）；
                # 此步之后任何步骤失败或进程中断，都会在下次访问或重启时幂等前滚到一致状态。
                commit_attempted = True
                try:
                    atomic_write_json(commit_file, commit_data)
                except Exception:
                    if os.path.lexists(commit_file):
                        condition.notify_all()
                    raise
                return self._apply_commit(
                    space_id,
                    commit_data,
                    condition,
                    old_size=old_size,
                    update_cache=True,
                )
        finally:
            # 只有尚未进入提交点（commit.json 不存在）时才清理暂存文件；
            # 若 commit.json 已落盘，必须保留暂存文件供后续前滚恢复使用。
            if os.path.lexists(temporary) and not (
                commit_attempted and os.path.lexists(self.commit_path(space_id))
            ):
                try:
                    os.unlink(temporary)
                except OSError:
                    pass

    def delete_file(self, space_id, decoded_path):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        if not os.path.isdir(self.space_directory(space_id)):
            raise ApiError(404, "space_not_found")

        condition = self.condition_for(space_id)
        with condition:
            self._recover_pending_commit(space_id, condition)
            metadata = self.require_space(space_id)
            relative_path, target = validate_file_path(
                self.files_directory(space_id), decoded_path
            )
            if os.path.isdir(target) and not os.path.islink(target):
                raise ApiError(409, "is_directory")
            if not os.path.lexists(target):
                return metadata["rev"]

            try:
                old_size = os.stat(target, follow_symlinks=False).st_size
            except FileNotFoundError:
                return metadata["rev"]
            except OSError as exc:
                raise StorageError("无法读取待删除同步文件信息") from exc

            commit_file = self.commit_path(space_id)
            commit_data = {
                "v": 1,
                "op": "delete",
                "path": relative_path,
                "target_rev": metadata["rev"] + 1,
            }
            try:
                atomic_write_json(commit_file, commit_data)
            except Exception:
                if os.path.lexists(commit_file):
                    condition.notify_all()
                raise
            return self._apply_commit(
                space_id,
                commit_data,
                condition,
                old_size=old_size,
                update_cache=True,
            )

    def watch(self, space_id, known_rev, timeout):
        if SPACE_ID_PATTERN.fullmatch(space_id) is None:
            raise ApiError(400, "bad_space")
        if not os.path.isdir(self.space_directory(space_id)):
            raise ApiError(404, "space_not_found")

        condition = self.condition_for(space_id)
        deadline = time.monotonic() + timeout
        with condition:
            self._recover_pending_commit(space_id, condition)
            current_rev = self.require_space(space_id)["rev"]
            if current_rev != known_rev:
                return current_rev
            while current_rev == known_rev and not self.shutting_down.is_set():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                # 同进程写删通过 notify_all 即时唤醒；限制单次等待步长可让外部 delete-space
                # 管理命令删掉空间目录时，阻塞中的 watch 在亚秒级感知并返回 404。
                condition.wait(min(remaining, WATCH_POLL_INTERVAL))
                self._recover_pending_commit(space_id, condition)
                current_rev = self.require_space(space_id)["rev"]
            return current_rev


class PtSyncHTTPServer(ThreadingHTTPServer):
    """支持 keep-alive 的线程服务器；每个请求线程不阻塞主退出流程。"""

    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, handler_class, store, access_log):
        self.store = store
        self.access_log = access_log
        ThreadingHTTPServer.__init__(self, address, handler_class)

    def server_bind(self):
        # 跳过标准库 HTTPServer 默认的 socket.getfqdn() 反向 DNS 查询：纯 IP 监听不需要 PTR 主机名，
        # 否则无本地 PTR 缓存的环境每次绑定都会被 DNS 超时卡住数秒乃至数十秒。
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)


class SyncRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pt-sync/1"
    sys_version = ""
    # 为空闲 Keep-Alive 连接与慢速请求读写设置套接字超时，防止半开连接长期占用工作线程。
    timeout = REQUEST_SOCKET_TIMEOUT

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
            self._validate_framing_headers(method)
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
                close_connection=exc.close_connection or exc.status >= 400,
            )
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True
        except Exception as exc:
            self._safe_internal_log("请求处理失败: " + exc.__class__.__name__)
            try:
                self._send_json(
                    500, {"error": "internal_error"}, close_connection=True
                )
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                self.close_connection = True

    def _validate_framing_headers(self, method):
        # 同步协议不支持分块传输编码；遇到任何 Transfer-Encoding 或带请求体的无体方法（如 GET/DELETE）
        # 立即拒绝并断开底层连接，防止残留包体字节在同一 Keep-Alive 连接上形成请求走私。
        if self.headers.get_all("Transfer-Encoding") is not None:
            raise ApiError(400, "bad_request", close_connection=True)
        if method not in ("POST", "PUT"):
            self._reject_unexpected_body()

    def _parse_single_content_length(self, values):
        if len(values) != 1:
            raise ApiError(400, "bad_request", close_connection=True)
        raw_value = values[0].strip()
        if CONTENT_LENGTH_PATTERN.fullmatch(raw_value) is None:
            raise ApiError(400, "bad_request", close_connection=True)
        return int(raw_value, 10)

    def _reject_unexpected_body(self):
        values = self.headers.get_all("Content-Length")
        if values is None:
            return
        length = self._parse_single_content_length(values)
        if length > 0:
            raise ApiError(400, "bad_request", close_connection=True)

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
        actual_hash = hashlib.sha256(parts[1].encode("utf-8")).hexdigest()
        if not hmac.compare_digest(metadata["token_sha256"], actual_hash):
            raise ApiError(401, "unauthorized")
        return metadata

    def _get_tree(self, space_id):
        self._require_authorized_space(space_id)
        rev, entries = self.server.store.list_tree(space_id)
        self._send_json(200, {"rev": rev, "entries": entries})

    def _read_file(self, space_id, raw_file_path):
        self._require_authorized_space(space_id)
        decoded_path = decode_file_path(raw_file_path)
        with self.server.store.open_file(space_id, decoded_path) as (
            handle,
            size,
        ):
            self._send_stream(200, handle, size)

    def _write_file(self, space_id, raw_file_path):
        self._require_authorized_space(space_id)
        decoded_path = decode_file_path(raw_file_path)
        validate_file_path(
            self.server.store.files_directory(space_id), decoded_path
        )
        content_length = self._require_content_length()
        rev = self.server.store.write_file_stream(
            space_id, decoded_path, self.rfile, content_length
        )
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
        return self._parse_single_content_length(values)

    def _read_body(self, limit, oversize_code):
        length = self._require_content_length()
        if length > limit:
            raise ApiError(413, oversize_code, close_connection=True)
        buffer = bytearray()
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, STREAM_CHUNK_BYTES))
            if not chunk:
                raise ApiError(400, "bad_request", close_connection=True)
            buffer.extend(chunk)
            remaining -= len(chunk)
        return bytes(buffer)

    def _send_json(self, status, value, close_connection=False):
        content = json.dumps(
            value, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        # 任何 4xx/5xx 错误响应一律强制关闭底层连接，杜绝协议错误或大包体拒绝后残留半读流被复用。
        if close_connection or status >= 400:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(content)
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                self.close_connection = True

    def _send_stream(self, status, handle, size):
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        if status >= 400:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command == "HEAD":
            return
        sent = 0
        try:
            while sent < size:
                chunk = handle.read(min(size - sent, STREAM_CHUNK_BYTES))
                if not chunk:
                    self.close_connection = True
                    break
                self.wfile.write(chunk)
                sent += len(chunk)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True

    def _send_bytes(self, status, content):
        self._send_stream(status, io.BytesIO(content), len(content))


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

    stop_event = threading.Event()

    def request_stop(_signum, _frame):
        # 信号处理函数内严禁获取业务锁或调用 server.shutdown()，避免连续信号或主线程重入死锁；
        # 仅置位事件，由主线程退出等待后按顺序唤醒 watch 并关闭监听。
        stop_event.set()

    previous_sigterm = signal.signal(signal.SIGTERM, request_stop)
    previous_sigint = signal.signal(signal.SIGINT, request_stop)
    try:
        serve_thread.start()
        actual_port = server.server_address[1]
        print("PT_SYNC_READY %d" % actual_port, flush=True)
        while serve_thread.is_alive() and not stop_event.is_set():
            stop_event.wait(0.5)
    finally:
        # 关闭收尾期间保留信号处理器，避免 systemd 或人工连续发送 SIGTERM 时在 server.shutdown()
        # 尚未完成就被默认处理器直接以 -15 终止进程；全部收尾后再恢复原处理器。
        try:
            server.store.wake_all()
            if serve_thread.is_alive():
                server.shutdown()
                serve_thread.join(5.0)
            server.server_close()
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm)
            signal.signal(signal.SIGINT, previous_sigint)
    return 0


def command_list_spaces(args):
    spaces_root = os.path.join(os.path.abspath(args.state_dir), "spaces")
    if not os.path.isdir(spaces_root):
        return 0
    entries = []
    with os.scandir(spaces_root) as scan_it:
        for entry in scan_it:
            if is_ephemeral_name(entry.name):
                continue
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
            except FileNotFoundError:
                continue
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
    spaces_root = os.path.join(os.path.abspath(args.state_dir), "spaces")
    if not os.path.isdir(spaces_root):
        print("错误：空间不存在", file=sys.stderr)
        return 1
    try:
        removed = remove_space_directory(spaces_root, args.space)
    except OSError as exc:
        raise StorageError("无法删除同步空间") from exc
    if not removed:
        print("错误：空间不存在", file=sys.stderr)
        return 1
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

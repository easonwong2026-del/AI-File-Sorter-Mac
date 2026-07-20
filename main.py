#!/usr/bin/env python3
"""程序入口：由 launchd 的 WatchPaths 事件唤醒，确认文件稳定后执行整理。"""

import argparse
import fcntl
import json
import os
import signal
import sys
import time
from pathlib import Path
from typing import Any, Dict, Optional, Set, Tuple

from sorter import FileSorter, file_signature


PROJECT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = PROJECT_DIR / "config.json"


def acquire_process_lock(lock_path: Path):
    """防止 LaunchAgent 与“立即整理”同时搬动同一个文件。"""
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return handle
    except BlockingIOError:
        handle.close()
        return None


class StateStore:
    """保存已见文件状态，防止重启后反复处理未分类文件。"""

    def __init__(self, path: Path):
        self.path = path
        self.data: Dict[str, Any] = {"version": 1, "initialized": False, "rules_fingerprint": "", "files": {}}
        self.dirty = False
        if path.exists():
            try:
                with path.open("r", encoding="utf-8") as handle:
                    loaded = json.load(handle)
                if loaded.get("version") == 1 and isinstance(loaded.get("files"), dict):
                    self.data = loaded
            except (OSError, json.JSONDecodeError):
                # 状态损坏不影响主功能；重新建立即可。
                self.dirty = True

    @staticmethod
    def _key(path: Path) -> str:
        return str(path.resolve())

    def prepare_rules(self, fingerprint: str) -> None:
        """规则变化时只释放 unknown，首次安装基线仍保持不动。"""
        if self.data.get("rules_fingerprint") == fingerprint:
            return
        files = self.data.get("files", {})
        self.data["files"] = {
            key: value for key, value in files.items() if value.get("reason") != "unknown"
        }
        self.data["rules_fingerprint"] = fingerprint
        self.dirty = True

    def is_handled(self, path: Path, signature: Tuple[int, int]) -> bool:
        record = self.data.get("files", {}).get(self._key(path))
        return bool(record and record.get("size") == signature[0] and record.get("mtime_ns") == signature[1])

    def mark(self, path: Path, signature: Tuple[int, int], reason: str) -> None:
        self.data.setdefault("files", {})[self._key(path)] = {
            "size": signature[0],
            "mtime_ns": signature[1],
            "reason": reason,
        }
        self.dirty = True

    def initialize(self) -> None:
        self.data["initialized"] = True
        self.dirty = True

    def prune(self, current_paths: Set[str]) -> None:
        files = self.data.setdefault("files", {})
        stale = [key for key in files if key not in current_paths]
        for key in stale:
            del files[key]
            self.dirty = True

    def save(self) -> None:
        """原子写入状态，避免断电造成半个 JSON 文件。"""
        if not self.dirty:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(self.data, handle, ensure_ascii=False, indent=2)
        os.replace(temporary, self.path)
        self.dirty = False


class EventWatcher:
    """处理一次 macOS 文件夹变更事件，目录安静后自动退出。"""

    def __init__(self, sorter: FileSorter):
        self.sorter = sorter
        self.state = StateStore(sorter.state_file)
        self.stop_requested = False

    def stop(self, _signum=None, _frame=None) -> None:
        self.stop_requested = True

    def _first_start_baseline(self, files) -> bool:
        if self.state.data.get("initialized"):
            return False
        self.state.prepare_rules(self.sorter.rules_fingerprint)
        keep_existing = not self.sorter.config.get("process_existing_on_first_start", False)
        if keep_existing:
            for path in files:
                try:
                    self.state.mark(path, file_signature(path), "baseline")
                except FileNotFoundError:
                    continue
            self.sorter.logger.info("首次启动：已保留 Downloads 中 %s 个现有文件，只监听之后的新文件", len(files))
        self.state.initialize()
        self.state.save()
        # 只有保护旧文件时才提前退出；允许处理存量时继续进入稳定性检测。
        return keep_existing

    def run_event(self) -> int:
        """launchd 调用模式：追踪正在写入的文件，处理完毕后退出。"""
        files = self.sorter.list_supported_files()
        if self._first_start_baseline(files):
            return 0

        self.state.prepare_rules(self.sorter.rules_fingerprint)
        stable_since: Dict[str, Tuple[Tuple[int, int], float]] = {}
        failed_this_run: Set[str] = set()
        started = time.monotonic()
        idle_since: Optional[float] = None

        while not self.stop_requested:
            self.sorter.reload_if_changed()
            self.state.prepare_rules(self.sorter.rules_fingerprint)
            files = self.sorter.list_supported_files()
            current_paths = {str(path.resolve()) for path in files}
            self.state.prune(current_paths)
            pending = 0
            now = time.monotonic()

            for path in files:
                key = str(path.resolve())
                try:
                    signature = file_signature(path)
                except FileNotFoundError:
                    continue
                if self.state.is_handled(path, signature) or key in failed_this_run:
                    continue
                pending += 1
                previous = stable_since.get(key)
                if previous is None or previous[0] != signature:
                    stable_since[key] = (signature, now)
                    continue
                stable_seconds = float(self.sorter.config.get("stable_seconds", 4))
                if now - previous[1] < stable_seconds:
                    continue

                result = self.sorter.sort_file(path)
                stable_since.pop(key, None)
                if result.status == "unknown":
                    self.state.mark(path, signature, "unknown")
                elif result.status == "error":
                    failed_this_run.add(key)

            self.state.save()
            if pending == 0:
                idle_since = idle_since or now
            else:
                idle_since = None

            idle_limit = float(self.sorter.config.get("event_idle_seconds", 8))
            runtime_limit = float(self.sorter.config.get("max_event_runtime_seconds", 900))
            if idle_since is not None and now - idle_since >= idle_limit:
                return 0
            if now - started >= runtime_limit:
                self.sorter.logger.warning("本次监听已达到最长运行时间，将等待下一次目录事件继续")
                return 0
            time.sleep(max(0.2, float(self.sorter.config.get("scan_interval_seconds", 2))))

        self.state.save()
        return 0

    def run_once(self) -> int:
        """手动模式：整理当前所有稳定且匹配规则的文件，不受首次基线限制。"""
        files = self.sorter.list_supported_files()
        before = {}
        for path in files:
            try:
                before[str(path.resolve())] = file_signature(path)
            except FileNotFoundError:
                pass
        time.sleep(max(0.0, float(self.sorter.config.get("stable_seconds", 4))))

        had_error = False
        for path in self.sorter.list_supported_files():
            key = str(path.resolve())
            try:
                if before.get(key) != file_signature(path):
                    self.sorter.logger.info("跳过仍在写入的文件：%s", path)
                    continue
            except FileNotFoundError:
                continue
            result = self.sorter.sort_file(path)
            had_error = had_error or result.status == "error"
        return 1 if had_error else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="AI-File-Sorter-Mac 文件自动整理工具")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="config.json 路径")
    parser.add_argument("--once", action="store_true", help="立即扫描并整理当前文件")
    parser.add_argument("--check-config", action="store_true", help="仅检查配置后退出")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        sorter = FileSorter(args.config)
        if args.check_config:
            print("配置检查通过：%s" % args.config.expanduser().resolve())
            return 0
        lock_handle = acquire_process_lock(sorter.state_file.parent / "sorter.lock")
        if lock_handle is None:
            print("已有一个整理任务正在运行，请稍后再试。")
            return 0
        try:
            watcher = EventWatcher(sorter)
            signal.signal(signal.SIGTERM, watcher.stop)
            signal.signal(signal.SIGINT, watcher.stop)
            return watcher.run_once() if args.once else watcher.run_event()
        finally:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
            lock_handle.close()
    except Exception as exc:
        print("启动失败：%s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

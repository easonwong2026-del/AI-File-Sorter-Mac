"""中文自动化测试：仅使用临时目录，不会读写用户真实的 Downloads。"""

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from main import EventWatcher, acquire_process_lock
from sorter import FileSorter


class FileSorterTests(unittest.TestCase):
    def make_config(self, root: Path, process_existing: bool = True) -> Path:
        config = {
            "watch_folder": str(root / "Downloads"),
            "log_file": str(root / "logs" / "sorter.log"),
            "state_file": str(root / "logs" / "state.json"),
            "scan_interval_seconds": 0.01,
            "stable_seconds": 0.01,
            "event_idle_seconds": 0.01,
            "max_event_runtime_seconds": 2,
            "process_existing_on_first_start": process_existing,
            "move_method": "python",
            "rename": {
                "enabled": True,
                "template": "{date}_{original_name}",
                "date_format": "%Y-%m-%d",
            },
            "supported_extensions": [".pdf", ".docx", ".xlsx", ".pptx", ".jpg", ".mp4", ".zip"],
            "rules": [{"keywords": ["Samsung", "三星"], "target": str(root / "资料库" / "三星")}],
        }
        path = root / "config.json"
        path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
        return path

    def test_rule_move_rename_and_collision(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            downloads = root / "Downloads"
            downloads.mkdir()
            config_path = self.make_config(root)
            sorter = FileSorter(config_path)

            first = downloads / "Samsung_S95F.pdf"
            first.write_text("one", encoding="utf-8")
            with patch("sorter.datetime") as mocked_datetime:
                mocked_datetime.now.return_value.strftime.return_value = "2026-07-16"
                result = sorter.sort_file(first)
            self.assertEqual(result.status, "moved")
            self.assertEqual(result.target.name, "2026-07-16_Samsung_S95F.pdf")

            second = downloads / "Samsung_S95F.pdf"
            second.write_text("two", encoding="utf-8")
            with patch("sorter.datetime") as mocked_datetime:
                mocked_datetime.now.return_value.strftime.return_value = "2026-07-16"
                result = sorter.sort_file(second)
            self.assertEqual(result.target.name, "2026-07-16_Samsung_S95F_1.pdf")

    def test_unknown_file_is_not_moved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            downloads = root / "Downloads"
            downloads.mkdir()
            sorter = FileSorter(self.make_config(root))
            source = downloads / "没有规则.pdf"
            source.write_text("data", encoding="utf-8")
            result = sorter.sort_file(source)
            self.assertEqual(result.status, "unknown")
            self.assertTrue(source.exists())

    def test_default_config_contains_editable_rules(self):
        project_config = Path(__file__).resolve().parents[1] / "config.json"
        config = json.loads(project_config.read_text(encoding="utf-8"))
        self.assertEqual(config["_config_version"], 9)
        self.assertEqual(config["organization_mode"], "review")
        self.assertEqual(config["retention_days"], 7)
        self.assertEqual(config["recent_modification_protection_hours"], 24)
        self.assertEqual(config["automatic_scan_interval_hours"], 24)
        self.assertEqual(config["excluded_paths"], [])
        self.assertIn(".csv", config["supported_extensions"])
        self.assertIn(".dmg", config["supported_extensions"])
        self.assertEqual(len(config["rules"]), 8)
        self.assertTrue(config["rules"][0]["enabled"])
        self.assertEqual(config["rules"][0]["match_mode"], "any")
        self.assertEqual(config["rules"][0]["exclude_keywords"], [])
        self.assertIn("pdf", config["rules"][0]["extensions"])
        self.assertEqual(config["rules"][0]["name"], "财务票据")
        self.assertIn("合同", config["rules"][1]["keywords"])
        self.assertEqual(config["rules"][3]["keywords"], [])
        self.assertIn("jpg", config["rules"][3]["extensions"])
        self.assertEqual(config["rules"][6]["name"], "安装包")

    def test_process_lock_prevents_two_sorters(self):
        with tempfile.TemporaryDirectory() as temporary:
            lock_path = Path(temporary) / "sorter.lock"
            first = acquire_process_lock(lock_path)
            self.assertIsNotNone(first)
            try:
                self.assertIsNone(acquire_process_lock(lock_path))
            finally:
                first.close()
            second = acquire_process_lock(lock_path)
            self.assertIsNotNone(second)
            second.close()

    def test_finder_failure_restores_original_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.pdf"
            destination_folder = root / "target"
            destination_folder.mkdir()
            destination = destination_folder / "renamed.pdf"
            source.write_text("content", encoding="utf-8")
            failed = SimpleNamespace(returncode=1, stderr="Finder test failure")
            with patch("sorter.subprocess.run", return_value=failed):
                with self.assertRaises(RuntimeError):
                    FileSorter._move_with_finder(source, destination)
            self.assertTrue(source.exists())
            self.assertEqual(source.read_text(encoding="utf-8"), "content")
            self.assertEqual(list(destination_folder.iterdir()), [])

    def test_event_watcher_processes_stable_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            downloads = root / "Downloads"
            downloads.mkdir()
            sorter = FileSorter(self.make_config(root, process_existing=True))
            source = downloads / "三星_测试.jpg"
            source.write_bytes(b"image")
            exit_code = EventWatcher(sorter).run_event()
            self.assertEqual(exit_code, 0)
            moved_files = list((root / "资料库" / "三星").glob("*.jpg"))
            self.assertEqual(len(moved_files), 1)

    def test_first_start_keeps_existing_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            downloads = root / "Downloads"
            downloads.mkdir()
            sorter = FileSorter(self.make_config(root, process_existing=False))
            source = downloads / "Samsung_旧文件.pdf"
            source.write_text("old", encoding="utf-8")
            EventWatcher(sorter).run_event()
            self.assertTrue(source.exists())
            self.assertTrue(sorter.state_file.exists())

            # 模拟首次基线完成后又下载了一个新文件；新文件必须被同一套状态识别并移动。
            new_source = downloads / "Samsung_新文件.pdf"
            new_source.write_text("new", encoding="utf-8")
            EventWatcher(FileSorter(config_path=self.make_config(root, process_existing=False))).run_event()
            self.assertFalse(new_source.exists())
            self.assertEqual(len(list((root / "资料库" / "三星").glob("*.pdf"))), 1)


if __name__ == "__main__":
    unittest.main()

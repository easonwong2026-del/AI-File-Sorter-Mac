"""核心分类与移动模块：读取规则、匹配文件名、创建目录并安全移动文件。"""

import hashlib
import json
import os
import shutil
import subprocess
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from ai_classifier import classify_file
from logger import log_result, setup_logger


PROJECT_DIR = Path(__file__).resolve().parent
TEMP_SUFFIXES = (".crdownload", ".download", ".part", ".tmp")


@dataclass
class SortResult:
    """单个文件的整理结果。"""

    status: str
    source: Path
    target: Optional[Path] = None
    detail: str = ""


def _resolve_project_path(value: str) -> Path:
    """展开用户目录；相对路径以项目目录为基准。"""
    expanded = Path(os.path.expandvars(os.path.expanduser(value)))
    return expanded if expanded.is_absolute() else PROJECT_DIR / expanded


def load_config(config_path: Path) -> Dict[str, Any]:
    """加载并校验配置，尽早给出适合新手理解的错误。"""
    try:
        with config_path.open("r", encoding="utf-8") as handle:
            config = json.load(handle)
    except FileNotFoundError as exc:
        raise ValueError("找不到配置文件：%s" % config_path) from exc
    except json.JSONDecodeError as exc:
        raise ValueError("config.json 格式错误（第 %s 行）：%s" % (exc.lineno, exc.msg)) from exc

    if not isinstance(config.get("rules"), list):
        raise ValueError("config.json 中 rules 必须是数组")
    for index, rule in enumerate(config["rules"], start=1):
        if not isinstance(rule.get("keywords"), list) or not rule.get("target"):
            raise ValueError("第 %s 条规则必须包含 keywords 数组和 target" % index)

    method = config.get("move_method", "python")
    if method not in ("python", "native", "finder"):
        raise ValueError("move_method 只能是 native 或 finder")
    return config


class FileSorter:
    """根据 config.json 对单个文件执行分类和移动。"""

    def __init__(self, config_path: Path):
        self.config_path = config_path.expanduser().resolve()
        self.config = load_config(self.config_path)
        self._config_mtime_ns = self.config_path.stat().st_mtime_ns
        self.logger = setup_logger(self.log_path)

    @property
    def log_path(self) -> Path:
        return _resolve_project_path(self.config.get("log_file", "logs/sorter.log"))

    @property
    def watch_folder(self) -> Path:
        return _resolve_project_path(self.config.get("watch_folder", "~/Downloads"))

    @property
    def state_file(self) -> Path:
        return _resolve_project_path(self.config.get("state_file", "logs/state.json"))

    @property
    def supported_extensions(self) -> set:
        values = self.config.get("supported_extensions", [])
        return {str(value).lower() for value in values}

    @property
    def rules_fingerprint(self) -> str:
        """规则变化后，让监听器重新尝试之前未分类的文件。"""
        relevant = {"rules": self.config.get("rules", []), "rename": self.config.get("rename", {})}
        content = json.dumps(relevant, ensure_ascii=False, sort_keys=True).encode("utf-8")
        return hashlib.sha256(content).hexdigest()

    def reload_if_changed(self) -> bool:
        """配置文件改变时热加载，无需手动重启。"""
        current_mtime = self.config_path.stat().st_mtime_ns
        if current_mtime == self._config_mtime_ns:
            return False
        self.config = load_config(self.config_path)
        self._config_mtime_ns = current_mtime
        self.logger.info("检测到 config.json 更新，已重新加载规则")
        return True

    def is_supported_file(self, path: Path) -> bool:
        """忽略目录、隐藏文件、下载临时文件和未支持的扩展名。"""
        if not path.is_file() or path.name.startswith("."):
            return False
        lower_name = path.name.lower()
        if lower_name.endswith(TEMP_SUFFIXES):
            return False
        return path.suffix.lower() in self.supported_extensions

    def list_supported_files(self) -> List[Path]:
        """只扫描监听目录第一层，避免意外搬动已有子目录内容。"""
        self.watch_folder.mkdir(parents=True, exist_ok=True)
        return sorted(
            (path for path in self.watch_folder.iterdir() if self.is_supported_file(path)),
            key=lambda item: item.name.casefold(),
        )

    def match_rule(self, filename: str) -> Optional[Dict[str, Any]]:
        """按配置顺序匹配；第一条命中的规则优先。"""
        folded_name = filename.casefold()
        for rule in self.config["rules"]:
            keywords = [str(keyword) for keyword in rule.get("keywords", []) if str(keyword)]
            if any(keyword.casefold() in folded_name for keyword in keywords):
                return rule
        return None

    def _destination_name(self, source: Path) -> str:
        """按可选模板重命名，并保留原扩展名。"""
        rename_config = self.config.get("rename", {})
        if not rename_config.get("enabled", False):
            return source.name

        date_format = str(rename_config.get("date_format", "%Y-%m-%d"))
        template = str(rename_config.get("template", "{date}_{original_name}"))
        rendered = template.format(
            date=datetime.now().strftime(date_format),
            original_name=source.stem,
            extension=source.suffix.lstrip("."),
        )
        safe_stem = Path(rendered).name.strip()
        if not safe_stem or safe_stem in (".", ".."):
            raise ValueError("重命名模板生成了无效文件名")
        if safe_stem.lower().endswith(source.suffix.lower()):
            return safe_stem
        return safe_stem + source.suffix

    @staticmethod
    def _avoid_collision(destination: Path) -> Path:
        """目标重名时追加序号，绝不覆盖用户已有文件。"""
        if not destination.exists():
            return destination
        counter = 1
        while True:
            candidate = destination.with_name("%s_%s%s" % (destination.stem, counter, destination.suffix))
            if not candidate.exists():
                return candidate
            counter += 1

    @staticmethod
    def _move_with_finder(source: Path, destination: Path) -> None:
        """通过 AppleScript 命令 Finder 完成移动，并在 Finder 中完成最终命名。"""
        staging_name = ".aisorter-%s-%s" % (uuid.uuid4().hex, source.name)
        staging_source = source.with_name(staging_name)
        source.rename(staging_source)
        script = """
on run argv
    set sourcePath to item 1 of argv
    set targetPath to item 2 of argv
    set finalName to item 3 of argv
    tell application "Finder"
        set movedItem to move (POSIX file sourcePath as alias) to (POSIX file targetPath as alias)
        set name of movedItem to finalName
    end tell
end run
"""
        try:
            completed = subprocess.run(
                ["/usr/bin/osascript", "-e", script, str(staging_source), str(destination.parent), destination.name],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            if completed.returncode != 0:
                raise RuntimeError(completed.stderr.strip() or "Finder 移动失败")
        except Exception:
            # Finder 未接管或只移动未重命名时回滚，避免留下隐藏的暂存文件。
            if staging_source.exists() and not source.exists():
                staging_source.rename(source)
            moved_staging = destination.parent / staging_name
            if moved_staging.exists() and not source.exists() and not destination.exists():
                shutil.move(str(moved_staging), str(source))
            raise

    def sort_file(self, source: Path) -> SortResult:
        """整理一个稳定文件；无规则时仅调用本地 AI 占位接口，不移动文件。"""
        source = source.expanduser().resolve()
        if not self.is_supported_file(source):
            return SortResult("ignored", source, detail="不支持的类型或临时文件")

        rule = self.match_rule(source.name)
        target_folder_value: Optional[str] = None
        matched_by = "规则"
        if rule:
            target_folder_value = str(rule["target"])
        else:
            ai_result = classify_file(str(source))
            if ai_result.get("category") != "unknown" and ai_result.get("target_folder"):
                target_folder_value = ai_result["target_folder"]
                matched_by = "AI"

        if not target_folder_value:
            log_result(self.logger, source, None, "未分类", "没有匹配规则；AI 接口返回 unknown")
            return SortResult("unknown", source, detail="没有匹配规则")

        target_folder = _resolve_project_path(target_folder_value).resolve()
        try:
            target_folder.mkdir(parents=True, exist_ok=True)
            destination = self._avoid_collision(target_folder / self._destination_name(source))
            if self.config.get("move_method", "python") == "finder":
                self._move_with_finder(source, destination)
            else:
                shutil.move(str(source), str(destination))
            log_result(self.logger, source, destination, "成功", "%s匹配并移动" % matched_by)
            return SortResult("moved", source, destination, "%s匹配" % matched_by)
        except Exception as exc:
            log_result(self.logger, source, target_folder, "失败", str(exc))
            return SortResult("error", source, target_folder, str(exc))


def file_signature(path: Path) -> Tuple[int, int]:
    """用大小和纳秒修改时间判断下载是否已经写入完成。"""
    stat = path.stat()
    return stat.st_size, stat.st_mtime_ns

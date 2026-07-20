"""中文日志模块：统一记录文件整理过程，并自动轮转日志文件。"""

import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path


def setup_logger(log_path: Path) -> logging.Logger:
    """创建同时写入文件和终端的日志器。"""
    resolved = log_path.expanduser().resolve()
    resolved.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("ai_file_sorter:%s" % resolved)
    logger.setLevel(logging.INFO)
    logger.propagate = False

    if logger.handlers:
        return logger

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    file_handler = RotatingFileHandler(
        resolved, maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8"
    )
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)
    return logger


def log_result(logger: logging.Logger, source: Path, target, result: str, detail: str = "") -> None:
    """按固定字段记录原路径、目标路径和执行结果，便于检索。"""
    target_text = str(target) if target else "-"
    logger.info(
        "原文件=%s | 目标=%s | 结果=%s | 说明=%s",
        source,
        target_text,
        result,
        detail or "-",
    )

"""AI 分类预留接口：当前版本不会访问网络，也不会调用任何 AI。"""

from pathlib import Path
from typing import Dict


def classify_file(file_path: str) -> Dict[str, str]:
    """
    返回未来 AI 接口约定的数据结构。

    后续可在这里接入 DeepSeek 或 OpenAI；当前固定返回 unknown，确保默认零网络请求。
    """
    _ = Path(file_path)  # 保留参数，方便未来读取文件名或元数据。
    return {"category": "unknown", "target_folder": ""}

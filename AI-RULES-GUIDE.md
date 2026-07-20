# 用外部 AI 设计 AI File Sorter 规则

AI File Sorter 不会在 App 内调用 AI，也不会上传目录、文件名或文件内容。你可以自行把希望采用的目录结构告诉 ChatGPT、Codex、DeepSeek 等 AI，让它生成规则 JSON，再从 App 的“自动化规则 → 规则管理 → 导入规则”导入。

## 推荐提示词

```text
请帮我为 AI File Sorter Mac 设计文件整理规则。

我的监听目录是：~/Downloads
我希望使用的目标目录结构是：
（在这里粘贴你的目录结构，只提供目录名称即可，不要提供隐私文件内容）

请根据常见中文和英文文件名设计规则，并输出一个 JSON 文件。只能输出 JSON，不要添加 Markdown 代码块或解释。

格式要求：
- 顶层包含 format_version 和 rules。
- format_version 固定为 1。
- 每条规则包含 name、enabled、match_mode、keywords、exclude_keywords、extensions、target。
- 可选高级条件：name_regex、minimum_size_mb、maximum_size_mb、modified_older_than_days、modified_newer_than_days、finder_tags。
- match_mode 只能是 any 或 all。
- keywords 可以为空，但 keywords、extensions、name_regex 至少要填写一项。
- extensions 不要带点，例如 pdf、docx。
- target 使用以 ~/ 开头的 macOS 路径。
- 具体规则放在通用文件类型规则之前，避免被提前匹配。
- 不要生成品牌或项目专属规则，除非我的目录结构明确需要。
```

## 最小可导入示例

```json
{
  "format_version": 1,
  "rules": [
    {
      "name": "合同与协议",
      "enabled": true,
      "match_mode": "any",
      "keywords": ["合同", "协议", "contract", "agreement"],
      "exclude_keywords": ["模板", "template"],
      "extensions": ["pdf", "doc", "docx"],
      "name_regex": "",
      "minimum_size_mb": null,
      "maximum_size_mb": null,
      "modified_older_than_days": null,
      "modified_newer_than_days": null,
      "finder_tags": [],
      "target": "~/Documents/资料库/合同与协议"
    },
    {
      "name": "压缩文件",
      "enabled": true,
      "match_mode": "any",
      "keywords": [],
      "exclude_keywords": [],
      "extensions": ["zip", "rar", "7z"],
      "target": "~/Documents/下载整理/压缩文件"
    }
  ]
}
```

导入前建议先查看 JSON，确认所有 `target` 都是你希望创建的目录。导入后使用 App 中的“检查冲突”和“文件名测试”，确认无误再启用自动整理。

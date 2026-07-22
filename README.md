# AI-File-Sorter-Mac

一个轻量级、可本地运行的 macOS 文件自动整理工具。使用 Swift 原生整理引擎和 macOS `launchd` 的 `WatchPaths` 监听目录，不需要 Python、Docker、后台服务器、Web 服务或持续连接 AI。

## 推荐：使用图形版 macOS App

项目现在提供原生 SwiftUI 图形界面，无需手动编辑 JSON 或输入管理命令。打开 `AI File Sorter.app` 后可以：

- 通过侧边栏查看待分类文件、自动化规则、整理记录和设置。
- 选择监听文件夹。
- 选择“仅手动整理”“自动扫描，整理前确认”或“完全自动整理”模式。
- 设置文件保留时间、最近修改保护、自动扫描间隔和排除路径。
- 设置首次启用时是否整理现有文件。
- 开关日期重命名并选择原生文件系统或 Finder 移动。
- 添加、删除、排序规则；支持关键词和文件扩展名分类。
- 在“待分类”中处理未匹配文件：可单次移动，也可根据本地建议建立长期规则。
- 一键安装、启动、停止或立即整理现有文件。
- 使用“立即扫描（不移动）”生成可审核的整理计划，执行前会重新确认文件状态。
- 在 App 内查看整理记录、撤销移动；需要排障时再打开技术日志。

直接使用已构建的 App：

1. 解压 `AI-File-Sorter-Mac-App-v<版本号>.zip`。
2. 把 `AI File Sorter.app` 拖入系统的 `/Applications`（“应用程序”）文件夹。固定位置是后台权限稳定的必要条件。
3. 双击打开，按首次引导检查通用规则，并在“设置”中选择监听目录。
4. 点击“安装并启动”。不需要管理员密码。

App 的后台 Agent 直接从固定位置运行：

```text
/Applications/AI File Sorter.app/Contents/Library/LaunchServices/com.ai.filesorter.agent
```

Agent 使用固定标识 `com.ai.filesorter.agent`。用户配置、状态和日志保存在：

```text
~/Library/Application Support/AI-File-Sorter-Mac/Engine/
```

以后所有设置都可以在 App 中修改。规则保存后自动生效；如果改变监听文件夹，请再点击一次“重新安装并启动”，以更新 LaunchAgent 监听路径。

当前图形版版本为 `2.5.0`，包含 Apple Silicon 和 Intel 两种架构。App 会生成 LaunchAgent 并管理启停，不再调用外部 Python。

2.5.0 安全升级：

- 旧配置自动迁移到配置版本 9；缺少新字段时默认使用审阅模式，不会在升级后突然自动移动文件。
- 完全自动模式才允许后台 Agent 移动文件；手动模式和审阅模式只提供手动整理或确认计划。
- 新文件保留时间、最近修改保护、临时下载后缀、排除路径和目标目录环路检查在 App 与原生 Agent 两侧同时生效。
- 整理计划显示文件年龄、大小、修改时间和目标冲突；执行前会重新检查文件是否消失或发生变化。

2.4.3 界面优化：

- 待分类页的列表成为唯一执行入口：勾选文件后，统一在底部执行“忽略 N 项”或“整理 N 项”。
- 详情页只负责查看、建议目标、Quick Look 和 Finder 定位；可直接把当前文件加入或移出所选，不再重复提供单文件移动/忽略按钮。
- 收紧详情页的图标和标题区域，统一建议位置卡片与底部工具栏的视觉层级，状态信息只保留在列表底部。

2.4.2 修复与优化：

- 编辑规则或设置后会清晰标示“未保存”；支持 `Command+S`，切换页面或退出 App 前会提示保存或放弃修改。
- 规则编辑表单会即时提示无效正则、大小范围冲突、负数条件、空目标路径，以及可能被前置规则遮挡的情况；无需等到保存时才发现问题。

2.4.1 修复与优化：

- 单文件、批量文件、最近目录和“为类似文件建立规则”合并为一个两步整理面板。
- 目标目录既可直接输入，也可通过 Finder 选择；最近目录只负责填入目标，确认后才执行移动。
- 每次确认整理时明确选择“只移动这一次”或“保存自动规则”，批量文件没有共同关键词时不会擅自建立规则。
- 修复自动监听进程占锁时，批量移动和最近目录看起来没有反应的问题。
- 手动整理严格只移动本次所选文件；保存规则不再触发整个 Downloads 的额外扫描。
- 操作进度与失败原因直接显示在待分类列表底部，不需要滚动右侧详情查找。

2.4.0 新增：

- “整理计划”以可勾选列表显示来源、命中规则、目标路径、重名和权限状态，确认后只执行所选文件。
- 同一次整理计划和批量单次移动使用统一批次 ID，可在“整理记录”中撤销最近批次。
- 待分类详情支持 macOS 原生 Quick Look；点击“快速预览”或按空格即可查看，不缓存文件内容。
- 规则增加可折叠高级条件：名称正则、最小/最大文件大小、修改时间范围和 Finder 标签。
- AI JSON 导入前显示同名规则、缺失目标目录、无效正则和当前目录预计影响数量。
- 整理计划最多缓存 300 条轻量路径记录，关闭即释放；后台仍使用目录事件，不增加常驻扫描进程。

2.3.1 优化：

- 整理历史和技术日志改为进入对应页面时再读取，减少启动阶段的文件读取与缓存。
- 关闭规则预览后立即释放预览文本。
- 修复仅按扩展名匹配时，预览显示空关键词的问题。
- 文件名测试和规则预览现在会显示规则名称及实际命中条件。
- 默认测试文件名改为通用合同示例，不再包含个人品牌规则。

2.3.0 新增：

- 使用 macOS 原生侧边栏，日常入口简化为“待分类、自动化规则、整理记录、设置”。
- 待分类改为列表与详情双栏结构，一次性移动是主操作，建立长期规则按需展开。
- 规则列表默认只显示名称和匹配摘要，展开后再编辑高级条件。
- 整理历史成为普通用户入口，原始技术日志收纳为辅助排障窗口。
- 首次使用引导说明整理流程与本地隐私边界。
- 默认规则改为财务票据、合同、截图、图片、视频、压缩文件、安装包和办公文档等 8 条通用方案，全部可修改或删除。
- 支持外部 AI 生成开放 JSON 规则：在“规则管理”中复制需求模板，交给 ChatGPT、Codex、DeepSeek 等工具生成后再导入；App 本身不会联网或上传目录。

2.2.0 新增：

- 每条规则可独立启用、停用和复制。
- 支持“任意关键词”或“全部关键词”，以及排除词和扩展名条件。
- 规则冲突检查：重复关键词、规则遮挡和过短关键词提醒。
- 文件名即时测试，显示命中规则、目标路径和最终重命名结果。
- 规则导入、导出、恢复上一次备份和恢复默认规则。
- 完整重命名模板编辑器，新增 `{category}` 和 `{keyword}` 变量。
- 待分类刷新改用 macOS 目录事件，并将连续事件合并处理；不再每20秒轮询。
- 页面改为按需渲染，未打开高级规则页时不会提前构建全部规则控件。
- 旧版规则自动迁移为“启用 + 任意关键词”，原有匹配行为保持不变。

2.1.0 新增：

- 独立“待分类”收件箱，不再用弹窗反复打断。
- “仅整理这一次”：选择目录并移动，不创建长期规则。
- “建立规则并整理”：显示预计影响数量，确认后保存规则并整理匹配文件。
- 批量单次整理、批量忽略和最近使用目录。
- 结构化整理历史、Finder 定位和一键撤销；同名文件不会被覆盖。
- 历史最多 500 条、待分类最多显示 200 条、忽略记录最多 1000 条、最近目录最多 8 个。
- 日志界面只读取文件末尾 40KB，减少长期运行时的瞬时内存占用。

2.0.2 将后台 Agent 固定在 `/Applications/AI File Sorter.app` 内运行，并设置稳定的反向域名标识。

2.0.1 增加 CSV/TSV 支持，并在每次“立即整理”后记录支持文件数、成功、未匹配、仍在写入和失败数量；旧配置会自动加入这两种扩展名。

2.0 新增：

- “预览匹配”：在分类规则页模拟当前文件会命中哪条规则、移动到哪里，不会真的移动文件。
- 完全原生 Swift 整理 Agent，不再依赖 Python。
- 菜单栏快捷控制：立即整理、启停服务、打开窗口和 Downloads。
- “环境与权限”：检查原生 Agent、监听目录、目标目录写入权限以及自动整理服务状态。
- 配置迁移：旧版配置缺少新字段时自动补充默认值。
- 配置备份：每次保存前保留 `config.backup.json`，配置损坏时优先恢复。

### 修改通用规则或添加规则

“自动化规则”页面首次会显示 8 条通用规则。它们不是只读模板，均可直接修改：

1. 点击规则右侧箭头展开编辑。
2. 在“关键词”输入框中编辑关键词，使用中文或英文逗号分隔；也可以只按扩展名匹配。
3. 在“目标”输入框中修改路径，或点击“选择…”挑选现有文件夹。
4. 点击垃圾桶可删除任意预置或新增规则，拖动可调整优先顺序。
5. 点击“保存规则”后写入用户配置并生效。

2.2 中每条规则还可以设置：

- `任意关键词`：命中其中一个关键词即可。
- `全部关键词`：文件名必须同时包含所有关键词。
- `排除词`：文件名包含任一排除词时不执行该规则。
- `扩展名`：例如 `pdf, docx`；留空表示所有受支持类型。
- `启用/停用`：停用规则会保留配置，但不参与自动整理。

点击“添加规则”会在列表顶部立刻新增一条规则，并更新标题中的规则数量。请把“新关键词”和“新分类”改成实际内容后保存。App 升级时会保留已经修改过的用户配置，不会重新覆盖为预置规则。

### 让外部 AI 帮你制定规则

这是一个开放的导入流程，不要求 App 内置或绑定任何 AI：

1. 在“自动化规则”页面打开“规则管理”，点击“复制给 AI 的规则需求模板”。
2. 把模板粘贴给你选择的 AI，并向它提供希望整理的目录结构、常见文件名和分类习惯。若使用能访问本机工作区的工具，也可以让它只读分析指定目录。
3. 要求 AI 将最终结果保存为 `.json`；完整格式见项目中的 `AI-RULES-GUIDE.md`。
4. 回到“规则管理 → 导入规则…”，选择替换当前规则或追加到末尾。
5. 先使用“整理计划”和“文件名测试”检查结果，再保存启用。

导入文件中的规则只需包含 `name`、`enabled`、`match_mode`、`keywords`、`exclude_keywords`、`extensions` 和 `target`。规则 ID 与导出时间都可省略，App 会自动补齐。

如果需要从源码重新构建通用版（Apple Silicon + Intel）App：

```bash
./build-app.sh
```

构建产物位于项目内的 `artifacts/`：`AI File Sorter.app` 和 `AI-File-Sorter-Mac-App-v<版本号>.zip`。

## 工作方式

```text
文件进入 Downloads
        ↓
macOS LaunchAgent 检测目录变化
        ↓
根据整理模式决定：手动、扫描后确认，或继续自动处理
        ↓
保留时间、最近修改保护和稳定性检查
        ↓
按 config.json 中从上到下的规则匹配文件名
        ↓
确认后或自动创建目标目录 → 可选重命名 → 安全移动
        ↓
写入 logs/sorter.log
```

未命中规则的文件会留在 Downloads。AI 分类接口仍为预留状态，不会联网，也不会调用任何 AI 服务。

## 系统要求

- macOS 13 或更新版本
- 当前用户可访问 Downloads 和规则中的目标文件夹

## 1.x 兼容命令行工具

在“终端”中进入本项目目录，然后运行：

```bash
chmod +x install.sh
./install.sh
```

这些脚本仅用于兼容旧版和源码调试；2.0 App 用户不需要运行。旧版安装脚本会：

1. 检查 Python 版本；本项目没有第三方 Python 依赖。
2. 创建 `logs`、`~/Downloads` 和 `~/Library/LaunchAgents`（如果不存在）。
3. 检查 Python 语法与 `config.json`。
4. 根据本机真实路径生成 `~/Library/LaunchAgents/com.ai.filesorter.plist`。
5. 加载 LaunchAgent，并在以后每次登录 Mac 时自动启用。

为了避免安装时意外整理旧文件，第一次启动默认只记录 Downloads 现有文件。安装完成后新下载或新复制进去的文件才会自动处理。若确实需要整理存量文件，可运行：

```bash
python3 main.py --once
```

## 修改分类规则

直接编辑 `config.json`。每条规则包含：

- `keywords`：只要文件名包含其中任意一个关键词就算命中，不区分英文大小写。
- `target`：目标文件夹，支持 `~`。

规则从上到下匹配，第一条命中者优先。保存配置后，LaunchAgent 也会收到变化事件；之前因未匹配而留在 Downloads 的文件会自动重新检查。

示例：

```json
{
  "keywords": ["合同", "协议", "报价"],
  "target": "~/Documents/资料库/商务文件"
}
```

JSON 标准不允许 `//` 注释，因此示例配置使用顶层 `_说明` 字段保存注释文字，程序会忽略该字段。编辑后可检查格式：

```bash
python3 main.py --check-config
```

## 可选自动重命名

默认关闭。将 `config.json` 中的：

```json
"rename": {
  "enabled": true,
  "template": "{date}_{original_name}",
  "date_format": "%Y-%m-%d"
}
```

设为 `true` 后，`final-new-v3.pdf` 会变成类似 `2026-07-16_final-new-v3.pdf`。扩展名会保留。模板支持：

- `{date}`：按 `date_format` 生成的日期。
- `{original_name}`：不含最后一个扩展名的原文件名。
- `{extension}`：不含点号的扩展名。

目标目录里已有同名文件时，程序会生成 `_1`、`_2` 等后缀，不会覆盖原文件。

## 原生移动与 Finder 移动

默认设置是：

```json
"move_method": "native"
```

这是 LaunchAgent 环境中最可靠的方式。如果希望移动操作显示为 Finder 操作，可改为：

```json
"move_method": "finder"
```

此模式通过 `/usr/bin/osascript` 调用 Finder。macOS 第一次使用时可能弹出“自动化”权限提示。若无人登录、权限被拒绝或 Finder 不可用，建议恢复为 `native`。

## 管理命令

启动或重新触发一次检查：

```bash
./start.sh
```

停止自动监听：

```bash
./stop.sh
```

修改了项目所在路径后，请重新运行 `./install.sh`，因为安装后的 plist 保存的是绝对路径。

## 查看日志

持续查看整理日志：

```bash
tail -f logs/sorter.log
```

还可以检查：

- `logs/launchd.out.log`：LaunchAgent 标准输出。
- `logs/launchd.err.log`：启动或权限错误。
- `logs/state.json`：已见文件状态，用于避免重复处理；它不是业务日志。
- `logs/history.json`：最近 500 条结构化移动历史，用于 App 内展示和撤销。

日志会记录时间、原文件路径、目标路径、结果与说明，例如：

```text
2026-07-16 10:20:00 | INFO | 原文件=/Users/me/Downloads/Samsung_S95F.pdf | 目标=/Users/me/Documents/资料库/电视/三星/Samsung_S95F.pdf | 结果=成功 | 说明=规则匹配并移动
```

日志最大约 5 MB，自动保留 3 个历史文件。

## 配置项说明

| 配置项 | 默认值 | 作用 |
|---|---:|---|
| `watch_folder` | `~/Downloads` | 监听目录 |
| `scan_interval_seconds` | `2` | 文件写入期间的复查间隔 |
| `stable_seconds` | `4` | 大小和修改时间保持不变多久后才移动 |
| `event_idle_seconds` | `8` | 事件处理完成后多久退出进程 |
| `max_event_runtime_seconds` | `900` | 单次下载事件最多跟踪 15 分钟 |
| `process_existing_on_first_start` | `false` | 第一次启动是否整理已有文件 |
| `move_method` | `native` | `native` 或 `finder` |
| `organization_mode` | `review` | `manual`、`review` 或 `automatic` |
| `retention_days` | `7` | 文件进入监听目录后至少保留多少天；0 表示关闭 |
| `recent_modification_protection_hours` | `24` | 最近修改保护时长；0 表示关闭 |
| `automatic_scan_interval_hours` | `24` | 完全自动模式下的定期复查间隔；0 表示只响应目录变化 |
| `excluded_paths` | `[]` | 不参与扫描或自动整理的文件/目录路径 |
| `history_file` | `logs/history.json` | 结构化整理历史和撤销记录 |
| `supported_extensions` | 见配置 | 允许自动整理的文件类型 |

规则字段：`enabled`、`match_mode`、`keywords`、`exclude_keywords`、`extensions` 和 `target`。旧配置缺少这些新字段时会自动补充兼容默认值。

LaunchAgent 不是一直运行的服务器：`launchd` 观察目录，发生变化时才启动原生 Agent；目录安静后 Agent 自动退出。

## 权限与常见问题

### 文件没有移动

1. 确认文件扩展名在 `supported_extensions` 中。
2. 确认文件名命中了某条 `keywords`。
3. 查看 `logs/sorter.log` 和 `logs/launchd.err.log`。
4. 在 App 中点击“立即整理现有文件”，并查看日志页。

### macOS 提示没有权限

目标位于 Documents、Desktop、外置磁盘或网络盘时，macOS 可能要求授权。请在“系统设置 → 隐私与安全性”中给 AI File Sorter 相应的“文件与文件夹”权限。只有确实需要时再授予“完全磁盘访问权限”。

### 修改规则后仍不匹配

关键词只匹配文件名，不读取 PDF/Office 文件正文。可先检查 JSON：

```bash
python3 main.py --check-config
./start.sh
```

### 想重新建立首次状态

先停止服务，再删除状态文件，然后重新安装或启动：

```bash
./stop.sh
rm logs/state.json
./start.sh
```

如果 `process_existing_on_first_start` 为 `false`，重新建立状态时仍会保留已有文件；需要手动整理全部存量文件请使用 `python3 main.py --once`。

## 运行测试

测试全部在临时目录中执行，不会触碰真实 Downloads：

```bash
python3 -m unittest discover -s tests -v
./tests/test_native_agent.sh
```

测试覆盖默认规则、规则匹配、自动创建目录、重命名、重名保护、未知文件保留、首次启动保护、监听事件处理、单次/批量整理、历史、撤销保护、进程互斥和 Finder 失败回滚。

## 项目结构

```text
AI-File-Sorter-Mac/
├── main.py                 # launchd 事件入口、稳定性检测和状态管理
├── config.json             # 用户可编辑规则
├── ai_classifier.py        # AI 分类预留接口（当前永远 unknown）
├── sorter.py               # 匹配、建目录、重命名和移动
├── logger.py               # 日志配置
├── install.sh              # 一键安装
├── build-app.sh            # 构建 SwiftUI 通用版 App
├── artifacts/              # 本地构建产物（App 和 zip，不提交 Git）
├── install-app.sh          # 安装到系统 /Applications 固定位置
├── start.sh                # 启动/触发检查
├── stop.sh                 # 停止监听
├── launchd/
│   └── com.ai.filesorter.plist
├── logs/
├── tests/
│   ├── test_sorter.py
│   └── test_native_agent.sh
├── mac-app/
│   ├── Info.plist
│   ├── Sources/AIFileSorterApp.swift
│   ├── Sources/AIFileSorterAgent.swift
│   └── Tools/IconMaker.swift
└── README.md
```

## AI 接口扩展约定

2.1 原生 Agent 当前将未匹配结果标记为 `unknown`：

```json
{
  "category": "unknown",
  "target_folder": ""
}
```

未来接入 DeepSeek 或 OpenAI 时应保持上述字段，并将 API Key 存入 macOS 钥匙串，不能写进代码或 `config.json`。

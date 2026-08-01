# AI File Sorter for macOS

[![Apache-2.0 License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](#系统要求)

一个本地优先的 macOS 文件整理 App。当前版本使用 SwiftUI 图形界面、Swift 原生整理 Agent 和 macOS `launchd` 目录事件，不需要 Python、Docker、后台服务器或持续运行的终端进程。

## 隐私与联网边界

App 默认完全在本机运行：不会上传文件内容、文件名、目录结构、规则、日志或凭据，也不会自动调用任何网络服务。App 不内置 AI 分类服务；规则由本地配置和本地匹配引擎执行。

规则管理页可以复制一份规则需求模板，交给用户自行选择的外部工具生成 JSON，再在 App 内审核、预览并导入。这个可选流程不会由 App 自动发送文件或目录数据，也不会为 App 增加网络连接。

完整边界见 [隐私说明](PRIVACY.md)。

## 使用图形版 App

### 安装已构建版本

1. 解压 `AI-File-Sorter-Mac-App-v<版本号>.zip`。
2. 将 `AI File Sorter.app` 拖入 `/Applications`（“应用程序”）。固定位置用于保持后台服务的路径和权限稳定。
3. 打开 App，按首次引导检查通用规则，并在“设置”中选择监听目录。
4. 在设置页的状态卡打开“自动整理”。不需要手动编辑后台服务，也不需要管理员密码。

改变监听目录后，保存设置会自动同步后台服务，不需要再次部署。

后台 Agent 固定在 App 内：

```text
/Applications/AI File Sorter.app/Contents/Library/LaunchServices/com.ai.filesorter.agent
```

App 使用固定标识 `com.ai.filesorter.agent`。配置、状态、历史和日志保存在：

```text
~/Library/Application Support/AI-File-Sorter-Mac/Engine/
```

### 从源码构建

要求 macOS 13 或更新版本，以及 Xcode Command Line Tools：

```bash
./build-app.sh
```

构建产物位于 `artifacts/`：`AI File Sorter.app` 和对应版本的 zip 压缩包。也可以用下面的脚本将构建产物安装到 `/Applications`：

```bash
./install-app.sh
```

## 整理行为

App 通过侧边栏提供四个主要入口：收件箱、自动化规则、整理记录和设置。

- `只提供整理建议`：后台不会自动移动文件；用户可以在收件箱选择文件并进行单次整理。
- `整理前让我确认`：后台扫描并生成待审核内容，移动前需要用户确认。
- `自动整理`：只有文件满足保留时间、最近修改保护、稳定性、排除路径和规则条件时才会自动移动。
- `只移动这一次`：输入目标目录即可移动本次选择的文件，不创建长期规则。
- `立即扫描（不移动）`：生成可勾选的整理计划；执行前会重新检查文件是否仍存在、是否改变以及目标是否冲突。

规则按列表顺序匹配，支持：

- 任意关键词或全部关键词；
- 排除关键词和扩展名；
- 名称正则、最小/最大文件大小、修改时间范围和 Finder 标签；
- 原生文件系统移动或 Finder 移动；
- 可选日期重命名，以及 `{date}`、`{original_name}`、`{extension}`、`{category}` 和 `{keyword}` 模板变量。

同名文件永远不会被覆盖。目标已有同名文件时，App 会使用 `_1`、`_2` 等后缀。整理记录保留最近 500 条移动记录，可在 App 内撤销单条移动或整个批次。

未命中规则、仍在写入、受保留时间/最近修改保护、位于排除路径或目标不可用的文件会留在监听目录，并在收件箱显示原因。

## 配置与状态迁移

日常设置应在 App 中修改并保存。配置文件位于 Engine 目录的 `config.json`，其中的规则和高级条件也可以用于备份或审阅。保存配置前，App 会保留 `config.backup.json`。

升级旧版本时保留用户配置、整理历史和状态，不会把旧设置静默改成自动整理：

- 缺少新字段的旧配置会补充安全默认值；旧配置默认进入 `扫描后确认` 模式。
- 配置版本会在原生 App 保存时规范化为当前版本 9；旧版扩展名字段会补齐 CSV/TSV 等兼容项。
- 旧版 `state.json`（包含 `size`、`mtime_ns` 和 `reason` 的文件记录）会迁移为原生状态版本 2，并保留已见文件基线，避免升级后重复处理旧文件。
- App 不再使用旧版运行时副本；启动时会清理 Engine 目录中遗留的旧脚本文件，但不会删除用户配置、状态、历史或日志。

如需重新建立首次启动基线，可先在 App 中暂停自动整理，再备份并删除 Engine 目录中的 `state.json`，最后重新开始自动整理。删除状态前请确认不需要保留当前基线；整理历史和配置不会因此自动删除。

## 规则安全检查

App 保存规则前会检查空匹配条件、无效正则、大小范围、负数条件，以及目标目录是否位于监听目录内。目标目录不能放在监听目录内部，以避免文件移动触发无限整理循环。

建议先使用“文件名测试”和“整理计划”检查规则，再启用自动整理。默认配置是审阅模式，默认不额外延迟文件；下载未完成保护仍由临时后缀和稳定时间检测负责。

## 日志与排障

在 App 的“整理记录”页查看结构化历史，在“技术日志”窗口查看原生 Agent 日志。常用文件为：

- `config.json`：当前配置；
- `config.backup.json`：最近一次保存前的配置备份；
- `logs/state.json`：已见文件状态和撤销保护标记；
- `logs/history.json`：最近的移动记录和撤销状态；
- `logs/sorter.log`：详细执行日志，原生日志会自动轮换。

若文件没有移动，请依次确认扩展名、规则顺序、整理模式、保留/最近修改设置、排除路径和目标目录权限；然后在 App 中运行环境检查或“立即整理”。目标位于 Documents、Desktop、外置磁盘或网络盘时，macOS 可能需要在“系统设置 → 隐私与安全性”中授予文件访问权限。

## 系统要求

- macOS 13 或更新版本；
- 当前用户可以访问监听目录和规则目标目录；
- 从源码构建时需要 Xcode Command Line Tools。

## 测试

测试只使用临时目录，不会触碰真实 Downloads。原生端到端测试需要先生成 App：

```bash
./build-app.sh
./tests/test_native_agent.sh
```

测试覆盖默认迁移、旧状态迁移、首次启动保留、保留时间、最近修改保护、排除路径、`--once`、单次整理不建规则、重名保护、整理模式、批次撤销、撤销防重复整理、互斥执行和防环路配置检查。

## 项目结构

```text
AI-File-Sorter-Mac/
├── config.json                  # App 首次部署的默认配置
├── build-app.sh                 # 构建 SwiftUI App 和原生 Agent
├── install-app.sh               # 安装到 /Applications
├── artifacts/                   # 本地构建产物，不提交 Git
├── logs/                        # 本地运行时日志目录占位
├── tests/
│   └── test_native_agent.sh     # macOS 原生 Agent 端到端测试
├── mac-app/
│   ├── Info.plist
│   ├── Sources/                 # SwiftUI App、模型、服务和原生 Agent
│   └── Tools/IconMaker.swift
└── README.md
```

## 参与贡献

欢迎通过 Issue 和 Pull Request 参与。提交前请阅读 [贡献指南](CONTRIBUTING.md)、[安全政策](SECURITY.md) 和 [社区行为准则](CODE_OF_CONDUCT.md)。

项目采用 [Apache-2.0](LICENSE) 许可证。

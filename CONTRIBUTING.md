# 贡献指南

感谢你愿意改进 AI File Sorter。项目以安全、可撤销、本地优先为原则；任何贡献都不应弱化这些默认保护。

## 开始前

1. 对较大的功能或行为变更，请先开 Issue 说明目标、影响范围和验证方式。
2. 不要提交真实文件、个人文件名、目录路径、日志、账号信息、API Key 或其他凭据。
3. 保持改动聚焦；避免把重构、功能和无关格式化混在一个 Pull Request。

## 本地验证

开发环境需要 macOS 13 或更新版本。Python 兼容层不需要第三方依赖；原生 App 需要 Xcode Command Line Tools。

```bash
python3 -m unittest discover -s tests -v
./tests/test_native_agent.sh
```

需要验证图形版时，可运行：

```bash
./build-app.sh
```

构建产物位于 `artifacts/`，由 `.gitignore` 排除，不要提交。

## 代码与产品约定

- 任何可能移动文件的流程都应保留预览、确认、冲突保护或撤销路径。
- 默认不得自动上传用户数据或调用第三方服务。
- Swift 原生 Agent 与 Python 兼容层的关键整理安全规则应保持一致。
- 新增配置字段时，要为旧配置提供安全的迁移默认值。
- 更新用户可见行为时，请同步更新 README、测试或相关说明。

## Pull Request

请说明：改了什么、为什么需要、如何验证，以及可能影响到的文件整理行为。贡献被合并后，除非另有书面说明，即表示你同意按 [Apache-2.0](LICENSE) 许可证提供该贡献。

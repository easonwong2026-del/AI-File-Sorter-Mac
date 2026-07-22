# Proposed OpenAI API Credits Plan

## Status

This is a maintenance and research proposal, not a description of a current product feature. AI File Sorter 2.5.1 runs locally and does not call OpenAI or any other AI service.

## Intended use of credits

If the project receives OpenAI API credits, the maintainer plans to use them to improve the open-source project in three bounded areas:

1. **Contributor productivity and quality.** Use Codex and OpenAI models against public source code, synthetic fixtures, test failures, and documentation to help maintain the Swift native app, the local sorting engine, accessibility, and regression coverage.
2. **Rule safety research.** Prototype an opt-in rule explanation and linting workflow that accepts only deliberately supplied, redacted rule JSON. It will never automatically send a user's file contents, file names, folder paths, logs, or configuration to an API.
3. **Documentation and testing.** Generate diverse synthetic file-name examples and edge-case test plans, then review every proposed change with the existing local tests and manual safety checks.

## Guardrails

- No end-user data is sent to an AI service by default.
- Any future networked feature must be separate, disabled by default, transparent about the exact data it sends, and require affirmative user action before a request.
- AI output remains advisory: users review rules and file-moving plans before execution.
- API keys, if introduced for development or an opt-in feature, belong in macOS Keychain or an external secret store, never in source code or `config.json`.

## 0.1.1

- Accept `brain_kernel ^0.2.0`. The 0.2.0 kernel adds resource-subscription
  members to `KernelClientConnection`; this package only holds kernel types and
  is unaffected by them, but the old `^0.1.2` bound made it the single package
  blocking every consumer from adopting the new kernel.

## [0.1.0] - 2026-06-18 - Initial publish

### Added
- `ClaudeCodeInteractiveProvider` / `ProcessClaudeRunner` — a `brain_kernel`
  LLM provider that drives Claude Code as a live interactive session
  (plain `claude` subprocess, no `-p`). Desktop-only.

# appplayer_claude_code_provider

A `brain_kernel` LLM provider that drives **Claude Code** as a live
interactive session (a plain `claude` subprocess — **no `-p`**), so usage
stays on the flat interactive subscription instead of the metered
programmatic credit. Desktop-only (spawns the `claude` CLI).

This is a legitimate way to use Claude Code as an LLM engine for the
platform: the host registers the provider with the kernel and agents drive
it like any other provider.

## Quick use

```dart
import 'package:appplayer_claude_code_provider/appplayer_claude_code_provider.dart';

// Register against a booted KernelApp (desktop host).
final provider = ClaudeCodeInteractiveProvider.forKernel(app);
// Agents now resolve `claude_code` as a native LLM provider.
```

## Platform

Desktop (macOS / Linux / Windows) — requires the `claude` CLI on PATH.
Not available on web/mobile; wire it only into desktop host builds.

## Depends on

- `brain_kernel` — the LLM provider seam (`mcp_llm` `CustomLlmProvider`).
- `mcp_llm` — request/response model.

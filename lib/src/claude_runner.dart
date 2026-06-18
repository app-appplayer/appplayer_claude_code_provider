/// Runs the `claude` CLI as a **plain subprocess without `-p`**.
///
/// When stdout is not a TTY, `claude "<prompt>"` does not render the
/// interactive TUI — it prints the answer to stdout and exits. So a one
/// line subprocess call returns the completion; no TUI scraping, no tmux,
/// no `-p`. (`-p` becomes metered programmatic billing on 2026-06-15;
/// this path is invoked without it.)
///
/// The argv builder and the subprocess runner are split so the argv logic
/// is unit-tested without spawning `claude`, and the provider is tested
/// against [FakeClaudeRunner].
library;

import 'dart:io';

/// One invocation of the `claude` CLI.
class ClaudeInvocation {
  const ClaudeInvocation({
    required this.prompt,
    this.system,
    this.mcpConfigPath,
    this.model,
    this.replaceSystem = false,
  });

  /// The user turn (passed as the positional prompt argument).
  final String prompt;

  /// Optional system instructions. Forwarded via `--append-system-prompt`
  /// (default) or `--system-prompt` when [replaceSystem] is true.
  final String? system;

  /// Optional path to an `--mcp-config` JSON (mode A — platform tools).
  final String? mcpConfigPath;

  /// Optional model alias / id (`--model`).
  final String? model;

  /// Replace claude's default system prompt instead of appending.
  final bool replaceSystem;
}

/// Build the `claude` argv — **never includes `-p`/`--print`**. The
/// positional prompt is last so flags are unambiguous.
List<String> buildClaudeArgs(ClaudeInvocation inv) {
  final args = <String>[];
  final system = inv.system;
  if (system != null && system.isNotEmpty) {
    args.add(inv.replaceSystem ? '--system-prompt' : '--append-system-prompt');
    args.add(system);
  }
  final model = inv.model;
  if (model != null && model.isNotEmpty) {
    args
      ..add('--model')
      ..add(model);
  }
  final mcp = inv.mcpConfigPath;
  if (mcp != null && mcp.isNotEmpty) {
    args
      ..add('--mcp-config')
      ..add(mcp);
  }
  // `--` (end-of-options) before the positional prompt. claude 2.1.x's
  // `--mcp-config` is variadic and would otherwise swallow the prompt as
  // another config path (`Error: Invalid MCP configuration: ... not
  // found: <prompt>`). With `--` the prompt is fixed as positional
  // regardless of which flags precede it.
  args
    ..add('--')
    ..add(inv.prompt);
  return args;
}

/// Seam — the provider drives this. Real impl spawns `claude`; tests use
/// [FakeClaudeRunner].
abstract class ClaudeRunner {
  /// Run one invocation; return the assistant reply text (trimmed).
  Future<String> run(ClaudeInvocation invocation);
}

/// Raised when the `claude` subprocess fails or times out.
class ClaudeRunnerError implements Exception {
  const ClaudeRunnerError(this.message);
  final String message;
  @override
  String toString() => 'ClaudeRunnerError: $message';
}

/// Spawns `claude` (no `-p`). `ANTHROPIC_API_KEY` is stripped so the call
/// lands on the user's subscription, never PAYG.
class ProcessClaudeRunner implements ClaudeRunner {
  ProcessClaudeRunner({
    this.executable = 'claude',
    this.workingDirectory,
    this.timeout = const Duration(minutes: 5),
  });

  final String executable;
  final String? workingDirectory;
  final Duration timeout;

  @override
  Future<String> run(ClaudeInvocation invocation) async {
    final args = buildClaudeArgs(invocation);
    final proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: _subscriptionEnv(),
    );
    // No interactive input — close stdin so claude sees EOF immediately.
    await proc.stdin.close();
    final stdoutF = proc.stdout.transform(systemEncoding.decoder).join();
    final stderrF = proc.stderr.transform(systemEncoding.decoder).join();
    final code = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return 124;
      },
    );
    final out = await stdoutF;
    final err = await stderrF;
    if (code != 0) {
      throw ClaudeRunnerError(
        '$executable exited $code: ${err.trim().isEmpty ? out.trim() : err.trim()}',
      );
    }
    return out.trim();
  }

  Map<String, String> _subscriptionEnv() {
    final env = Map<String, String>.from(Platform.environment);
    env.remove('ANTHROPIC_API_KEY');
    return env;
  }
}

/// In-memory runner for tests — records invocations, returns a scripted
/// reply (function of the invocation).
class FakeClaudeRunner implements ClaudeRunner {
  FakeClaudeRunner(this._reply);

  final String Function(ClaudeInvocation) _reply;
  final List<ClaudeInvocation> calls = <ClaudeInvocation>[];

  @override
  Future<String> run(ClaudeInvocation invocation) async {
    calls.add(invocation);
    return _reply(invocation);
  }
}

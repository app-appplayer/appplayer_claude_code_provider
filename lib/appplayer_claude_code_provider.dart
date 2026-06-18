/// Recipe — Claude Code as a brain_kernel LLM provider, run as a plain
/// subprocess **without `-p`**.
///
/// `claude "<prompt>"` (no `-p`, stdout not a TTY) prints the answer and
/// exits — so the provider just spawns it and reads stdout. No TUI
/// scraping, no tmux. `-p`/SDK/headless move to metered programmatic
/// billing on 2026-06-15; this path is invoked without `-p`.
///
/// System instructions ride on `--append-system-prompt`; platform tools
/// (mode A) ride on `--mcp-config`. `ANTHROPIC_API_KEY` is stripped so
/// the call lands on the user's subscription. brain_kernel is not
/// modified.
library;

import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_llm/mcp_llm.dart' show LlmCapability;

import 'src/claude_runner.dart';

export 'src/claude_runner.dart';

class ClaudeCodeInteractiveProvider extends CustomLlmProvider {
  ClaudeCodeInteractiveProvider({
    String name = 'claude_code_interactive',
    ClaudeRunner? runner,
    this.mcpConfigPath,
    this.mcpServers,
    this.model,
    this.replaceSystem = false,
  })  : runner = runner ?? ProcessClaudeRunner(),
        super(name: name);

  /// Wire against a live [KernelApp] — mode A. The host's external
  /// server spec ([KernelApp.hostMcpServerSpec]) is forwarded to the CLI
  /// as `--mcp-config` so the subscription-side LLM sees the host's own
  /// catalog (`bk.*` / `<bundleId>.*`) as native MCP tools. Mirrors the
  /// `-p` recipe's `ClaudeCodeProvider.forKernel`, minus `-p`.
  factory ClaudeCodeInteractiveProvider.forKernel(
    KernelApp app, {
    String name = 'claude_code_interactive',
    ClaudeRunner? runner,
    String? model,
    bool replaceSystem = false,
    String? endpointLabel,
    List<McpServerSpec>? extraMcpServers,
  }) {
    final spec = app.hostMcpServerSpec(endpointLabel: endpointLabel);
    final servers = <McpServerSpec>[
      if (spec != null) spec,
      ...?extraMcpServers,
    ];
    return ClaudeCodeInteractiveProvider(
      name: name,
      runner: runner,
      model: model,
      replaceSystem: replaceSystem,
      mcpServers: servers.isEmpty ? null : servers,
    );
  }

  /// The subprocess seam. Defaults to [ProcessClaudeRunner].
  final ClaudeRunner runner;

  /// Optional `--mcp-config` path (mode A — platform tools/agents).
  /// Takes precedence over [mcpServers].
  final String? mcpConfigPath;

  /// Optional host server specs (mode A) — materialized to a temp
  /// `--mcp-config` JSON per request, then cleaned up. Set by [forKernel].
  final List<McpServerSpec>? mcpServers;

  /// Optional `--model` alias / id.
  final String? model;

  /// Replace claude's default system prompt instead of appending.
  final bool replaceSystem;

  // CustomLlmProvider.complete reads the endpoint getters before
  // executeRequest; empty strings keep them inert.
  @override
  String getCompletionEndpoint() => '';
  @override
  String getEmbeddingEndpoint() => '';

  @override
  Future<Map<String, dynamic>> transformRequest(LlmRequest request) async {
    final out = <String, dynamic>{'prompt': request.prompt};

    final system = request.parameters['system'] ??
        request.parameters['system_instructions'];
    if (system is String && system.isNotEmpty) {
      out['system'] = system;
    }

    if (request.history.isNotEmpty) {
      final buf = StringBuffer();
      for (final m in request.history) {
        final text = _messageText(m);
        if (text.isEmpty) continue;
        buf.writeln('${_roleLabel(m.role)}: $text');
      }
      if (buf.isNotEmpty) {
        out['serializedHistory'] = buf.toString().trimRight();
      }
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>> executeRequest(
    Map<String, dynamic> requestData,
    String endpoint,
    Map<String, String> headers,
  ) async {
    final base = (requestData['prompt'] ?? '').toString();
    final history = requestData['serializedHistory'];
    final prompt = history is String && history.isNotEmpty
        ? 'Conversation so far:\n$history\n\nUser: $base'
        : base;

    final mcp = await _materializeMcpConfig();
    try {
      final text = await runner.run(
        ClaudeInvocation(
          prompt: prompt,
          system: requestData['system'] as String?,
          mcpConfigPath: mcp.path,
          model: model,
          replaceSystem: replaceSystem,
        ),
      );
      return <String, dynamic>{
        'text': text,
        'metadata': <String, dynamic>{
          'provider': name,
          'mode': 'subscription_no_print',
        },
      };
    } finally {
      await mcp.cleanup();
    }
  }

  /// Resolve the `--mcp-config` path for this call: a static
  /// [mcpConfigPath] if set, else materialize [mcpServers] to a temp JSON
  /// (cleaned up after the call).
  Future<_McpConfig> _materializeMcpConfig() async {
    if (mcpConfigPath != null && mcpConfigPath!.isNotEmpty) {
      return _McpConfig(mcpConfigPath, null);
    }
    final specs = mcpServers;
    if (specs == null || specs.isEmpty) return const _McpConfig(null, null);
    final block = <String, dynamic>{
      'mcpServers': <String, dynamic>{
        for (final s in specs) s.name: s.toMcpConfigEntry(),
      },
    };
    final file = File(
      '${Directory.systemTemp.path}/cc_interactive_mcp_'
      '${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await file.writeAsString(jsonEncode(block));
    return _McpConfig(file.path, file);
  }

  @override
  Stream<dynamic> executeStreamingRequest(
    Map<String, dynamic> requestData,
    String endpoint,
    Map<String, String> headers,
  ) async* {
    // No structured streaming without `-p` — emit the full result once.
    yield await executeRequest(requestData, endpoint, headers);
  }

  @override
  Future<LlmResponse> transformResponse(
    Map<String, dynamic> rawResponse,
  ) async {
    final meta = rawResponse['metadata'];
    return LlmResponse(
      text: (rawResponse['text'] ?? '').toString(),
      metadata: meta is Map<String, dynamic>
          ? meta
          : <String, dynamic>{'raw_response': rawResponse},
    );
  }

  @override
  Future<void> initialize(LlmConfiguration config) async {}
  @override
  Future<void> close() async {}

  @override
  Future<List<double>> getEmbeddings(String text) async =>
      throw UnimplementedError(
        'Embeddings are not supported by the claude CLI provider.',
      );

  @override
  bool hasToolCallMetadata(Map<String, dynamic> metadata) => false;
  @override
  LlmToolCall? extractToolCallFromMetadata(Map<String, dynamic> metadata) =>
      null;
  @override
  Map<String, dynamic> standardizeMetadata(Map<String, dynamic> metadata) =>
      metadata;
  @override
  bool get supportsPromptCaching => false;

  String _roleLabel(dynamic role) {
    final s = role.toString().toLowerCase();
    if (s.contains('assistant')) return 'Assistant';
    if (s.contains('system')) return 'System';
    return 'User';
  }

  String _messageText(dynamic message) {
    try {
      final content = (message as dynamic).content;
      if (content is String) return content;
      return content?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }
}

/// Resolved `--mcp-config` for one request — a path plus an optional
/// temp file to delete afterwards.
class _McpConfig {
  const _McpConfig(this.path, this._temp);
  final String? path;
  final File? _temp;
  Future<void> cleanup() async {
    final t = _temp;
    if (t != null) {
      try {
        await t.delete();
      } catch (_) {/* best-effort */}
    }
  }
}

/// Factory for `mcp_llm` registration. Knobs flow through
/// `LlmConfiguration.options` (`mcpConfig`, `model`, `replaceSystem`).
class ClaudeCodeInteractiveProviderFactory implements CustomLlmProviderFactory {
  @override
  String get name => 'claude_code_interactive';

  @override
  Set<LlmCapability> get capabilities => <LlmCapability>{
        LlmCapability.completion,
      };

  @override
  LlmProvider createProvider(LlmConfiguration config) {
    final opts = config.options ?? const <String, dynamic>{};
    return ClaudeCodeInteractiveProvider(
      mcpConfigPath: opts['mcpConfig'] as String?,
      model: opts['model'] as String?,
      replaceSystem: opts['replaceSystem'] == true,
    );
  }
}

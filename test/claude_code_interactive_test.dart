/// Tests for the no-`-p` Claude Code provider. The subprocess engine
/// (argv build) and the provider logic are tested without spawning
/// `claude` (via [FakeClaudeRunner]); a gated smoke test exercises the
/// real binary when present.
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:appplayer_claude_code_provider/appplayer_claude_code_provider.dart';
import 'package:test/test.dart';

void main() {
  group('buildClaudeArgs — no -p, prompt fixed after `--`', () {
    test('plain prompt → `--` then prompt', () {
      final args = buildClaudeArgs(const ClaudeInvocation(prompt: '2+2'));
      expect(args, <String>['--', '2+2']);
      expect(args, isNot(contains('-p')));
      expect(args, isNot(contains('--print')));
    });

    test('system → --append-system-prompt, then `--` then prompt', () {
      final args = buildClaudeArgs(
        const ClaudeInvocation(prompt: 'hi', system: 'Be terse.'),
      );
      expect(args, <String>['--append-system-prompt', 'Be terse.', '--', 'hi']);
    });

    test('replaceSystem → --system-prompt', () {
      final args = buildClaudeArgs(
        const ClaudeInvocation(
          prompt: 'hi',
          system: 'You are X.',
          replaceSystem: true,
        ),
      );
      expect(args.first, '--system-prompt');
    });

    test(
        '`--` immediately precedes the prompt so --mcp-config '
        '(variadic) cannot swallow it', () {
      final args = buildClaudeArgs(
        const ClaudeInvocation(
          prompt: 'go',
          model: 'opus',
          mcpConfigPath: '/tmp/mcp.json',
        ),
      );
      expect(args, containsAllInOrder(<String>['--model', 'opus']));
      expect(
          args, containsAllInOrder(<String>['--mcp-config', '/tmp/mcp.json']));
      // prompt is last, and the token right before it is `--`.
      expect(args.last, 'go');
      expect(args[args.length - 2], '--');
      expect(args, isNot(contains('-p')));
    });
  });

  group('provider — FakeClaudeRunner (no claude binary)', () {
    test('transformRequest maps prompt + system', () async {
      final p = ClaudeCodeInteractiveProvider(
        runner: FakeClaudeRunner((_) => ''),
      );
      final data = await p.transformRequest(
        LlmRequest(prompt: 'q', parameters: <String, dynamic>{'system': 's'}),
      );
      expect(data['prompt'], 'q');
      expect(data['system'], 's');
    });

    test('executeRequest forwards to runner and returns {text, metadata}',
        () async {
      late ClaudeInvocation seen;
      final p = ClaudeCodeInteractiveProvider(
        runner: FakeClaudeRunner((inv) {
          seen = inv;
          return '42';
        }),
      );
      final raw = await p.executeRequest(
        <String, dynamic>{'prompt': 'q', 'system': 's'},
        '',
        const <String, String>{},
      );
      expect(raw['text'], '42');
      expect((raw['metadata'] as Map)['mode'], 'subscription_no_print');
      expect(seen.prompt, 'q');
      expect(seen.system, 's');
    });

    test('history is folded into the prompt', () async {
      late ClaudeInvocation seen;
      final p = ClaudeCodeInteractiveProvider(
        runner: FakeClaudeRunner((inv) {
          seen = inv;
          return 'ok';
        }),
      );
      await p.executeRequest(
        <String, dynamic>{
          'prompt': 'and then?',
          'serializedHistory': 'User: hi\nAssistant: hello',
        },
        '',
        const <String, String>{},
      );
      expect(seen.prompt, contains('User: hi'));
      expect(seen.prompt, contains('and then?'));
    });

    test('full round-trip → LlmResponse', () async {
      final p = ClaudeCodeInteractiveProvider(
        runner: FakeClaudeRunner((_) => 'Bleu.'),
      );
      final data = await p.transformRequest(LlmRequest(prompt: 'color?'));
      final raw = await p.executeRequest(data, '', const <String, String>{});
      final resp = await p.transformResponse(raw);
      expect(resp.text, 'Bleu.');
      expect(resp.metadata['provider'], 'claude_code_interactive');
    });

    test('the invocation never yields a -p argv', () async {
      late ClaudeInvocation seen;
      final p = ClaudeCodeInteractiveProvider(
        runner: FakeClaudeRunner((inv) {
          seen = inv;
          return '';
        }),
      );
      await p.executeRequest(
        <String, dynamic>{'prompt': 'x'},
        '',
        const <String, String>{},
      );
      expect(buildClaudeArgs(seen), isNot(contains('-p')));
    });
  });

  group('integration smoke (real claude, no -p) — gated', () {
    final hasClaude = _which('claude') != null;

    test('claude "2+2" prints 4 on stdout (no -p, no TTY)', () async {
      final runner = ProcessClaudeRunner();
      final out = await runner.run(
        const ClaudeInvocation(
          prompt: 'What is 2+2? Reply with only the number, nothing else.',
        ),
      );
      expect(out.trim(), contains('4'));
    }, skip: hasClaude ? false : 'claude not on PATH');

    test('chat path through the provider: system + multi-turn recall',
        () async {
      // Real provider → real claude. System instruction applied and prior
      // turns (folded into the prompt) carry context — the actual "chat"
      // path the studio drives, minus the UI.
      final provider = ClaudeCodeInteractiveProvider();
      final raw = await provider.executeRequest(
        <String, dynamic>{
          'prompt': 'What is my name? Reply with only the name.',
          'system': 'You are terse.',
          'serializedHistory': 'User: My name is Jin.\nAssistant: Got it, Jin.',
        },
        '',
        const <String, String>{},
      );
      final resp = await provider.transformResponse(raw);
      expect(resp.text, contains('Jin'));
    },
        skip: hasClaude ? false : 'claude not on PATH',
        timeout: const Timeout(Duration(seconds: 60)));

    test('--mcp-config present does NOT swallow the prompt (regression)',
        () async {
      // claude 2.1.x `--mcp-config` is variadic; without the `--`
      // separator it ate the prompt as a config path. A down MCP server
      // is non-fatal — the prompt must still be answered.
      final cfg = File(
        '${Directory.systemTemp.path}/cc_it_regress_'
        '${DateTime.now().microsecondsSinceEpoch}.json',
      );
      await cfg.writeAsString(
        '{"mcpServers":{"host":{"type":"http",'
        '"url":"http://127.0.0.1:7841/mcp"}}}',
      );
      try {
        final out = await ProcessClaudeRunner().run(
          ClaudeInvocation(
            prompt: 'Reply with exactly: PONG',
            mcpConfigPath: cfg.path,
          ),
        );
        expect(out, contains('PONG'));
      } finally {
        try {
          await cfg.delete();
        } catch (_) {/* best-effort */}
      }
    },
        skip: hasClaude ? false : 'claude not on PATH',
        timeout: const Timeout(Duration(seconds: 60)));
  });
}

String? _which(String exe) {
  final paths = (Platform.environment['PATH'] ?? '').split(':');
  for (final dir in paths) {
    final f = File('$dir/$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}

import 'dart:io';

import 'package:gitwhisper/src/acp/acp_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AcpClient live activity and timeouts', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gw_acp_client_test_');
    });

    tearDown(() => dir.delete(recursive: true));

    test(
      'surfaces agent tool calls through onActivity',
      () async {
        final script = File(p.join(dir.path, 'fake_acp.py'))
          ..writeAsStringSync(_activityScript);
        final activities = <AcpToolActivity>[];
        final statuses = <AcpStatusEvent>[];

        final client = AcpClient(
          executable: 'python3',
          arguments: <String>[script.path],
          onActivity: activities.add,
          onStatus: statuses.add,
        );

        final text = await client.prompt(cwd: dir.path, text: 'go');

        expect(text, 'feat: add helpers');
        expect(
          statuses.map((status) => (status.phase, status.title)),
          containsAll(<(AcpStatusPhase, String)>[
            (AcpStatusPhase.started, 'Launching ACP process'),
            (AcpStatusPhase.completed, 'Launching ACP process'),
            (AcpStatusPhase.started, 'Initializing ACP agent'),
            (AcpStatusPhase.completed, 'Initializing ACP agent'),
            (AcpStatusPhase.started, 'Starting ACP session'),
            (AcpStatusPhase.completed, 'Starting ACP session'),
            (
              AcpStatusPhase.started,
              'Waiting for ACP agent to inspect staged changes',
            ),
            (
              AcpStatusPhase.completed,
              'Waiting for ACP agent to inspect staged changes',
            ),
          ]),
        );
        expect(
          statuses
              .where((status) => status.phase == AcpStatusPhase.completed)
              .map((status) => status.elapsed),
          everyElement(isNotNull),
        );

        // No-arg tool: emitted once (on completion), no path.
        final listCalls =
            activities.where((a) => a.title.contains('list_staged_files'));
        expect(listCalls.length, 1);
        expect(listCalls.single.path, isNull);

        // Path tool where the path only arrives in a later tool_call_update
        // (the claude-acp shape) must still surface the filename, once.
        final diffCalls =
            activities.where((a) => a.title.contains('get_file_diff')).toList();
        expect(diffCalls.length, 1);
        expect(diffCalls.single.path, 'lib/src/foo.dart');
      },
      skip: Platform.isWindows ? 'POSIX fake agent only' : null,
    );

    test(
      'initialize fails fast with a helpful hint when the agent stalls',
      () async {
        final script = File(p.join(dir.path, 'stalled_acp.py'))
          ..writeAsStringSync(_stalledScript);

        final client = AcpClient(
          executable: 'python3',
          arguments: <String>[script.path],
          initializeTimeout: const Duration(milliseconds: 300),
          timeout: const Duration(seconds: 10),
        );

        await expectLater(
          client.prompt(cwd: dir.path, text: 'go'),
          throwsA(
            isA<AcpException>().having(
              (e) => e.message,
              'message',
              allOf(contains('initialize'), contains('did not start in time')),
            ),
          ),
        );
      },
      skip: Platform.isWindows ? 'POSIX fake agent only' : null,
    );
  });

  test('ACP auth errors explain agent provider setup', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32603,
      'message': 'Internal error',
      'data': 'OpenAI Chat Completions error (status 401 Unauthorized): '
          "You didn't provide an API key.",
    });

    expect(error.message, contains('model provider is not authenticated'));
    expect(error.message, contains('login command'));
    expect(error.message, contains('provider API key'));
  });

  test('ACP structured auth methods are shown as recovery instructions', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32000,
      'message': 'Authentication required',
      'data': <String, dynamic>{
        'authMethods': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'login',
            'name': 'Login with Kimi account',
            'description': 'Run `kimi login` command in the terminal, then '
                'follow the instructions to finish login.',
            'type': 'terminal',
            'args': <String>['login'],
            'env': <String, dynamic>{},
          },
        ],
      },
    });

    expect(error, isA<AcpAuthenticationRequiredException>());
    expect(error.message, contains('Authentication required'));
    expect(error.message, contains('Login with Kimi account'));
    expect(error.message, contains('kimi login'));
    expect(error.message, isNot(contains('{authMethods')));
  });

  test('ACP auth message fallback extracts terminal command instructions', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32000,
      'message': 'Authentication required',
      'data': <String, dynamic>{
        'message': 'Run `pool login` in a terminal to authenticate to '
            'Poolside.',
      },
    });

    expect(error, isA<AcpAuthenticationRequiredException>());
    final authError = error as AcpAuthenticationRequiredException;
    expect(authError.authMethods.single.command, ['pool', 'login']);
    expect(authError.message, contains('pool login'));
    expect(authError.message, isNot(contains('{message')));
  });

  test('ACP auth message fallback extracts Cursor login and method id', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32000,
      'message': 'Authentication required',
      'data': <String, dynamic>{
        'message': "Authentication required. Please run 'agent login' first, "
            "then call authenticate() with methodId 'cursor_login'.",
      },
    });

    expect(error, isA<AcpAuthenticationRequiredException>());
    final authError = error as AcpAuthenticationRequiredException;
    final method = authError.authMethods.single;
    expect(method.command, ['agent', 'login']);
    expect(method.authenticateMethodId, 'cursor_login');
    expect(authError.message, isNot(contains('{message}')));
  });

  test('ACP auth method parser reads terminal-auth metadata', () {
    final method = AcpAuthMethod.fromJson(<String, dynamic>{
      'id': 'login',
      'name': 'Login with Kimi account',
      'description': 'Run `kimi login`.',
      '_meta': <String, dynamic>{
        'terminal-auth': <String, dynamic>{
          'command': '/tmp/kimi',
          'args': <String>['login'],
          'type': 'terminal',
          'env': <String, dynamic>{'KIMI_TEST': '1'},
        },
      },
    });

    expect(method.isTerminal, isTrue);
    expect(method.command, ['/tmp/kimi', 'login']);
    expect(method.environment, containsPair('KIMI_TEST', '1'));
  });
}

const _activityScript = '''
import json
import sys

for line in sys.stdin:
    if not line.strip():
        continue
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "authMethods": []}}), flush=True)
    elif method == "session/new":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "s1"}}), flush=True)
    elif method == "session/prompt":
        # No-arg tool: pending then completed, never carries a path (emit once
        # on completion, no filename).
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "mcp__gitwhisper__list_staged_files", "kind": "read", "status": "pending"}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"}}}), flush=True)
        # Path tool, claude-acp shape: path only arrives in a follow-up update.
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call", "toolCallId": "t2", "title": "mcp__gitwhisper__get_file_diff", "kind": "read", "status": "pending"}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call_update", "toolCallId": "t2", "rawInput": {"path": "lib/src/foo.dart"}}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call_update", "toolCallId": "t2", "status": "completed"}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "feat: add helpers"}}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}}), flush=True)
        break
''';

const _stalledScript = '''
import sys
import time

# Read the initialize request but never respond, forcing a fast-fail timeout.
for line in sys.stdin:
    time.sleep(10)
''';

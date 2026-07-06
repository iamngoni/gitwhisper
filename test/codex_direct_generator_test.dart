import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/models/codex_direct_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CodexDirectGenerator', () {
    test('uses Codex auth.json and executes Responses tool calls', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'chatgpt-token');

      final requests = <_CapturedRequest>[];
      final generator = CodexDirectGenerator(
        codexHome: root.path,
        environment: const <String, String>{},
        variant: 'gpt-test',
        postResponses: (endpoint, headers, body) async {
          requests.add(_CapturedRequest(endpoint, headers, body));
          if (requests.length == 1) {
            return <String, dynamic>{
              'output': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'function_call',
                  'call_id': 'call_1',
                  'name': 'list_staged_files',
                  'arguments': '{}',
                },
              ],
            };
          }
          return <String, dynamic>{
            'output': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'message',
                'content': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'output_text',
                    'text': 'docs: Update README title',
                  },
                ],
              },
            ],
          };
        },
      );

      final message = await generator.generateAgentCommitMessage(
        AgentCommitRequest(
          tools: GitAgentTools(
            folderPath: root.path,
            onToolUse: (_) {},
          ),
          language: Language.english,
          withEmoji: false,
        ),
      );

      expect(message, 'docs: Update README title');
      expect(requests, hasLength(2));
      expect(
        requests.first.endpoint.toString(),
        'https://chatgpt.com/backend-api/codex/responses',
      );
      expect(requests.first.headers['Authorization'], 'Bearer chatgpt-token');
      expect(requests.first.headers['ChatGPT-Account-ID'], 'account_123');
      expect(requests.first.body['model'], 'gpt-test');
      expect(requests.first.body['tools'], isA<List<dynamic>>());
      expect(
        requests.last.body['input'],
        contains(
          containsPair('type', 'function_call_output'),
        ),
      );
    });

    test('runs codex login when auth.json is missing', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      var loginCount = 0;

      final generator = CodexDirectGenerator(
        codexHome: root.path,
        environment: const <String, String>{},
        variant: 'gpt-test',
        runLogin: (executable, arguments) async {
          loginCount++;
          expect(executable, 'codex');
          expect(arguments, <String>['login']);
          await _writeAuthJson(root, accessToken: 'after-login-token');
          return 0;
        },
        postResponses: (endpoint, headers, body) async {
          return <String, dynamic>{
            'output_text': 'docs: Add setup notes',
          };
        },
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(message, 'docs: Add setup notes');
      expect(loginCount, 1);
    });

    test('reads Codex config model as default variant', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await File(p.join(root.path, 'config.toml')).writeAsString(
        'model = "gpt-custom"\n[profiles.work]\nmodel = "ignored"\n',
      );

      final generator = CodexDirectGenerator(
        codexHome: root.path,
        environment: const <String, String>{},
      );

      expect(generator.defaultVariant, 'gpt-custom');
    });
  });
}

Future<void> _writeAuthJson(
  Directory root, {
  required String accessToken,
}) async {
  final file = File(p.join(root.path, 'auth.json'));
  await file.writeAsString(
    jsonEncode(<String, dynamic>{
      'auth_mode': 'chatgpt',
      'tokens': <String, dynamic>{
        'id_token': _jwt(<String, dynamic>{
          'https://api.openai.com/auth': <String, dynamic>{
            'chatgpt_account_id': 'account_123',
          },
        }),
        'access_token': accessToken,
        'refresh_token': 'refresh-token',
        'account_id': 'account_123',
      },
    }),
  );
}

String _jwt(Map<String, dynamic> payload) {
  String encode(Map<String, dynamic> value) {
    return base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  }

  return '${encode(<String, dynamic>{'alg': 'none'})}.${encode(payload)}.sig';
}

class _CapturedRequest {
  const _CapturedRequest(this.endpoint, this.headers, this.body);

  final Uri endpoint;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

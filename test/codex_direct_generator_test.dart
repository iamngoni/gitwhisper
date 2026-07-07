import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/constants.dart';
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
                  'id': 'rs_tool_call',
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
      expect(requests.first.body['stream'], isTrue);
      expect(requests.first.body['tools'], isA<List<dynamic>>());
      expect(
        requests.last.body['input'],
        contains(
          containsPair('type', 'function_call_output'),
        ),
      );
      expect(requests.last.body['input'].toString(), isNot(contains('rs_')));
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

    test('parses streaming Responses SSE from Codex endpoint', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'chatgpt-token');
      final capturedRequests = <RequestOptions>[];
      final interceptor = InterceptorsWrapper(
        onRequest: (options, handler) {
          capturedRequests.add(options);
          handler.resolve(
            Response<ResponseBody>(
              requestOptions: options,
              statusCode: 200,
              data: ResponseBody.fromString(
                [
                  _sse(
                    'response.output_text.delta',
                    <String, dynamic>{
                      'type': 'response.output_text.delta',
                      'delta': 'docs: ',
                    },
                  ),
                  _sse(
                    'response.output_text.delta',
                    <String, dynamic>{
                      'type': 'response.output_text.delta',
                      'delta': 'Stream Codex responses',
                    },
                  ),
                  _sse(
                    'response.output_item.done',
                    <String, dynamic>{
                      'type': 'response.output_item.done',
                      'item': <String, dynamic>{
                        'type': 'message',
                        'role': 'assistant',
                        'content': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'type': 'output_text',
                            'text': 'docs: Stream Codex responses',
                          },
                        ],
                      },
                    },
                  ),
                  _sse(
                    'response.completed',
                    <String, dynamic>{
                      'type': 'response.completed',
                      'response': <String, dynamic>{'id': 'resp_1'},
                    },
                  ),
                ].join(),
                200,
              ),
            ),
          );
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final generator = CodexDirectGenerator(
        codexHome: root.path,
        environment: const <String, String>{},
        variant: 'gpt-test',
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(message, 'docs: Stream Codex responses');
      expect(capturedRequests, hasLength(1));
      expect(capturedRequests.single.responseType, ResponseType.stream);
      expect(capturedRequests.single.headers['Accept'], 'text/event-stream');
      final body = capturedRequests.single.data as Map<String, dynamic>;
      expect(body['stream'], isTrue);
    });

    test('refreshes expired ChatGPT auth before request', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(
        root,
        accessToken: _jwt(<String, dynamic>{
          'exp': DateTime.now()
                  .toUtc()
                  .subtract(const Duration(minutes: 1))
                  .millisecondsSinceEpoch ~/
              1000,
        }),
      );

      final responseRequests = <RequestOptions>[];
      final refreshBodies = <Map<String, dynamic>>[];
      final interceptor = InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.toString() == 'https://auth.openai.com/oauth/token') {
            refreshBodies.add(Map<String, dynamic>.from(options.data as Map));
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'access_token': 'fresh-token',
                  'refresh_token': 'fresh-refresh-token',
                },
              ),
            );
            return;
          }

          responseRequests.add(options);
          handler.resolve(
            Response<ResponseBody>(
              requestOptions: options,
              statusCode: 200,
              data: ResponseBody.fromString(
                _streamingCommitMessage('docs: Refresh Codex auth'),
                200,
              ),
            ),
          );
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final generator = CodexDirectGenerator(
        codexHome: root.path,
        environment: const <String, String>{},
        variant: 'gpt-test',
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(message, 'docs: Refresh Codex auth');
      expect(refreshBodies, hasLength(1));
      expect(refreshBodies.single['refresh_token'], 'refresh-token');
      expect(responseRequests, hasLength(1));
      expect(
        responseRequests.single.headers['Authorization'],
        'Bearer fresh-token',
      );

      final storedAuth = jsonDecode(
        await File(p.join(root.path, 'auth.json')).readAsString(),
      ) as Map<String, dynamic>;
      final tokens = Map<String, dynamic>.from(
        storedAuth['tokens'] as Map<dynamic, dynamic>,
      );
      expect(tokens['access_token'], 'fresh-token');
      expect(tokens['refresh_token'], 'fresh-refresh-token');
    });

    test('refreshes and retries once after Codex 401', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'stale-token');

      final responseRequests = <RequestOptions>[];
      final refreshBodies = <Map<String, dynamic>>[];
      final interceptor = InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.toString() == 'https://auth.openai.com/oauth/token') {
            refreshBodies.add(Map<String, dynamic>.from(options.data as Map));
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'access_token': 'fresh-token',
                  'refresh_token': 'fresh-refresh-token',
                },
              ),
            );
            return;
          }

          responseRequests.add(options);
          if (responseRequests.length == 1) {
            handler.resolve(
              Response<ResponseBody>(
                requestOptions: options,
                statusCode: 401,
                data: ResponseBody.fromString(
                  jsonEncode(<String, dynamic>{
                    'error': <String, dynamic>{
                      'message': 'Invalid authentication credentials',
                      'type': 'authentication_error',
                    },
                  }),
                  401,
                ),
              ),
            );
            return;
          }

          handler.resolve(
            Response<ResponseBody>(
              requestOptions: options,
              statusCode: 200,
              data: ResponseBody.fromString(
                _streamingCommitMessage('docs: Retry Codex auth'),
                200,
              ),
            ),
          );
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final generator = CodexDirectGenerator(
        codexHome: root.path,
        environment: const <String, String>{},
        variant: 'gpt-test',
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(message, 'docs: Retry Codex auth');
      expect(refreshBodies, hasLength(1));
      expect(refreshBodies.single['refresh_token'], 'refresh-token');
      expect(responseRequests, hasLength(2));
      expect(
        responseRequests.first.headers['Authorization'],
        'Bearer stale-token',
      );
      expect(
        responseRequests.last.headers['Authorization'],
        'Bearer fresh-token',
      );
    });

    test('retries once when agent returns prose instead of a header', () async {
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
              'output_text': 'I inspected the staged changes.',
            };
          }
          return <String, dynamic>{
            'output_text': 'feat: Add direct Codex harness',
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

      expect(message, 'feat: Add direct Codex harness');
      expect(requests, hasLength(2));
      expect(
        requests.last.body['input'].toString(),
        contains('return only the final conventional commit message'),
      );
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

String _sse(String event, Map<String, dynamic> data) {
  return 'event: $event\ndata: ${jsonEncode(data)}\n\n';
}

String _streamingCommitMessage(String message) {
  return [
    _sse(
      'response.output_text.delta',
      <String, dynamic>{
        'type': 'response.output_text.delta',
        'delta': message,
      },
    ),
    _sse(
      'response.completed',
      <String, dynamic>{
        'type': 'response.completed',
        'response': <String, dynamic>{'id': 'resp_1'},
      },
    ),
  ].join();
}

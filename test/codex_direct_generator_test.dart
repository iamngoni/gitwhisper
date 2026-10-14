import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/constants.dart';
import 'package:gitwhisper/src/exceptions/exceptions.dart';
import 'package:gitwhisper/src/models/codex_direct_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:gitwhisper/src/models/model_variants.dart';
import 'package:gitwhisper/src/private_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CodexDirectGenerator', () {
    test('uses Codex auth.json and executes Responses tool calls', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'chatgpt-token');

      final requests = <_CapturedRequest>[];
      final generator = _codexGenerator(
        root,
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

      final generator = _codexGenerator(
        root,
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

      final generator = _codexGenerator(
        root,
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

      final generator = _codexGenerator(
        root,
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

      final generator = _codexGenerator(
        root,
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

      final generator = _codexGenerator(
        root,
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
      final generator = _codexGenerator(
        root,
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

    test('asks for the final message with tools disabled at the budget',
        () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'chatgpt-token');

      final bodies = <Map<String, dynamic>>[];
      final executedTools = <String>[];
      final generator = _codexGenerator(
        root,
        variant: 'gpt-test',
        postResponses: (endpoint, headers, body) async {
          bodies.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
          if (bodies.length == 1) {
            return <String, dynamic>{
              'output': <Map<String, dynamic>>[
                _functionCall('call_1', 'first_tool'),
                _functionCall('call_2', 'second_tool'),
              ],
            };
          }
          return <String, dynamic>{'output_text': 'docs: Finish in budget'};
        },
      );

      final message = await generator.generateAgentCommitMessage(
        AgentCommitRequest(
          tools: GitAgentTools(
            folderPath: root.path,
            onToolUse: (toolUse) => executedTools.add(toolUse.name),
          ),
          language: Language.english,
          withEmoji: false,
          maxToolCalls: 1,
        ),
      );

      expect(message, 'docs: Finish in budget');
      expect(bodies.map((body) => body['tool_choice']), <String>[
        'auto',
        'none',
      ]);
      expect(bodies.last['tools'], isNotEmpty);
      expect(executedTools, <String>['first_tool']);

      final input =
          (bodies.last['input'] as List<dynamic>).cast<Map<dynamic, dynamic>>();
      final outputs = input
          .where((item) => item['type'] == 'function_call_output')
          .map((item) => item['output'].toString())
          .toList();
      expect(outputs, hasLength(2));
      expect(outputs.last, contains('limit of 1 tool calls was reached'));
      expect(
        input.last.toString(),
        contains('You have used all available tool calls'),
      );
    });

    test('rejects incomplete Codex responses', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'chatgpt-token');

      final generator = _codexGenerator(
        root,
        variant: 'gpt-test',
        postResponses: (endpoint, headers, body) async => <String, dynamic>{
          'status': 'incomplete',
          'incomplete_details': <String, dynamic>{
            'reason': 'max_output_tokens',
          },
          'output_text': 'docs: Cut off mid',
        },
      );

      await expectLater(
        generator.generateCommitMessage(
          'diff --git a/README.md b/README.md\n+Docs',
          Language.english,
          withEmoji: false,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Codex response was incomplete (max_output_tokens).',
          ),
        ),
      );
    });

    test('names the reason for an incomplete Codex stream', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'chatgpt-token');
      final interceptor = InterceptorsWrapper(
        onRequest: (options, handler) {
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
                      'delta': 'docs: Cut off',
                    },
                  ),
                  _sse(
                    'response.incomplete',
                    <String, dynamic>{
                      'type': 'response.incomplete',
                      'response': <String, dynamic>{
                        'status': 'incomplete',
                        'incomplete_details': <String, dynamic>{
                          'reason': 'max_output_tokens',
                        },
                      },
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

      await expectLater(
        _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
          'diff --git a/README.md b/README.md\n+Docs',
          Language.english,
          withEmoji: false,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('max_output_tokens'),
          ),
        ),
      );
    });

    test('adopts a token Codex saved during a request that got a 401',
        () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: 'stale-token');

      var refreshCount = 0;
      final interceptor = _codexInterceptor(
        responseRequests: <RequestOptions>[],
        onRefresh: (options, handler) {
          refreshCount++;
          _resolveFreshTokens(options, handler);
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final requests = <_CapturedRequest>[];
      final generator = _codexGenerator(
        root,
        variant: 'gpt-test',
        postResponses: (endpoint, headers, body) async {
          requests.add(_CapturedRequest(endpoint, headers, body));
          if (requests.length == 1) {
            // Codex refreshed while this request was in flight.
            await _writeAuthJson(
              root,
              accessToken: 'codex-cli-token',
              refreshToken: 'codex-cli-refresh-token',
            );
            throw _unauthorized(endpoint);
          }
          return <String, dynamic>{'output_text': 'docs: Adopt Codex token'};
        },
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(message, 'docs: Adopt Codex token');
      expect(refreshCount, 0);
      expect(
        requests.last.headers['Authorization'],
        'Bearer codex-cli-token',
      );
    });

    test(
      'merges refreshed tokens into the latest auth.json and saves it '
      'privately',
      () async {
        final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
        addTearDown(() => root.delete(recursive: true));
        await _writeAuthJson(
          root,
          accessToken: _expiredJwt(),
          extra: <String, dynamic>{'OPENAI_API_KEY': null},
        );

        final interceptor = _codexInterceptor(
          responseRequests: <RequestOptions>[],
          onRefresh: (options, handler) {
            // Codex changes another field while the refresh is running.
            final authJson = _readAuthJsonFile(root);
            authJson['last_refresh'] = 'from-codex';
            authJson['preferred_setting'] = 'updated';
            File(p.join(root.path, 'auth.json'))
                .writeAsStringSync(jsonEncode(authJson));
            _resolveFreshTokens(options, handler);
          },
        );
        $dio.interceptors.add(interceptor);
        addTearDown(() => $dio.interceptors.remove(interceptor));

        final staged = _recordStagedFiles();
        await _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
          'diff --git a/README.md b/README.md\n+Docs',
          Language.english,
          withEmoji: false,
        );

        // The temp file sits in a fresh 0700 directory next to auth.json and
        // is 0600 before anything is written to it, so no other user can
        // ever open it.
        expect(staged, hasLength(1));
        expect(staged.single.stagingParent, root.path);
        expect(staged.single.stagingMode, 0x1C0);
        expect(staged.single.fileMode, 0x180);
        expect(staged.single.length, 0);

        final authJson = _readAuthJsonFile(root);
        expect(authJson['preferred_setting'], 'updated');
        expect(authJson, containsPair('OPENAI_API_KEY', null));
        final tokens = authJson['tokens'] as Map<String, dynamic>;
        expect(tokens['access_token'], 'fresh-token');
        expect(tokens['refresh_token'], 'fresh-refresh-token');
        expect(tokens['account_id'], 'account_123');

        final authFile = File(p.join(root.path, 'auth.json'));
        expect(authFile.statSync().mode & 0x1FF, 0x180);
        expect(
          root.listSync().where((entity) => entity.path.endsWith('.tmp')),
          isEmpty,
        );
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );

    test('keeps tokens Codex saved while a refresh was running', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: _expiredJwt());

      final responseRequests = <RequestOptions>[];
      final interceptor = _codexInterceptor(
        responseRequests: responseRequests,
        onRefresh: (options, handler) {
          File(p.join(root.path, 'auth.json')).writeAsStringSync(
            jsonEncode(<String, dynamic>{
              'auth_mode': 'chatgpt',
              'tokens': <String, dynamic>{
                'access_token': 'codex-cli-token',
                'refresh_token': 'codex-cli-refresh-token',
                'account_id': 'account_123',
              },
            }),
          );
          _resolveFreshTokens(options, handler);
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      await _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(
        responseRequests.single.headers['Authorization'],
        'Bearer codex-cli-token',
      );
      final tokens = _readAuthJsonFile(root)['tokens'] as Map<String, dynamic>;
      expect(tokens['access_token'], 'codex-cli-token');
      expect(tokens['refresh_token'], 'codex-cli-refresh-token');
    });

    test('reports refresh failures as authentication errors without tokens',
        () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: _expiredJwt());

      final interceptor = _codexInterceptor(
        responseRequests: <RequestOptions>[],
        onRefresh: (options, handler) {
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 400,
              data: <String, dynamic>{
                'error': 'invalid_grant',
                'error_description':
                    'Refresh token refresh-token was already used.',
              },
            ),
          );
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      await expectLater(
        _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
          'diff --git a/README.md b/README.md\n+Docs',
          Language.english,
          withEmoji: false,
        ),
        throwsA(
          isA<AuthenticationException>()
              .having((error) => error.statusCode, 'statusCode', 400)
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('status 400'),
                  contains('was already used'),
                  isNot(contains('refresh-token')),
                ),
              ),
        ),
      );
    });

    test('converts rejected refresh requests to authentication errors',
        () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: _expiredJwt());

      final interceptor = _codexInterceptor(
        responseRequests: <RequestOptions>[],
        onRefresh: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 401,
                data: <String, dynamic>{
                  'error': <String, dynamic>{
                    'message': 'Your refresh token has expired.',
                    'code': 'refresh_token_expired',
                  },
                },
              ),
            ),
          );
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      await expectLater(
        _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
          'diff --git a/README.md b/README.md\n+Docs',
          Language.english,
          withEmoji: false,
        ),
        throwsA(
          isA<AuthenticationException>().having(
            (error) => error.message,
            'message',
            contains('Your refresh token has expired.'),
          ),
        ),
      );
    });

    test(
      'keeps refreshed tokens in memory when auth.json cannot be saved',
      () async {
        final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
        addTearDown(() => root.delete(recursive: true));
        await _writeAuthJson(root, accessToken: _expiredJwt());
        Process.runSync('chmod', <String>['555', root.path]);
        addTearDown(() => Process.runSync('chmod', <String>['755', root.path]));
        try {
          File(p.join(root.path, 'probe')).createSync();
          markTestSkipped('Directory permissions are not enforced (root?).');
          return;
        } on FileSystemException {
          // Expected: the Codex home is read-only.
        }

        var refreshCount = 0;
        final responseRequests = <RequestOptions>[];
        final interceptor = _codexInterceptor(
          responseRequests: responseRequests,
          onRefresh: (options, handler) {
            refreshCount++;
            _resolveFreshTokens(options, handler);
          },
        );
        $dio.interceptors.add(interceptor);
        addTearDown(() => $dio.interceptors.remove(interceptor));

        final generator = _codexGenerator(root, variant: 'gpt-test');
        for (var attempt = 0; attempt < 2; attempt++) {
          await generator.generateCommitMessage(
            'diff --git a/README.md b/README.md\n+Docs',
            Language.english,
            withEmoji: false,
          );
        }

        expect(refreshCount, 1);
        expect(
          responseRequests.map((request) => request.headers['Authorization']),
          <String>['Bearer fresh-token', 'Bearer fresh-token'],
        );
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );

    test('does not use the working directory when no home is known', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));

      await expectLater(
        _codexGenerator(
          root,
          useEnvironmentCodexHome: true,
          environment: const <String, String>{'HOME': ''},
        ).generateCommitMessage('diff', Language.english),
        throwsA(
          isA<AuthenticationException>().having(
            (error) => error.message,
            'message',
            contains('Codex home'),
          ),
        ),
      );
    });

    test(
      'does not use a relative HOME',
      () async {
        final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
        addTearDown(() => root.delete(recursive: true));
        // Relative to the working directory, this HOME reaches a folder with
        // credentials. Using it would let a repository supply them.
        final codexHome = Directory(p.join(root.path, 'home', '.codex'))
          ..createSync(recursive: true);
        await _writeAuthJson(codexHome, accessToken: 'cwd-token');

        await expectLater(
          _codexGenerator(
            root,
            useEnvironmentCodexHome: true,
            environment: <String, String>{
              'HOME': p.relative(codexHome.parent.path),
            },
            postResponses: (endpoint, headers, body) async {
              throw StateError('Network requests are disabled in tests.');
            },
          ).generateCommitMessage('diff', Language.english),
          throwsA(
            isA<AuthenticationException>().having(
              (error) => error.message,
              'message',
              contains('Codex home'),
            ),
          ),
        );
      },
      skip: Platform.isWindows ? 'Windows uses USERPROFILE.' : false,
    );

    test(
      'refuses an auth.json that is not a regular file or is too large',
      () async {
        final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
        addTearDown(() => root.delete(recursive: true));
        final authPath = p.join(root.path, 'auth.json');

        Link(authPath).createSync('/dev/zero');
        await expectLater(
          _codexGenerator(root, variant: 'gpt-test')
              .generateCommitMessage('diff', Language.english),
          throwsA(
            isA<AuthenticationException>().having(
              (error) => error.message,
              'message',
              contains('not a regular file'),
            ),
          ),
        );

        Link(authPath).deleteSync();
        await _writeAuthJson(
          root,
          accessToken: 'chatgpt-token',
          extra: <String, dynamic>{'padding': 'x' * (1024 * 1024)},
        );
        await expectLater(
          _codexGenerator(root, variant: 'gpt-test')
              .generateCommitMessage('diff', Language.english),
          throwsA(
            isA<AuthenticationException>().having(
              (error) => error.message,
              'message',
              contains('larger than 1 MiB'),
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
      skip: Platform.isWindows ? 'Uses /dev/zero.' : false,
    );

    test(
      'ignores a config.toml that is not a regular file',
      () async {
        final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
        addTearDown(() => root.delete(recursive: true));
        Link(p.join(root.path, 'config.toml')).createSync('/dev/zero');

        expect(
          _codexGenerator(root).defaultVariant,
          ModelVariants.getDefault('codex'),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
      skip: Platform.isWindows ? 'Uses /dev/zero.' : false,
    );

    test('does not re-create auth.json removed during a refresh', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: _expiredJwt());

      var refreshCount = 0;
      final responseRequests = <RequestOptions>[];
      final interceptor = _codexInterceptor(
        responseRequests: responseRequests,
        onRefresh: (options, handler) {
          refreshCount++;
          // `codex logout` runs while the refresh request is in flight.
          File(p.join(root.path, 'auth.json')).deleteSync();
          _resolveFreshTokens(options, handler);
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final generator = _codexGenerator(root, variant: 'gpt-test');
      for (var attempt = 0; attempt < 2; attempt++) {
        await generator.generateCommitMessage(
          'diff --git a/README.md b/README.md\n+Docs',
          Language.english,
          withEmoji: false,
        );
      }

      expect(refreshCount, 1);
      expect(File(p.join(root.path, 'auth.json')).existsSync(), isFalse);
      expect(
        responseRequests.map((request) => request.headers['Authorization']),
        <String>['Bearer fresh-token', 'Bearer fresh-token'],
      );
    });

    test('adopts an access token Codex saved with the same refresh token',
        () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: _expiredJwt());

      final responseRequests = <RequestOptions>[];
      final interceptor = _codexInterceptor(
        responseRequests: responseRequests,
        onRefresh: (options, handler) {
          // The refresh token was not rotated, so only the access token
          // tells that Codex refreshed too.
          _writeAuthJsonSync(root, accessToken: 'codex-cli-token');
          _resolveFreshTokens(options, handler);
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      await _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(
        responseRequests.single.headers['Authorization'],
        'Bearer codex-cli-token',
      );
      final tokens = _readAuthJsonFile(root)['tokens'] as Map<String, dynamic>;
      expect(tokens['access_token'], 'codex-cli-token');
      expect(tokens['refresh_token'], 'refresh-token');
    });

    test('adopts an API key login saved during a refresh', () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: _expiredJwt());

      final responseRequests = <RequestOptions>[];
      final apiKeyLogin = <String, dynamic>{
        'auth_mode': 'apikey',
        'OPENAI_API_KEY': 'sk-test-key',
      };
      final interceptor = _codexInterceptor(
        responseRequests: responseRequests,
        onRefresh: (options, handler) {
          File(p.join(root.path, 'auth.json'))
              .writeAsStringSync(jsonEncode(apiKeyLogin));
          _resolveFreshTokens(options, handler);
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      await _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );

      expect(
        responseRequests.single.headers['Authorization'],
        'Bearer sk-test-key',
      );
      expect(_readAuthJsonFile(root), apiKeyLogin);
    });

    test('waits for another gitwhisper refresh and adopts its tokens',
        () async {
      final root = await Directory.systemTemp.createTemp('gitwhisper_codex_');
      addTearDown(() => root.delete(recursive: true));
      await _writeAuthJson(root, accessToken: _expiredJwt());
      final lockHolder = await _startLockHolder(
        root,
        File(p.join(root.path, '.gitwhisper-oauth-refresh.lock')),
      );
      addTearDown(lockHolder.kill);

      var refreshCount = 0;
      final responseRequests = <RequestOptions>[];
      final interceptor = _codexInterceptor(
        responseRequests: responseRequests,
        onRefresh: (options, handler) {
          refreshCount++;
          _resolveFreshTokens(options, handler);
        },
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final messageFuture =
          _codexGenerator(root, variant: 'gpt-test').generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
        withEmoji: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(refreshCount, 0, reason: 'refresh must wait for the lock');

      // The other process finishes its refresh, saves, and unlocks.
      await _writeAuthJson(
        root,
        accessToken: 'other-process-token',
        refreshToken: 'other-process-refresh-token',
      );
      await lockHolder.stdin.close();
      await lockHolder.exitCode;

      await messageFuture;

      expect(refreshCount, 0);
      expect(
        responseRequests.single.headers['Authorization'],
        'Bearer other-process-token',
      );
    });
  });
}

/// Records every file the private writer stages while the current test runs:
/// the directory it is staged in, that directory's mode, and the file's mode
/// and length before anything is written to it.
List<
    ({
      String stagingParent,
      int stagingMode,
      int fileMode,
      int length,
    })> _recordStagedFiles() {
  final staged = <({
    String stagingParent,
    int stagingMode,
    int fileMode,
    int length,
  })>[];
  debugOnPrivateFileStaged = (file) => staged.add(
        (
          stagingParent: file.parent.parent.path,
          stagingMode: file.parent.statSync().mode & 0x1FF,
          fileMode: file.statSync().mode & 0x1FF,
          length: file.lengthSync(),
        ),
      );
  addTearDown(() => debugOnPrivateFileStaged = null);
  return staged;
}

/// Starts a separate Dart process that holds [lockFile] until its stdin is
/// closed, standing in for another gitwhisper process mid-refresh.
Future<Process> _startLockHolder(Directory sandbox, File lockFile) async {
  final script = File(p.join(sandbox.path, 'hold_lock.dart'))
    ..writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> args) async {
  final handle = await File(args.single).open(mode: FileMode.append);
  await handle.lock();
  stdout.writeln('locked');
  await stdin.drain<void>();
  await handle.unlock();
  await handle.close();
}
''');
  final process = await Process.start(
    Platform.resolvedExecutable,
    <String>[script.path, lockFile.path],
  );
  await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((line) => line == 'locked')
      .timeout(const Duration(seconds: 60));
  return process;
}

/// Creates a generator that cannot touch the developer's real environment:
/// HOME points inside [root], auth.json is read from [root], and `codex
/// login` is a fake that throws unless a test passes its own.
CodexDirectGenerator _codexGenerator(
  Directory root, {
  Map<String, String> environment = const <String, String>{},
  bool useEnvironmentCodexHome = false,
  String? variant,
  CodexResponsesPoster? postResponses,
  CodexLoginRunner? runLogin,
}) {
  return CodexDirectGenerator(
    codexHome: useEnvironmentCodexHome ? null : root.path,
    environment: <String, String>{
      'HOME': p.join(root.path, 'home'),
      ...environment,
    },
    variant: variant,
    postResponses: postResponses,
    runLogin: runLogin ??
        (executable, arguments) async {
          throw StateError('codex login is disabled in tests.');
        },
  );
}

Future<void> _writeAuthJson(
  Directory root, {
  required String accessToken,
  String refreshToken = 'refresh-token',
  Map<String, dynamic> extra = const <String, dynamic>{},
}) async {
  _writeAuthJsonSync(
    root,
    accessToken: accessToken,
    refreshToken: refreshToken,
    extra: extra,
  );
}

void _writeAuthJsonSync(
  Directory root, {
  required String accessToken,
  String refreshToken = 'refresh-token',
  Map<String, dynamic> extra = const <String, dynamic>{},
}) {
  File(p.join(root.path, 'auth.json')).writeAsStringSync(
    jsonEncode(<String, dynamic>{
      'auth_mode': 'chatgpt',
      'tokens': <String, dynamic>{
        'id_token': _jwt(<String, dynamic>{
          'https://api.openai.com/auth': <String, dynamic>{
            'chatgpt_account_id': 'account_123',
          },
        }),
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'account_id': 'account_123',
      },
      ...extra,
    }),
  );
}

Map<String, dynamic> _functionCall(String callId, String name) {
  return <String, dynamic>{
    'type': 'function_call',
    'call_id': callId,
    'name': name,
    'arguments': '{}',
  };
}

String _expiredJwt() {
  return _jwt(<String, dynamic>{
    'exp': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch ~/
        1000,
  });
}

Map<String, dynamic> _readAuthJsonFile(Directory root) {
  return jsonDecode(File(p.join(root.path, 'auth.json')).readAsStringSync())
      as Map<String, dynamic>;
}

/// Answers Codex token refreshes with [onRefresh] and Responses requests
/// with a streamed commit message, recording the Responses requests.
InterceptorsWrapper _codexInterceptor({
  required List<RequestOptions> responseRequests,
  required void Function(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) onRefresh,
  String message = 'docs: Refresh Codex auth',
}) {
  return InterceptorsWrapper(
    onRequest: (options, handler) {
      if (options.uri.toString() == 'https://auth.openai.com/oauth/token') {
        onRefresh(options, handler);
        return;
      }
      responseRequests.add(options);
      handler.resolve(
        Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody.fromString(_streamingCommitMessage(message), 200),
        ),
      );
    },
  );
}

void _resolveFreshTokens(
  RequestOptions options,
  RequestInterceptorHandler handler,
) {
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
}

DioException _unauthorized(Uri endpoint) {
  final requestOptions = RequestOptions(path: endpoint.toString());
  return DioException(
    requestOptions: requestOptions,
    response: Response<dynamic>(
      requestOptions: requestOptions,
      statusCode: 401,
      data: <String, dynamic>{
        'error': <String, dynamic>{
          'message': 'Invalid authentication credentials',
          'type': 'authentication_error',
        },
      },
    ),
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

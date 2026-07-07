import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:gitwhisper/src/exceptions/exceptions.dart';
import 'package:gitwhisper/src/models/claude_code_direct_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeCodeDirectGenerator', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('gw-claude-code-');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('reads Claude Code OAuth credentials from config directory', () async {
      await _writeCredentials(tempDir, 'oauth-token');

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        useMacOsKeychain: false,
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer oauth-token');
      expect(
        headers['anthropic-beta'],
        'claude-code-20250219,oauth-2025-04-20',
      );
      expect(headers, isNot(contains('x-api-key')));
    });

    test('prefers macOS keychain OAuth credentials over config file', () async {
      await _writeCredentials(tempDir, 'file-token');

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        readMacOsKeychainService: (service) async {
          expect(service, 'Claude Code-credentials');
          return _credentialsJson('keychain-token');
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer keychain-token');
    });

    test('decodes hex macOS keychain OAuth credentials', () async {
      await _writeCredentials(tempDir, 'file-token');

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        readMacOsKeychainService: (service) async {
          expect(service, 'Claude Code-credentials');
          return _hex(_credentialsJson('keychain-token'));
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer keychain-token');
    });

    test('uses Claude Code keychain service hash for CLAUDE_CONFIG_DIR',
        () async {
      final expectedService =
          'Claude Code-credentials-${_configDirHash(tempDir.path)}';

      final generator = ClaudeCodeDirectGenerator(
        environment: <String, String>{
          'CLAUDE_CONFIG_DIR': tempDir.path,
        },
        readMacOsKeychainService: (service) async {
          expect(service, expectedService);
          return _credentialsJson('keychain-token');
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer keychain-token');
    });

    test('prefers macOS keychain API key over global config API key', () async {
      await File(pathFor(tempDir, '.claude.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'primaryApiKey': 'config-api-key',
        }),
      );

      final generator = ClaudeCodeDirectGenerator(
        environment: <String, String>{
          'HOME': tempDir.path,
        },
        readMacOsKeychainService: (service) async {
          if (service == 'Claude Code-credentials') return null;
          expect(service, 'Claude Code');
          return 'keychain-api-key';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['x-api-key'], 'keychain-api-key');
    });

    test('prefers external environment credentials over stored credentials',
        () async {
      await _writeCredentials(tempDir, 'stored-token');

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'ANTHROPIC_API_KEY': 'env-api-key',
          'ANTHROPIC_AUTH_TOKEN': 'env-auth-token',
        },
        useMacOsKeychain: false,
      );

      final headers = await generator.resolveHeaders();

      expect(headers['x-api-key'], 'env-api-key');
      expect(headers['Authorization'], 'Bearer env-auth-token');
      expect(headers['anthropic-beta'], 'claude-code-20250219');
    });

    test('uses apiKeyHelper from Claude Code user settings before stored OAuth',
        () async {
      await _writeCredentials(tempDir, 'stored-token');
      await File(pathFor(tempDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'print-helper-token',
        }),
      );

      var helperCalls = 0;
      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        useMacOsKeychain: false,
        runApiKeyHelper: (command, timeout) async {
          helperCalls += 1;
          expect(command, 'print-helper-token');
          expect(timeout, const Duration(minutes: 10));
          return 'helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(helperCalls, 1);
      expect(headers, isNot(contains('x-api-key')));
      expect(headers['Authorization'], 'Bearer helper-token');
      expect(headers['anthropic-beta'], 'claude-code-20250219');
    });

    test('uses local apiKeyHelper over project and user settings', () async {
      final userDir = Directory(pathFor(tempDir, 'user'))..createSync();
      final projectDir = Directory(pathFor(tempDir, 'project'))..createSync();
      final claudeDir = Directory(pathFor(projectDir, '.claude'))..createSync();
      await File(pathFor(userDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'user-helper',
        }),
      );
      await File(pathFor(claudeDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'project-helper',
        }),
      );
      await File(pathFor(claudeDir, 'settings.local.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'local-helper',
        }),
      );

      await _withCurrentDirectory(projectDir, () async {
        final generator = ClaudeCodeDirectGenerator(
          claudeConfigDir: userDir.path,
          environment: const <String, String>{},
          useMacOsKeychain: false,
          runApiKeyHelper: (command, timeout) async {
            expect(command, 'local-helper');
            return 'local-helper-token';
          },
        );

        final headers = await generator.resolveHeaders();

        expect(headers['Authorization'], 'Bearer local-helper-token');
      });
    });

    test('uses managed apiKeyHelper drop-in over local settings', () async {
      final userDir = Directory(pathFor(tempDir, 'user'))..createSync();
      final projectDir = Directory(pathFor(tempDir, 'project'))..createSync();
      final claudeDir = Directory(pathFor(projectDir, '.claude'))..createSync();
      final managedDir = Directory(pathFor(tempDir, 'managed'))..createSync();
      final dropInDir = Directory(pathFor(managedDir, 'managed-settings.d'))
        ..createSync();
      await File(pathFor(claudeDir, 'settings.local.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'local-helper',
        }),
      );
      await File(pathFor(managedDir, 'managed-settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'managed-base-helper',
        }),
      );
      await File(pathFor(dropInDir, '20-helper.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'managed-drop-in-helper',
        }),
      );

      await _withCurrentDirectory(projectDir, () async {
        final generator = ClaudeCodeDirectGenerator(
          claudeConfigDir: userDir.path,
          environment: <String, String>{
            'USER_TYPE': 'ant',
            'CLAUDE_CODE_MANAGED_SETTINGS_PATH': managedDir.path,
          },
          useMacOsKeychain: false,
          runApiKeyHelper: (command, timeout) async {
            expect(command, 'managed-drop-in-helper');
            return 'managed-helper-token';
          },
        );

        final headers = await generator.resolveHeaders();

        expect(headers['Authorization'], 'Bearer managed-helper-token');
      });
    });

    test('prefers Anthropic auth token over apiKeyHelper', () async {
      await File(pathFor(tempDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'print-helper-token',
        }),
      );

      var helperCalls = 0;
      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'ANTHROPIC_AUTH_TOKEN': 'external-auth-token',
        },
        useMacOsKeychain: false,
        runApiKeyHelper: (command, timeout) async {
          helperCalls += 1;
          return 'helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(helperCalls, 0);
      expect(headers['Authorization'], 'Bearer external-auth-token');
      expect(headers['anthropic-beta'], 'claude-code-20250219');
    });

    test('apiKeyHelper failure does not fall back to stored OAuth', () async {
      await _writeCredentials(tempDir, 'stored-token');
      await File(pathFor(tempDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'failing-helper',
        }),
      );

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        useMacOsKeychain: false,
        runApiKeyHelper: (command, timeout) async {
          throw StateError('exited 1');
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer  ');
      expect(headers['anthropic-beta'], 'claude-code-20250219');
    });

    test('matches Claude Code external env auth precedence', () async {
      await _writeCredentials(tempDir, 'stored-token');

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'ANTHROPIC_API_KEY': 'env-api-key',
          'ANTHROPIC_AUTH_TOKEN': 'external-auth-token',
          'CLAUDE_CODE_OAUTH_TOKEN': 'claude-code-oauth-token',
        },
        useMacOsKeychain: false,
      );

      final headers = await generator.resolveHeaders();

      expect(headers['x-api-key'], 'env-api-key');
      expect(headers['Authorization'], 'Bearer external-auth-token');
      expect(headers['anthropic-beta'], 'claude-code-20250219');
    });

    test('uses Claude Code OAuth file descriptor token', () async {
      final generator = ClaudeCodeDirectGenerator(
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR': '3',
        },
        useMacOsKeychain: false,
        readFileDescriptorCredential: (envVar, wellKnownPath) {
          if (envVar == 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR') return null;
          expect(envVar, 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR');
          expect(wellKnownPath, '/home/claude/.claude/remote/.oauth_token');
          return 'fd-oauth-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers, isNot(contains('x-api-key')));
      expect(headers['Authorization'], 'Bearer fd-oauth-token');
      expect(
        headers['anthropic-beta'],
        'claude-code-20250219,oauth-2025-04-20',
      );
    });

    test('uses Claude Code API key file descriptor before OAuth', () async {
      final generator = ClaudeCodeDirectGenerator(
        environment: const <String, String>{
          'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR': '4',
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth-token',
        },
        useMacOsKeychain: false,
        readFileDescriptorCredential: (envVar, wellKnownPath) {
          if (envVar == 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR') {
            expect(wellKnownPath, '/home/claude/.claude/remote/.api_key');
            return 'fd-api-key';
          }
          return null;
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['x-api-key'], 'fd-api-key');
      expect(headers, isNot(contains('Authorization')));
      expect(headers['anthropic-beta'], 'claude-code-20250219');
    });

    test('managed Claude context prefers Claude Code OAuth env token',
        () async {
      await File(pathFor(tempDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'print-helper-token',
        }),
      );
      var helperCalls = 0;
      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'CLAUDE_CODE_REMOTE': '1',
          'ANTHROPIC_API_KEY': 'external-api-key',
          'ANTHROPIC_AUTH_TOKEN': 'external-auth-token',
          'CLAUDE_CODE_OAUTH_TOKEN': 'claude-code-oauth-token',
        },
        useMacOsKeychain: false,
        runApiKeyHelper: (command, timeout) async {
          helperCalls += 1;
          return 'helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(helperCalls, 0);
      expect(headers, isNot(contains('x-api-key')));
      expect(headers['Authorization'], 'Bearer claude-code-oauth-token');
      expect(
        headers['anthropic-beta'],
        'claude-code-20250219,oauth-2025-04-20',
      );
    });

    test('bare Claude Code mode ignores stored OAuth credentials', () async {
      await _writeCredentials(tempDir, 'stored-token');

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'CLAUDE_CODE_SIMPLE': '1',
        },
        useMacOsKeychain: false,
      );

      await expectLater(
        generator.resolveHeaders(),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('bare Claude Code mode ignores file descriptor credentials', () async {
      final generator = ClaudeCodeDirectGenerator(
        environment: const <String, String>{
          'CLAUDE_CODE_SIMPLE': '1',
          'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR': '4',
          'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR': '5',
        },
        useMacOsKeychain: false,
        readFileDescriptorCredential: (envVar, wellKnownPath) {
          fail('bare mode should not read $envVar');
        },
      );

      await expectLater(
        generator.resolveHeaders(),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('uses Claude Code OAuth env token when no external auth is set',
        () async {
      final generator = ClaudeCodeDirectGenerator(
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN': 'claude-code-oauth-token',
        },
        useMacOsKeychain: false,
      );

      final headers = await generator.resolveHeaders();

      expect(headers, isNot(contains('x-api-key')));
      expect(headers['Authorization'], 'Bearer claude-code-oauth-token');
      expect(
        headers['anthropic-beta'],
        'claude-code-20250219,oauth-2025-04-20',
      );
    });

    test('runs Claude Code token setup when credentials are missing', () async {
      var loginCount = 0;
      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        useMacOsKeychain: false,
        runLogin: (executable, arguments) async {
          loginCount += 1;
          expect(executable, 'claude');
          expect(arguments, <String>['setup-token']);
          await _writeCredentials(tempDir, 'new-token');
          return 0;
        },
      );

      final headers = await generator.resolveHeaders();

      expect(loginCount, 1);
      expect(headers['Authorization'], 'Bearer new-token');
    });

    test('uses Claude Code streaming request shape', () async {
      Uri? endpoint;
      Map<String, String>? headers;
      Map<String, dynamic>? body;

      final generator = ClaudeCodeDirectGenerator(
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth-token',
        },
        useMacOsKeychain: false,
        streamMessages: (requestEndpoint, requestHeaders, requestBody) async {
          endpoint = requestEndpoint;
          headers = requestHeaders;
          body = requestBody;
          return <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': 'fix: Test direct Claude Code streaming',
            },
          ];
        },
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/a.txt b/a.txt',
        Language.english,
      );

      expect(message, 'fix: Test direct Claude Code streaming');
      expect(endpoint.toString(), 'https://api.anthropic.com/v1/messages');
      expect(headers?['Accept'], 'text/event-stream');
      expect(body?['stream'], isTrue);
      expect(
        body?['system'],
        "You are a Claude agent, built on Anthropic's Claude Agent SDK.",
      );
    });

    test('refreshes expired stored OAuth credentials before request', () async {
      await _writeCredentials(
        tempDir,
        'expired-token',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      Map<String, String>? headers;
      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        useMacOsKeychain: false,
        refreshToken: (endpoint, body) async {
          expect(
            endpoint.toString(),
            'https://platform.claude.com/v1/oauth/token',
          );
          expect(body['refresh_token'], 'refresh-token');
          expect(
            body['scope'],
            'user:profile user:inference user:sessions:claude_code '
            'user:mcp_servers user:file_upload',
          );
          return <String, dynamic>{
            'access_token': 'fresh-token',
            'refresh_token': 'fresh-refresh-token',
            'expires_in': 3600,
            'scope': 'user:profile user:inference',
          };
        },
        streamMessages: (requestEndpoint, requestHeaders, requestBody) async {
          headers = requestHeaders;
          return <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': 'fix: Refresh expired Claude Code OAuth token',
            },
          ];
        },
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/a.txt b/a.txt',
        Language.english,
      );

      expect(message, 'fix: Refresh expired Claude Code OAuth token');
      expect(headers?['Authorization'], 'Bearer fresh-token');

      final stored = await _readStoredOauth(tempDir);
      expect(stored['accessToken'], 'fresh-token');
      expect(stored['refreshToken'], 'fresh-refresh-token');
      expect(stored['scopes'], <String>['user:profile', 'user:inference']);
      expect(stored['expiresAt'], isA<int>());
    });

    test('uses staging Claude Code OAuth refresh endpoint and client id',
        () async {
      await _writeCredentials(
        tempDir,
        'expired-token',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'USER_TYPE': 'ant',
          'USE_STAGING_OAUTH': '1',
        },
        useMacOsKeychain: false,
        refreshToken: (endpoint, body) async {
          expect(
            endpoint.toString(),
            'https://platform.staging.ant.dev/v1/oauth/token',
          );
          expect(body['client_id'], '22422756-60c9-4084-8eb7-27705fd5cf9a');
          return <String, dynamic>{
            'access_token': 'staging-fresh-token',
            'refresh_token': 'staging-refresh-token',
            'expires_in': 3600,
            'scope': 'user:profile user:inference',
          };
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer staging-fresh-token');
    });

    test('tries stored OAuth token once when proactive refresh fails',
        () async {
      await _writeCredentials(
        tempDir,
        'expired-token',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      var refreshCount = 0;
      Map<String, String>? headers;
      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        useMacOsKeychain: false,
        refreshToken: (endpoint, body) async {
          refreshCount += 1;
          throw const AuthenticationException(
            message: 'Claude Code token refresh failed with status 400: '
                'invalid_grant. Run `claude setup-token`.',
            statusCode: 400,
          );
        },
        streamMessages: (requestEndpoint, requestHeaders, requestBody) async {
          headers = requestHeaders;
          return <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': 'fix: Try stored Claude Code token after refresh error',
            },
          ];
        },
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/a.txt b/a.txt',
        Language.english,
      );

      expect(message, 'fix: Try stored Claude Code token after refresh error');
      expect(refreshCount, 1);
      expect(headers?['Authorization'], 'Bearer expired-token');
    });

    test('refreshes and retries once after stored OAuth 401', () async {
      await _writeCredentials(
        tempDir,
        'stale-token',
      );

      var callCount = 0;
      final seenAuthorizations = <String?>[];
      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{},
        useMacOsKeychain: false,
        refreshToken: (endpoint, body) async {
          expect(
            endpoint.toString(),
            'https://platform.claude.com/v1/oauth/token',
          );
          expect(body['refresh_token'], 'refresh-token');
          expect(
            body['scope'],
            'user:profile user:inference user:sessions:claude_code '
            'user:mcp_servers user:file_upload',
          );
          return <String, dynamic>{
            'access_token': 'fresh-token',
            'refresh_token': 'fresh-refresh-token',
            'expires_in': 3600,
            'scope': 'user:profile user:inference',
          };
        },
        streamMessages: (requestEndpoint, requestHeaders, requestBody) async {
          callCount += 1;
          seenAuthorizations.add(requestHeaders['Authorization']);
          if (callCount == 1) {
            throw _unauthorized(requestEndpoint);
          }
          return <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': 'fix: Retry after Claude Code OAuth refresh',
            },
          ];
        },
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/a.txt b/a.txt',
        Language.english,
      );

      expect(message, 'fix: Retry after Claude Code OAuth refresh');
      expect(callCount, 2);
      expect(seenAuthorizations, <String>[
        'Bearer stale-token',
        'Bearer fresh-token',
      ]);
    });
  });
}

Future<void> _writeCredentials(
  Directory directory,
  String token, {
  String refreshToken = 'refresh-token',
  DateTime? expiresAt,
}) async {
  await File(pathFor(directory, '.credentials.json')).writeAsString(
    _credentialsJson(
      token,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    ),
  );
}

String _credentialsJson(
  String token, {
  String refreshToken = 'refresh-token',
  DateTime? expiresAt,
}) {
  return jsonEncode(<String, dynamic>{
    'claudeAiOauth': <String, dynamic>{
      'accessToken': token,
      'refreshToken': refreshToken,
      'expiresAt': (expiresAt ?? DateTime.now().add(const Duration(hours: 1)))
          .toUtc()
          .millisecondsSinceEpoch,
      'scopes': <String>['user:inference'],
    },
  });
}

String _hex(String value) {
  return utf8
      .encode(value)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

String _configDirHash(String value) {
  return crypto.sha256.convert(utf8.encode(value)).toString().substring(0, 8);
}

Future<Map<String, dynamic>> _readStoredOauth(Directory directory) async {
  final raw = await File(
    pathFor(directory, '.credentials.json'),
  ).readAsString();
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded['claudeAiOauth'] as Map<String, dynamic>;
}

Future<void> _withCurrentDirectory(
  Directory directory,
  Future<void> Function() callback,
) async {
  final previous = Directory.current;
  Directory.current = directory;
  try {
    await callback();
  } finally {
    Directory.current = previous;
  }
}

DioException _unauthorized(Uri endpoint) {
  final requestOptions = RequestOptions(path: endpoint.toString());
  return DioException(
    requestOptions: requestOptions,
    response: Response<dynamic>(
      requestOptions: requestOptions,
      statusCode: 401,
      data: <String, dynamic>{
        'type': 'error',
        'error': <String, dynamic>{
          'type': 'authentication_error',
          'message': 'Invalid authentication credentials',
        },
      },
    ),
  );
}

String pathFor(Directory directory, String fileName) {
  return '${directory.path}${Platform.pathSeparator}$fileName';
}

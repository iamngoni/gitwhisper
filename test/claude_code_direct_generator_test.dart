import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
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
        'oauth-2025-04-20,claude-code-20250219',
      );
      expect(headers, isNot(contains('x-api-key')));
    });

    test('prefers environment credentials over stored credentials', () async {
      await _writeCredentials(tempDir, 'stored-token');

      final generator = ClaudeCodeDirectGenerator(
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'ANTHROPIC_API_KEY': 'env-api-key',
          'CLAUDE_CODE_OAUTH_TOKEN': 'env-oauth-token',
        },
        useMacOsKeychain: false,
      );

      final headers = await generator.resolveHeaders();

      expect(headers['x-api-key'], 'env-api-key');
      expect(headers['Authorization'], 'Bearer env-oauth-token');
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
    jsonEncode(<String, dynamic>{
      'claudeAiOauth': <String, dynamic>{
        'accessToken': token,
        'refreshToken': refreshToken,
        'expiresAt': (expiresAt ?? DateTime.now().add(const Duration(hours: 1)))
            .toUtc()
            .millisecondsSinceEpoch,
        'scopes': <String>['user:inference'],
      },
    }),
  );
}

Future<Map<String, dynamic>> _readStoredOauth(Directory directory) async {
  final raw = await File(
    pathFor(directory, '.credentials.json'),
  ).readAsString();
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded['claudeAiOauth'] as Map<String, dynamic>;
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

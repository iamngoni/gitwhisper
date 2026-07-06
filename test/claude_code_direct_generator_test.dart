import 'dart:convert';
import 'dart:io';

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
  });
}

Future<void> _writeCredentials(Directory directory, String token) async {
  await File(pathFor(directory, '.credentials.json')).writeAsString(
    jsonEncode(<String, dynamic>{
      'claudeAiOauth': <String, dynamic>{
        'accessToken': token,
        'refreshToken': 'refresh-token',
        'expiresAt':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
        'scopes': <String>['user:inference'],
      },
    }),
  );
}

String pathFor(Directory directory, String fileName) {
  return '${directory.path}${Platform.pathSeparator}$fileName';
}

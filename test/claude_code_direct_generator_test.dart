import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/constants.dart';
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

      final generator = _sandboxedGenerator(
        tempDir,
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

      final generator = _sandboxedGenerator(
        tempDir,
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'ANTHROPIC_API_KEY': 'env-api-key',
          'ANTHROPIC_AUTH_TOKEN': 'env-auth-token',
        },
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
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

    test('ignores project apiKeyHelper settings in untrusted folders',
        () async {
      final userDir = Directory(pathFor(tempDir, 'user'))..createSync();
      final projectDir = await _writeProjectApiKeyHelpers(tempDir);
      await File(pathFor(userDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'user-helper',
        }),
      );

      final commands = <String>[];
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: userDir.path,
        projectDirectory: projectDir.path,
        runApiKeyHelper: (command, timeout) async {
          commands.add(command);
          return 'user-helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(commands, <String>['user-helper']);
      expect(headers['Authorization'], 'Bearer user-helper-token');
    });

    test('never runs an untrusted project apiKeyHelper', () async {
      final userDir = Directory(pathFor(tempDir, 'user'))..createSync();
      await _writeCredentials(userDir, 'stored-token');
      final projectDir = await _writeProjectApiKeyHelpers(tempDir);
      // Trust for a parent folder or another project does not count.
      await _writeClaudeTrust(
        File(pathFor(userDir, '.claude.json')),
        <String>[tempDir.path, pathFor(tempDir, 'other-project')],
      );

      var helperCalls = 0;
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: userDir.path,
        projectDirectory: projectDir.path,
        runApiKeyHelper: (command, timeout) async {
          helperCalls += 1;
          return 'project-helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(helperCalls, 0);
      expect(headers['Authorization'], 'Bearer stored-token');
    });

    test('uses local apiKeyHelper over project and user settings when trusted',
        () async {
      final userDir = Directory(pathFor(tempDir, 'user'))..createSync();
      final projectDir = await _writeProjectApiKeyHelpers(tempDir);
      await File(pathFor(userDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'user-helper',
        }),
      );
      await _writeClaudeTrust(
        File(pathFor(userDir, '.claude.json')),
        <String>[projectDir.path],
      );

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: userDir.path,
        projectDirectory: projectDir.path,
        runApiKeyHelper: (command, timeout) async {
          expect(command, 'local-helper');
          return 'local-helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer local-helper-token');
    });

    test('reads project trust from the home Claude Code config', () async {
      final home = Directory(pathFor(tempDir, 'trusted-home'))..createSync();
      final projectDir = await _writeProjectApiKeyHelpers(tempDir);
      await _writeClaudeTrust(
        File(pathFor(home, '.claude.json')),
        <String>[projectDir.resolveSymbolicLinksSync()],
      );

      final generator = _sandboxedGenerator(
        tempDir,
        projectDirectory: projectDir.path,
        environment: <String, String>{'HOME': home.path},
        runApiKeyHelper: (command, timeout) async {
          expect(command, 'local-helper');
          return 'local-helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer local-helper-token');
    });

    test('reads project trust from CLAUDE_CONFIG_DIR config', () async {
      final configDir = Directory(pathFor(tempDir, 'config'))..createSync();
      final home = Directory(pathFor(tempDir, 'untrusted-home'))..createSync();
      final projectDir = await _writeProjectApiKeyHelpers(tempDir);
      await _writeClaudeTrust(
        File(pathFor(configDir, '.claude.json')),
        <String>[projectDir.path],
      );
      await _writeClaudeTrust(File(pathFor(home, '.claude.json')), <String>[]);

      final generator = _sandboxedGenerator(
        tempDir,
        projectDirectory: projectDir.path,
        environment: <String, String>{
          'HOME': home.path,
          'CLAUDE_CONFIG_DIR': configDir.path,
        },
        runApiKeyHelper: (command, timeout) async {
          expect(command, 'local-helper');
          return 'local-helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer local-helper-token');
    });

    test('uses USERPROFILE when HOME is not set', () async {
      final profile = Directory(pathFor(tempDir, 'profile'))..createSync();
      final claudeDir = Directory(pathFor(profile, '.claude'))..createSync();
      await _writeCredentials(claudeDir, 'profile-token');

      final generator = _sandboxedGenerator(
        tempDir,
        environment: <String, String>{
          'HOME': '',
          'USERPROFILE': profile.path,
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer profile-token');
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: userDir.path,
        projectDirectory: projectDir.path,
        managedSettingsPath: managedDir.path,
        runApiKeyHelper: (command, timeout) async {
          expect(command, 'managed-drop-in-helper');
          return 'managed-helper-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer managed-helper-token');
    });

    test('reads managed settings path override for internal users', () async {
      final managedDir = Directory(pathFor(tempDir, 'ant-managed'))
        ..createSync();
      await File(pathFor(managedDir, 'managed-settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'managed-env-helper',
        }),
      );

      final generator = _sandboxedGenerator(
        tempDir,
        useEnvironmentManagedSettingsPath: true,
        environment: <String, String>{
          'USER_TYPE': 'ant',
          'CLAUDE_CODE_MANAGED_SETTINGS_PATH': managedDir.path,
        },
        runApiKeyHelper: (command, timeout) async {
          expect(command, 'managed-env-helper');
          return 'managed-env-token';
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer managed-env-token');
    });

    test('prefers Anthropic auth token over apiKeyHelper', () async {
      await File(pathFor(tempDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'print-helper-token',
        }),
      );

      var helperCalls = 0;
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'ANTHROPIC_AUTH_TOKEN': 'external-auth-token',
        },
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'ANTHROPIC_API_KEY': 'env-api-key',
          'ANTHROPIC_AUTH_TOKEN': 'external-auth-token',
          'CLAUDE_CODE_OAUTH_TOKEN': 'claude-code-oauth-token',
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['x-api-key'], 'env-api-key');
      expect(headers['Authorization'], 'Bearer external-auth-token');
      expect(headers['anthropic-beta'], 'claude-code-20250219');
    });

    test('uses Claude Code OAuth file descriptor token', () async {
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR': '3',
        },
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
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR': '4',
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth-token',
        },
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

    test('ignores remote credential files outside Claude Code remote',
        () async {
      await _writeCredentials(tempDir, 'stored-token');

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        readFileDescriptorCredential: (envVar, wellKnownPath) {
          fail('should not read $wellKnownPath outside a remote session');
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer stored-token');
    });

    test('reads remote credential files in Claude Code remote sessions',
        () async {
      await _writeCredentials(tempDir, 'stored-token');
      final readPaths = <String>[];

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{'CLAUDE_CODE_REMOTE': 'true'},
        readFileDescriptorCredential: (envVar, wellKnownPath) {
          readPaths.add(wellKnownPath);
          if (envVar == 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR') {
            return 'remote-oauth-token';
          }
          return null;
        },
      );

      final headers = await generator.resolveHeaders();

      expect(readPaths, <String>[
        '/home/claude/.claude/remote/.api_key',
        '/home/claude/.claude/remote/.oauth_token',
      ]);
      expect(headers['Authorization'], 'Bearer remote-oauth-token');
    });

    test('managed Claude context prefers Claude Code OAuth env token',
        () async {
      await File(pathFor(tempDir, 'settings.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'apiKeyHelper': 'print-helper-token',
        }),
      );
      var helperCalls = 0;
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'CLAUDE_CODE_REMOTE': '1',
          'ANTHROPIC_API_KEY': 'external-api-key',
          'ANTHROPIC_AUTH_TOKEN': 'external-auth-token',
          'CLAUDE_CODE_OAUTH_TOKEN': 'claude-code-oauth-token',
        },
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'CLAUDE_CODE_SIMPLE': '1',
        },
      );

      await expectLater(
        generator.resolveHeaders(),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('bare Claude Code mode ignores file descriptor credentials', () async {
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_SIMPLE': '1',
          'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR': '4',
          'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR': '5',
        },
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
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN': 'claude-code-oauth-token',
        },
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
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth-token',
        },
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

    test('lets the model choose tools, then disables them at the budget',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final executedTools = <String>[];
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth-token',
        },
        streamMessages: (endpoint, headers, body) async {
          bodies.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
          if (bodies.length == 1) {
            return <Map<String, dynamic>>[
              _toolUse('call_1', 'first_tool'),
              _toolUse('call_2', 'second_tool'),
            ];
          }
          return <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'fix: Finish in budget'},
          ];
        },
      );

      final message = await generator.generateAgentCommitMessage(
        AgentCommitRequest(
          tools: GitAgentTools(
            folderPath: tempDir.path,
            onToolUse: (toolUse) => executedTools.add(toolUse.name),
          ),
          language: Language.english,
          maxToolCalls: 1,
        ),
      );

      expect(message, 'fix: Finish in budget');
      expect(
        bodies.map((body) => body['tool_choice']),
        <Object>[
          <String, dynamic>{'type': 'auto'},
          <String, dynamic>{'type': 'none'},
        ],
      );
      expect(bodies.last['tools'], isNotEmpty);
      expect(executedTools, <String>['first_tool']);

      final messages = bodies.last['messages'] as List<dynamic>;
      final toolResults = (messages.last as Map)['content'] as List<dynamic>;
      expect(toolResults, hasLength(3));
      expect(
        (toolResults[1] as Map)['content'],
        contains('limit of 1 tool calls was reached'),
      );
      expect(
        (toolResults[2] as Map)['text'],
        contains('You have used all available tool calls'),
      );
    });

    test('rejects Claude responses cut off at max_tokens', () async {
      final interceptor = _claudeSseInterceptor(
        text: 'fix: Cut off mid',
        stopReason: 'max_tokens',
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth-token',
        },
        useHttpTransport: true,
      );

      await expectLater(
        generator.generateCommitMessage(
          'diff --git a/a.txt b/a.txt',
          Language.english,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('max_tokens'),
          ),
        ),
      );
    });

    test('accepts streamed Claude responses that end normally', () async {
      final interceptor = _claudeSseInterceptor(
        text: 'fix: Stream a complete message',
        stopReason: 'end_turn',
      );
      $dio.interceptors.add(interceptor);
      addTearDown(() => $dio.interceptors.remove(interceptor));

      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth-token',
        },
        useHttpTransport: true,
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/a.txt b/a.txt',
        Language.english,
      );

      expect(message, 'fix: Stream a complete message');
    });

    test('refreshes expired stored OAuth credentials before request', () async {
      await _writeCredentials(
        tempDir,
        'expired-token',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      Map<String, String>? headers;
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        environment: const <String, String>{
          'USER_TYPE': 'ant',
          'USE_STAGING_OAUTH': '1',
        },
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
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
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

    test(
      'saves refreshed credentials atomically with owner-only permissions',
      () async {
        await _writeCredentials(
          tempDir,
          'expired-token',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        );

        final generator = _sandboxedGenerator(
          tempDir,
          claudeConfigDir: tempDir.path,
          refreshToken: (endpoint, body) async => _refreshResponse(),
        );

        await generator.resolveHeaders();

        final credentialsFile = File(pathFor(tempDir, '.credentials.json'));
        expect(_permissionBits(credentialsFile), 0x180);
        expect(
          tempDir
              .listSync()
              .map((entity) => entity.path)
              .where((name) => name.endsWith('.tmp')),
          isEmpty,
        );
        expect((await _readStoredOauth(tempDir))['accessToken'], 'fresh-token');
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );

    test('merges refreshed tokens into the latest stored credentials',
        () async {
      await File(pathFor(tempDir, '.credentials.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'claudeAiOauth': <String, dynamic>{
            'accessToken': 'expired-token',
            'refreshToken': 'refresh-token',
            'expiresAt': DateTime.now()
                .subtract(const Duration(minutes: 1))
                .millisecondsSinceEpoch,
            'scopes': <String>['user:inference'],
            'organizationUuid': 'org-1',
          },
          'mcpOAuth': <String, dynamic>{'server': 'snapshot'},
        }),
      );

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        refreshToken: (endpoint, body) async {
          // Claude Code updates another entry while the refresh is running.
          final file = File(pathFor(tempDir, '.credentials.json'));
          final root = jsonDecode(file.readAsStringSync()) as Map;
          root['mcpOAuth'] = <String, dynamic>{'server': 'updated'};
          file.writeAsStringSync(jsonEncode(root));
          return _refreshResponse();
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer fresh-token');
      final root = jsonDecode(
        File(pathFor(tempDir, '.credentials.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(root['mcpOAuth'], <String, dynamic>{'server': 'updated'});
      final oauth = root['claudeAiOauth'] as Map<String, dynamic>;
      expect(oauth['accessToken'], 'fresh-token');
      expect(oauth['refreshToken'], 'fresh-refresh-token');
      expect(oauth['organizationUuid'], 'org-1');
    });

    test('keeps tokens Claude Code saved while a refresh was running',
        () async {
      await _writeCredentials(
        tempDir,
        'expired-token',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        refreshToken: (endpoint, body) async {
          await _writeCredentials(
            tempDir,
            'claude-code-token',
            refreshToken: 'claude-code-refresh-token',
          );
          return _refreshResponse();
        },
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer claude-code-token');
      final stored = await _readStoredOauth(tempDir);
      expect(stored['accessToken'], 'claude-code-token');
      expect(stored['refreshToken'], 'claude-code-refresh-token');
    });

    test('waits for another gitwhisper refresh and adopts its tokens',
        () async {
      await _writeCredentials(
        tempDir,
        'expired-token',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final lockHolder = await _startLockHolder(
        tempDir,
        File(pathFor(tempDir, '.gitwhisper-oauth-refresh.lock')),
      );
      addTearDown(lockHolder.kill);

      var refreshCalls = 0;
      final generator = _sandboxedGenerator(
        tempDir,
        claudeConfigDir: tempDir.path,
        refreshToken: (endpoint, body) async {
          refreshCalls += 1;
          return _refreshResponse();
        },
      );

      final headersFuture = generator.resolveHeaders();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(refreshCalls, 0, reason: 'refresh must wait for the lock');

      // The other process finishes its refresh, saves, and unlocks.
      await _writeCredentials(
        tempDir,
        'other-process-token',
        refreshToken: 'other-process-refresh-token',
      );
      await lockHolder.stdin.close();
      await lockHolder.exitCode;

      final headers = await headersFuture;

      expect(headers['Authorization'], 'Bearer other-process-token');
      expect(refreshCalls, 0);
    });

    test('keeps refreshed tokens in memory when the keychain save fails',
        () async {
      var refreshCalls = 0;
      final generator = _sandboxedGenerator(
        tempDir,
        readMacOsKeychainService: (service) async => _credentialsJson(
          'expired-token',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        writeMacOsKeychainService: (service, value) async {
          throw StateError('keychain is locked');
        },
        refreshToken: (endpoint, body) async {
          refreshCalls += 1;
          return _refreshResponse();
        },
      );

      final first = await generator.resolveHeaders();
      final second = await generator.resolveHeaders();

      expect(first['Authorization'], 'Bearer fresh-token');
      expect(second['Authorization'], 'Bearer fresh-token');
      expect(refreshCalls, 1);
    });

    test('passes keychain credentials to security on stdin, not argv',
        () async {
      final calls = <({List<String> arguments, String? stdin})>[];
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{'USER': 'gw-test'},
        readMacOsKeychainService: (service) async => _credentialsJson(
          'expired-token',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        runSecurityCommand: (arguments, {stdin}) async {
          calls.add((arguments: arguments, stdin: stdin));
          return 0;
        },
        refreshToken: (endpoint, body) async => _refreshResponse(),
      );

      final headers = await generator.resolveHeaders();

      expect(headers['Authorization'], 'Bearer fresh-token');
      expect(calls, hasLength(1));
      expect(calls.single.arguments, <String>['-i']);
      final command = calls.single.stdin!;
      expect(
        command,
        startsWith(
          'add-generic-password -U -a "gw-test" '
          '-s "Claude Code-credentials" -X "',
        ),
      );
      expect(command, endsWith('"\n'));
      final hexValue =
          RegExp('-X "([0-9a-f]+)"').firstMatch(command)!.group(1)!;
      expect(_unhex(hexValue), contains('fresh-refresh-token'));
    });

    test('falls back to argv for keychain payloads too long for stdin',
        () async {
      final calls = <({List<String> arguments, String? stdin})>[];
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{'USER': 'gw-test'},
        readMacOsKeychainService: (service) async => jsonEncode(
          <String, dynamic>{
            ...jsonDecode(
              _credentialsJson(
                'expired-token',
                expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
              ),
            ) as Map<String, dynamic>,
            'mcpOAuth': <String, dynamic>{'padding': 'x' * 3000},
          },
        ),
        runSecurityCommand: (arguments, {stdin}) async {
          calls.add((arguments: arguments, stdin: stdin));
          return 0;
        },
        refreshToken: (endpoint, body) async => _refreshResponse(),
      );

      await generator.resolveHeaders();

      expect(calls, hasLength(1));
      expect(calls.single.stdin, isNull);
      expect(
        calls.single.arguments.take(7),
        <String>[
          'add-generic-password',
          '-U',
          '-a',
          'gw-test',
          '-s',
          'Claude Code-credentials',
          '-X',
        ],
      );
    });

    test('treats a failed security write as a failed save', () async {
      var refreshCalls = 0;
      final generator = _sandboxedGenerator(
        tempDir,
        environment: const <String, String>{'USER': 'gw-test'},
        readMacOsKeychainService: (service) async => _credentialsJson(
          'expired-token',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        runSecurityCommand: (arguments, {stdin}) async => 45,
        refreshToken: (endpoint, body) async {
          refreshCalls += 1;
          return _refreshResponse();
        },
      );

      final first = await generator.resolveHeaders();
      final second = await generator.resolveHeaders();

      expect(first['Authorization'], 'Bearer fresh-token');
      expect(second['Authorization'], 'Bearer fresh-token');
      expect(refreshCalls, 1);
    });

    test(
      'writes a private recovery copy when saving the credentials file fails',
      () async {
        final lockedDir = Directory(pathFor(tempDir, 'locked'))..createSync();
        final target = File(pathFor(lockedDir, 'credentials.json'))
          ..writeAsStringSync(
            _credentialsJson(
              'expired-token',
              expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
            ),
          );
        Link(pathFor(tempDir, '.credentials.json')).createSync(target.path);
        Process.runSync('chmod', <String>['555', lockedDir.path]);
        addTearDown(
          () => Process.runSync('chmod', <String>['755', lockedDir.path]),
        );
        try {
          File(pathFor(lockedDir, 'probe')).createSync();
          markTestSkipped('Directory permissions are not enforced (root?).');
          return;
        } on FileSystemException {
          // Expected: the credentials directory is read-only.
        }

        var refreshCalls = 0;
        final generator = _sandboxedGenerator(
          tempDir,
          claudeConfigDir: tempDir.path,
          refreshToken: (endpoint, body) async {
            refreshCalls += 1;
            return _refreshResponse();
          },
        );

        final first = await generator.resolveHeaders();
        final second = await generator.resolveHeaders();

        expect(first['Authorization'], 'Bearer fresh-token');
        expect(second['Authorization'], 'Bearer fresh-token');
        expect(refreshCalls, 1);
        expect(target.readAsStringSync(), contains('expired-token'));

        final recovery = File(
          pathFor(tempDir, '.credentials.json.gitwhisper-recovery'),
        );
        expect(_permissionBits(recovery), 0x180);
        final recovered = jsonDecode(recovery.readAsStringSync()) as Map;
        expect(
          (recovered['claudeAiOauth'] as Map)['refreshToken'],
          'fresh-refresh-token',
        );
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );
  });

  group(
    'ClaudeCodeDirectGenerator.defaultApiKeyHelperRunner',
    () {
      late Directory tempDir;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('gw-claude-helper-');
      });

      tearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      test('returns trimmed helper output', () async {
        final value = await ClaudeCodeDirectGenerator.defaultApiKeyHelperRunner(
          r"printf '  helper-token  \n'",
          const Duration(seconds: 10),
        );

        expect(value, 'helper-token');
      });

      test('kills a hung helper and its child processes on timeout', () async {
        final shellPidFile = File(pathFor(tempDir, 'shell.pid'));
        final childPidFile = File(pathFor(tempDir, 'child.pid'));
        final command = 'echo \$\$ > "${shellPidFile.path}"; '
            'sleep 30 & echo \$! > "${childPidFile.path}"; wait';

        await expectLater(
          ClaudeCodeDirectGenerator.defaultApiKeyHelperRunner(
            command,
            const Duration(seconds: 1),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              startsWith('timed out'),
            ),
          ),
        );

        for (final pidFile in <File>[shellPidFile, childPidFile]) {
          final pid = int.parse(pidFile.readAsStringSync().trim());
          expect(
            await _waitForProcessExit(pid),
            isTrue,
            reason: 'helper process $pid was still running',
          );
        }
      });

      test('reports the exit code with a short sanitized stderr note',
          () async {
        const command =
            r"printf '\033[31mhelper failed: %0200d\nsecond line\n' 0"
            ' >&2; exit 3';

        await expectLater(
          ClaudeCodeDirectGenerator.defaultApiKeyHelperRunner(
            command,
            const Duration(seconds: 10),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(
                startsWith('exited with code 3 ('),
                contains('helper failed: 000'),
                isNot(contains('\x1B')),
                isNot(contains('second line')),
                hasLength(lessThan(110)),
              ),
            ),
          ),
        );
      });
    },
    skip: Platform.isWindows ? 'Uses /bin/sh helpers.' : false,
  );
}

Map<String, dynamic> _toolUse(String id, String name) {
  return <String, dynamic>{
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': <String, dynamic>{},
  };
}

/// Answers Claude Messages requests with a streamed text block that stops
/// with [stopReason].
InterceptorsWrapper _claudeSseInterceptor({
  required String text,
  required String stopReason,
}) {
  String event(String name, Map<String, dynamic> data) {
    return 'event: $name\ndata: ${jsonEncode(data)}\n\n';
  }

  final body = [
    event('message_start', <String, dynamic>{
      'type': 'message_start',
      'message': <String, dynamic>{'id': 'msg_1', 'content': <Object>[]},
    }),
    event('content_block_start', <String, dynamic>{
      'type': 'content_block_start',
      'index': 0,
      'content_block': <String, dynamic>{'type': 'text', 'text': ''},
    }),
    event('content_block_delta', <String, dynamic>{
      'type': 'content_block_delta',
      'index': 0,
      'delta': <String, dynamic>{'type': 'text_delta', 'text': text},
    }),
    event('content_block_stop', <String, dynamic>{
      'type': 'content_block_stop',
      'index': 0,
    }),
    event('message_delta', <String, dynamic>{
      'type': 'message_delta',
      'delta': <String, dynamic>{'stop_reason': stopReason},
    }),
    event('message_stop', <String, dynamic>{'type': 'message_stop'}),
  ].join();

  return InterceptorsWrapper(
    onRequest: (options, handler) {
      handler.resolve(
        Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody.fromString(body, 200),
        ),
      );
    },
  );
}

Map<String, dynamic> _refreshResponse() {
  return <String, dynamic>{
    'access_token': 'fresh-token',
    'refresh_token': 'fresh-refresh-token',
    'expires_in': 3600,
    'scope': 'user:profile user:inference',
  };
}

int _permissionBits(File file) => file.statSync().mode & 0x1FF;

/// Starts a separate Dart process that holds [lockFile] until its stdin is
/// closed, standing in for another gitwhisper process mid-refresh.
Future<Process> _startLockHolder(Directory sandbox, File lockFile) async {
  final script = File(pathFor(sandbox, 'hold_lock.dart'))..writeAsStringSync('''
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

/// Polls until [pid] no longer accepts signals. SIGCONT is harmless to a
/// running process, so it is used as a liveness probe.
Future<bool> _waitForProcessExit(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (!Process.killPid(pid, ProcessSignal.sigcont)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
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

/// Creates `<sandbox>/project` with a shared and a local apiKeyHelper, as a
/// cloned repository could.
Future<Directory> _writeProjectApiKeyHelpers(Directory sandbox) async {
  final projectDir = Directory(pathFor(sandbox, 'project'))..createSync();
  final claudeDir = Directory(pathFor(projectDir, '.claude'))..createSync();
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
  return projectDir;
}

/// Writes a Claude Code global config that trusts [trustedDirectories].
Future<void> _writeClaudeTrust(
  File configFile,
  List<String> trustedDirectories,
) async {
  await configFile.writeAsString(
    jsonEncode(<String, dynamic>{
      'projects': <String, dynamic>{
        for (final directory in trustedDirectories)
          directory: <String, dynamic>{'hasTrustDialogAccepted': true},
      },
    }),
  );
}

String _hex(String value) {
  return utf8
      .encode(value)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

String _unhex(String value) {
  return utf8.decode(<int>[
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
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

/// Creates a generator that cannot touch the developer's real environment.
///
/// HOME points inside [sandbox], project and managed settings are read from
/// [sandbox], and the keychain, apiKeyHelper, login, token refresh, file
/// descriptor and network hooks are fakes unless a test passes its own. The
/// default fakes throw, so an unexpected call fails loudly instead of running
/// `security`, a shell command, or a real request.
ClaudeCodeDirectGenerator _sandboxedGenerator(
  Directory sandbox, {
  String? claudeConfigDir,
  String? projectDirectory,
  String? managedSettingsPath,
  bool useEnvironmentManagedSettingsPath = false,
  Map<String, String> environment = const <String, String>{},
  bool? useMacOsKeychain,
  ClaudeCodeKeychainReader? readMacOsKeychainService,
  ClaudeCodeKeychainWriter? writeMacOsKeychainService,
  ClaudeCodeSecurityCommandRunner? runSecurityCommand,
  ClaudeCodeFileDescriptorCredentialReader? readFileDescriptorCredential,
  ClaudeCodeApiKeyHelperRunner? runApiKeyHelper,
  ClaudeCodeLoginRunner? runLogin,
  ClaudeCodeMessagesStreamer? streamMessages,
  bool useHttpTransport = false,
  ClaudeCodeTokenRefresher? refreshToken,
}) {
  return ClaudeCodeDirectGenerator(
    claudeConfigDir: claudeConfigDir,
    projectDirectory: projectDirectory ?? pathFor(sandbox, 'project'),
    managedSettingsPath: useEnvironmentManagedSettingsPath
        ? null
        : managedSettingsPath ?? pathFor(sandbox, 'managed'),
    environment: <String, String>{
      'HOME': pathFor(sandbox, 'home'),
      ...environment,
    },
    useMacOsKeychain: useMacOsKeychain ?? readMacOsKeychainService != null,
    readMacOsKeychainService:
        readMacOsKeychainService ?? (service) async => null,
    // A test that injects a `security` runner exercises the real keychain
    // write logic against that fake instead of a fake writer.
    writeMacOsKeychainService: writeMacOsKeychainService ??
        (runSecurityCommand != null
            ? null
            : (service, value) async {
                throw StateError('Keychain writes are disabled in tests.');
              }),
    runSecurityCommand: runSecurityCommand ??
        (arguments, {stdin}) async {
          throw StateError('The security command is disabled in tests.');
        },
    readFileDescriptorCredential:
        readFileDescriptorCredential ?? (envVar, wellKnownPath) => null,
    runApiKeyHelper: runApiKeyHelper ??
        (command, timeout) async {
          throw StateError('apiKeyHelper processes are disabled in tests.');
        },
    runLogin: runLogin ??
        (executable, arguments) async {
          throw StateError('Login processes are disabled in tests.');
        },
    // With useHttpTransport the real streaming client runs; the test must
    // answer every request with a $dio interceptor.
    streamMessages: streamMessages ??
        (useHttpTransport
            ? null
            : (endpoint, headers, body) async {
                throw StateError('Network requests are disabled in tests.');
              }),
    refreshToken: refreshToken ??
        (endpoint, body) async {
          throw StateError('Token refresh requests are disabled in tests.');
        },
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import '../agent/agent_commit_generator.dart';
import '../agent/git_agent_tools.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'claude_generator.dart';
import 'language.dart';
import 'model_variants.dart';

typedef ClaudeCodeLoginRunner = Future<int> Function(
  String executable,
  List<String> arguments,
);

typedef ClaudeCodeMessagesStreamer = Future<List<Map<String, dynamic>>>
    Function(
  Uri endpoint,
  Map<String, String> headers,
  Map<String, dynamic> body,
);

typedef ClaudeCodeTokenRefresher = Future<Map<String, dynamic>> Function(
  Uri endpoint,
  Map<String, dynamic> body,
);

typedef ClaudeCodeKeychainReader = Future<String?> Function(String service);

typedef ClaudeCodeKeychainWriter = Future<void> Function(
  String service,
  String value,
);

typedef ClaudeCodeFileDescriptorCredentialReader = String? Function(
  String envVar,
  String wellKnownPath,
);

typedef ClaudeCodeApiKeyHelperRunner = Future<String> Function(
  String command,
  Duration timeout,
);

class ClaudeCodeDirectGenerator extends ClaudeGenerator {
  ClaudeCodeDirectGenerator({
    String? apiKey,
    String? variant,
    String? baseUrl,
    String? claudeConfigDir,
    String? projectDirectory,
    String? managedSettingsPath,
    Map<String, String>? environment,
    ClaudeCodeLoginRunner? runLogin,
    ClaudeCodeMessagesStreamer? streamMessages,
    ClaudeCodeTokenRefresher? refreshToken,
    ClaudeCodeKeychainReader? readMacOsKeychainService,
    ClaudeCodeKeychainWriter? writeMacOsKeychainService,
    ClaudeCodeFileDescriptorCredentialReader? readFileDescriptorCredential,
    ClaudeCodeApiKeyHelperRunner? runApiKeyHelper,
    Duration? apiKeyHelperTimeout,
    this.loginExecutable = 'claude',
    this.loginArguments = const <String>['setup-token'],
    this.useMacOsKeychain = true,
  })  : _explicitApiKey = apiKey,
        _claudeConfigDir = claudeConfigDir,
        _projectDirectory = projectDirectory,
        _managedSettingsPathOverride = managedSettingsPath,
        _environment = environment,
        _runLogin = runLogin ?? _defaultRunLogin,
        _streamMessages = streamMessages,
        _refreshToken = refreshToken,
        _readMacOsKeychain = readMacOsKeychainService,
        _writeMacOsKeychain = writeMacOsKeychainService,
        _readFileDescriptorCredential = readFileDescriptorCredential,
        _runApiKeyHelper = runApiKeyHelper ?? _defaultRunApiKeyHelper,
        _apiKeyHelperTimeout =
            apiKeyHelperTimeout ?? _defaultApiKeyHelperTimeout,
        super(
          apiKey,
          variant: variant,
          baseUrl: baseUrl ??
              (environment ?? Platform.environment)['ANTHROPIC_BASE_URL'],
        );

  /// Runs an apiKeyHelper command with the platform shell. Used when no
  /// runner is injected.
  static const ClaudeCodeApiKeyHelperRunner defaultApiKeyHelperRunner =
      _defaultRunApiKeyHelper;

  static const String _systemPrompt =
      "You are a Claude agent, built on Anthropic's Claude Agent SDK.";
  static const String _prodOAuthClientId =
      '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const String _nonProdOAuthClientId =
      '22422756-60c9-4084-8eb7-27705fd5cf9a';
  static const Duration _refreshBuffer = Duration(minutes: 5);
  static const Duration _apiKeyHelperDefaultTtl = Duration(minutes: 5);
  static const Duration _defaultApiKeyHelperTimeout = Duration(minutes: 10);
  static const int _helperStderrNoteLength = 80;
  static const Duration _credentialLockTimeout = Duration(seconds: 30);
  static const String _credentialLockFileName =
      '.gitwhisper-oauth-refresh.lock';
  static const String _credentialRecoverySuffix = '.gitwhisper-recovery';
  static const String _claudeAiInferenceScope = 'user:inference';
  static const String _ccrOAuthTokenPath =
      '/home/claude/.claude/remote/.oauth_token';
  static const String _ccrApiKeyPath = '/home/claude/.claude/remote/.api_key';
  static const Set<String> _allowedCustomOAuthBaseUrls = <String>{
    'https://beacon.claude-ai.staging.ant.dev',
    'https://claude.fedstart.com',
    'https://claude-staging.fedstart.com',
  };
  static const List<String> _defaultOAuthScopes = <String>[
    'user:profile',
    _claudeAiInferenceScope,
    'user:sessions:claude_code',
    'user:mcp_servers',
    'user:file_upload',
  ];

  final String? _explicitApiKey;
  final String? _claudeConfigDir;

  /// Directory whose `.claude/settings*.json` are the project settings.
  /// Defaults to the current working directory.
  final String? _projectDirectory;

  /// Directory holding `managed-settings.json` and `managed-settings.d`.
  /// Defaults to the platform's Claude Code managed settings location.
  final String? _managedSettingsPathOverride;
  final Map<String, String>? _environment;
  final ClaudeCodeLoginRunner _runLogin;
  final ClaudeCodeMessagesStreamer? _streamMessages;
  final ClaudeCodeTokenRefresher? _refreshToken;
  final ClaudeCodeKeychainReader? _readMacOsKeychain;
  final ClaudeCodeKeychainWriter? _writeMacOsKeychain;
  final ClaudeCodeFileDescriptorCredentialReader? _readFileDescriptorCredential;
  final ClaudeCodeApiKeyHelperRunner _runApiKeyHelper;
  final Duration _apiKeyHelperTimeout;
  final String loginExecutable;
  final List<String> loginArguments;
  final bool useMacOsKeychain;
  final Map<String, String?> _fileDescriptorCredentialCache =
      <String, String?>{};
  _ClaudeCodeApiKeyHelperCache? _apiKeyHelperCache;
  bool _warnedAboutUntrustedProjectSettings = false;
  ({
    String? replacedRefreshToken,
    _ClaudeCodeOAuthCredentials credentials,
  })? _unsavedOAuthCredentials;

  Map<String, String> get _env => _environment ?? Platform.environment;

  @override
  String get modelName => 'claude-code';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  Future<Map<String, String>> resolveHeaders() async {
    final auth = await _loadAuth();
    return _headersForAuth(auth);
  }

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) async {
    final content = await _postStreamingMessages(
      <String, dynamic>{
        'model': actualVariant,
        'max_tokens': maxTokens,
        'stream': true,
        'system': _systemPrompt,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': getCommitPrompt(
              diff,
              language,
              prefix: prefix,
              withEmoji: withEmoji,
            ),
          },
        ],
      },
    );

    return _extractClaudeText(content).trim();
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final content = await _postStreamingMessages(
      <String, dynamic>{
        'model': actualVariant,
        'max_tokens': maxAnalysisTokens,
        'stream': true,
        'system': _systemPrompt,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': getAnalysisPrompt(diff, language),
          },
        ],
      },
    );

    return _extractClaudeText(content).trim();
  }

  @override
  Future<String> generateAgentCommitMessage(
    AgentCommitRequest request,
  ) async {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': getAgentCommitPrompt(
          request.language,
          prefix: request.prefix,
          withEmoji: request.withEmoji,
          additionalContext: request.additionalContext,
        ),
      },
    ];

    var toolCallCount = 0;

    while (true) {
      final content = await _postStreamingMessages(
        <String, dynamic>{
          'model': actualVariant,
          'max_tokens': 1000,
          'stream': true,
          'system': _systemPrompt,
          'messages': messages,
          'tools': GitAgentTools.claudeToolDefinitions,
          if (messages.length == 1)
            'tool_choice': <String, dynamic>{'type': 'any'},
        },
      );

      final toolUses = _extractClaudeToolUses(content);
      if (toolUses.isEmpty) {
        return _extractClaudeText(content).trim();
      }

      toolCallCount += toolUses.length;
      if (toolCallCount > request.maxToolCalls) {
        throw StateError(
          'Agent mode exceeded ${request.maxToolCalls} tool calls.',
        );
      }

      messages.add(<String, dynamic>{
        'role': 'assistant',
        'content': content,
      });

      final toolResults = <Map<String, dynamic>>[];
      for (final toolUse in toolUses) {
        toolResults.add(
          await _executeClaudeToolUse(request.tools, toolUse),
        );
      }

      messages.add(<String, dynamic>{
        'role': 'user',
        'content': toolResults,
      });
    }
  }

  Future<List<Map<String, dynamic>>> _postStreamingMessages(
    Map<String, dynamic> body,
  ) async {
    var auth = await _loadAuth();
    var retriedAfterUnauthorized = false;

    while (true) {
      try {
        return await _sendStreamingMessages(auth, body);
      } on DioException catch (error) {
        if (!retriedAfterUnauthorized && error.response?.statusCode == 401) {
          final refreshedAuth = await _recoverFromUnauthorized(auth);
          if (refreshedAuth != null) {
            auth = refreshedAuth;
            retriedAfterUnauthorized = true;
            continue;
          }
        }

        throw ErrorParser.parseProviderError('claude', error);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _sendStreamingMessages(
    _ClaudeCodeAuth auth,
    Map<String, dynamic> body,
  ) async {
    final endpoint = Uri.parse(messagesEndpoint);
    final headers = <String, String>{
      ..._headersForAuth(auth),
      'Accept': 'text/event-stream',
    };

    final streamMessages = _streamMessages;
    if (streamMessages != null) {
      return streamMessages(endpoint, headers, body);
    }

    final Response<ResponseBody> response = await $dio.postUri<ResponseBody>(
      endpoint,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
      data: body,
    );

    if (response.statusCode != 200) {
      final errorBody = await _readResponseBodyAsString(response.data);
      final decodedError = _decodeErrorBody(errorBody);
      throw DioException(
        requestOptions: response.requestOptions,
        response: Response<dynamic>(
          requestOptions: response.requestOptions,
          statusCode: response.statusCode,
          statusMessage: response.statusMessage,
          data: decodedError ?? errorBody,
        ),
      );
    }

    final responseBody = response.data;
    if (responseBody == null) {
      throw const FormatException('Claude response stream was empty.');
    }

    return _readStreamingResponse(responseBody);
  }

  Map<String, String> _headersForAuth(_ClaudeCodeAuth auth) {
    return <String, String>{
      'anthropic-version': '2023-06-01',
      ...auth.headers,
    };
  }

  Future<String> _readResponseBodyAsString(ResponseBody? responseBody) async {
    if (responseBody == null) return '';
    final buffer = StringBuffer();
    await for (final chunk
        in responseBody.stream.cast<List<int>>().transform(utf8.decoder)) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  Object? _decodeErrorBody(String body) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _readStreamingResponse(
    ResponseBody responseBody,
  ) async {
    final blocks = <int, Map<String, dynamic>>{};
    final inputJsonBuffers = <int, StringBuffer>{};
    var completed = false;
    var eventName = '';
    final dataLines = <String>[];

    await for (final line in responseBody.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.isEmpty) {
        _consumeSseEvent(
          eventName: eventName,
          dataLines: dataLines,
          blocks: blocks,
          inputJsonBuffers: inputJsonBuffers,
          markCompleted: () => completed = true,
        );
        eventName = '';
        dataLines.clear();
        continue;
      }

      if (line.startsWith(':')) continue;

      final separatorIndex = line.indexOf(':');
      final field =
          separatorIndex == -1 ? line : line.substring(0, separatorIndex);
      final value = separatorIndex == -1
          ? ''
          : line.substring(separatorIndex + 1).trimLeft();

      if (field == 'event') {
        eventName = value;
      } else if (field == 'data') {
        dataLines.add(value);
      }
    }

    if (eventName.isNotEmpty || dataLines.isNotEmpty) {
      _consumeSseEvent(
        eventName: eventName,
        dataLines: dataLines,
        blocks: blocks,
        inputJsonBuffers: inputJsonBuffers,
        markCompleted: () => completed = true,
      );
    }

    if (!completed) {
      throw const FormatException(
        'Claude response stream closed before message_stop.',
      );
    }

    return (blocks.keys.toList()..sort()).map((index) {
      final block = blocks[index]!;
      final inputJson = inputJsonBuffers[index]?.toString();
      if (inputJson != null && inputJson.trim().isNotEmpty) {
        block['input'] = _decodeClaudeToolInput(inputJson);
      }
      return block;
    }).toList();
  }

  static void _consumeSseEvent({
    required String eventName,
    required List<String> dataLines,
    required Map<int, Map<String, dynamic>> blocks,
    required Map<int, StringBuffer> inputJsonBuffers,
    required void Function() markCompleted,
  }) {
    if (dataLines.isEmpty) return;

    final data = dataLines.join('\n').trim();
    if (data.isEmpty || data == '[DONE]') return;

    final decoded = jsonDecode(data);
    if (decoded is! Map<dynamic, dynamic>) return;

    final event = Map<String, dynamic>.from(decoded);
    final type = _nonBlank(event['type']?.toString()) ?? eventName;

    switch (type) {
      case 'content_block_start':
        final index = event['index'];
        final rawBlock = event['content_block'];
        if (index is int && rawBlock is Map<dynamic, dynamic>) {
          final block = Map<String, dynamic>.from(rawBlock);
          if (block['type'] == 'text') {
            block['text'] = block['text']?.toString() ?? '';
          }
          blocks[index] = block;
        }
      case 'content_block_delta':
        final index = event['index'];
        final rawDelta = event['delta'];
        if (index is! int || rawDelta is! Map<dynamic, dynamic>) return;

        final block = blocks[index];
        final delta = Map<String, dynamic>.from(rawDelta);
        switch (delta['type']) {
          case 'text_delta':
            if (block != null) {
              block['text'] = '${block['text'] ?? ''}${delta['text'] ?? ''}';
            }
          case 'input_json_delta':
            inputJsonBuffers
                .putIfAbsent(index, StringBuffer.new)
                .write(delta['partial_json'] ?? '');
        }
      case 'message_stop':
        markCompleted();
      case 'error':
        final error = event['error'];
        if (error is Map<dynamic, dynamic>) {
          final errorMap = Map<String, dynamic>.from(error);
          final message = _nonBlank(errorMap['message']?.toString()) ??
              'Claude response stream failed.';
          throw InvalidRequestException(message: message);
        }
        throw const FormatException('Claude response stream failed.');
    }
  }

  static List<Map<String, dynamic>> _extractClaudeToolUses(
    List<Map<String, dynamic>> content,
  ) {
    return content
        .where((block) => block['type'] == 'tool_use')
        .map(Map<String, dynamic>.from)
        .toList();
  }

  static String _extractClaudeText(List<Map<String, dynamic>> content) {
    return content
        .where((block) => block['type'] == 'text')
        .map((block) => (block['text'] ?? '').toString())
        .where((text) => text.trim().isNotEmpty)
        .join('\n')
        .trim();
  }

  Future<Map<String, dynamic>> _executeClaudeToolUse(
    GitAgentTools tools,
    Map<String, dynamic> toolUse,
  ) async {
    final id = toolUse['id']?.toString() ?? '';

    try {
      final name = toolUse['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('Tool use did not include a name.');
      }

      final output = await tools.execute(
        name,
        _decodeClaudeToolInput(toolUse['input']),
      );

      return <String, dynamic>{
        'type': 'tool_result',
        'tool_use_id': id,
        'content': output,
      };
    } on Object catch (error) {
      return <String, dynamic>{
        'type': 'tool_result',
        'tool_use_id': id,
        'content': 'ERROR: $error',
        'is_error': true,
      };
    }
  }

  static Map<String, dynamic> _decodeClaudeToolInput(Object? input) {
    if (input is Map<String, dynamic>) return input;
    if (input is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(input);
    }
    if (input is! String || input.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(input);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(decoded);
    }
    return <String, dynamic>{};
  }

  Future<_ClaudeCodeAuth> _loadAuth({bool allowLogin = true}) async {
    final envAuth = await _readEnvironmentAuth();
    if (envAuth != null) return envAuth;

    if (_isBareMode) {
      throw const AuthenticationException(
        message: 'Claude Code bare mode requires ANTHROPIC_API_KEY.',
      );
    }

    final storedOAuthCredentials = await _readStoredOAuthCredentials();
    if (storedOAuthCredentials != null) {
      final auth = _ClaudeCodeAuth(oauthCredentials: storedOAuthCredentials);
      if (_shouldRefresh(storedOAuthCredentials)) {
        return _refreshClaudeCodeOAuthOrUseStored(auth);
      }
      return auth;
    }

    final storedApiKey = await _readStoredApiKey();
    if (storedApiKey != null) {
      return _ClaudeCodeAuth(apiKey: storedApiKey);
    }

    if (allowLogin) {
      await _runInteractiveLogin();
      return _loadAuth(allowLogin: false);
    }

    throw const AuthenticationException(
      message: 'Claude Code credentials were not found. Run `claude '
          'setup-token` and export CLAUDE_CODE_OAUTH_TOKEN, or set '
          'ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY.',
    );
  }

  Future<_ClaudeCodeAuth?> _readEnvironmentAuth() async {
    final explicitApiKey = _nonBlank(_explicitApiKey);
    final envApiKey = _nonBlank(_env['ANTHROPIC_API_KEY']) ??
        _nonBlank(_env['CLAUDE_API_KEY']);
    final apiKeyFromFileDescriptor = _isBareMode
        ? null
        : _readCredentialFromFileDescriptor(
            'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR',
            _ccrApiKeyPath,
          );
    final apiKey = explicitApiKey ?? envApiKey ?? apiKeyFromFileDescriptor;
    final externalBearerToken =
        _isManagedOAuthContext ? null : _nonBlank(_env['ANTHROPIC_AUTH_TOKEN']);
    final claudeCodeOAuthToken = _isBareMode
        ? null
        : _nonBlank(_env['CLAUDE_CODE_OAUTH_TOKEN']) ??
            _readCredentialFromFileDescriptor(
              'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR',
              _ccrOAuthTokenPath,
            );

    if (_isBareMode) {
      if (apiKey == null) return null;
      return _ClaudeCodeAuth(apiKey: apiKey);
    }

    if (_isManagedOAuthContext && claudeCodeOAuthToken != null) {
      return _ClaudeCodeAuth(
        bearerToken: claudeCodeOAuthToken,
        bearerSource: _ClaudeCodeBearerSource.claudeCodeOAuthToken,
      );
    }

    if (apiKey != null || externalBearerToken != null) {
      return _ClaudeCodeAuth(
        apiKey: apiKey,
        bearerToken: externalBearerToken,
        bearerSource: externalBearerToken == null
            ? null
            : _ClaudeCodeBearerSource.anthropicAuthToken,
      );
    }

    final apiKeyHelperToken = await _readApiKeyHelperToken();
    if (apiKeyHelperToken != null) {
      return _ClaudeCodeAuth(
        bearerToken: apiKeyHelperToken,
        bearerSource: _ClaudeCodeBearerSource.apiKeyHelper,
      );
    }

    if (claudeCodeOAuthToken != null) {
      return _ClaudeCodeAuth(
        bearerToken: claudeCodeOAuthToken,
        bearerSource: _ClaudeCodeBearerSource.claudeCodeOAuthToken,
      );
    }

    return null;
  }

  Future<_ClaudeCodeOAuthCredentials?> _readStoredOAuthCredentials() async {
    final stored = await _readClaudeAiOauthCredentialsFromMacOsKeychain() ??
        await _readClaudeAiOauthCredentialsFromFile();

    // Refreshed tokens that could not be saved stay in use for this run while
    // the store still holds the refresh token they replaced.
    final unsaved = _unsavedOAuthCredentials;
    if (unsaved == null) return stored;
    if (stored == null || stored.refreshToken == unsaved.replacedRefreshToken) {
      return unsaved.credentials;
    }

    _unsavedOAuthCredentials = null;
    return stored;
  }

  Future<_ClaudeCodeOAuthCredentials?>
      _readClaudeAiOauthCredentialsFromMacOsKeychain() async {
    if (!useMacOsKeychain) return null;
    final keychainValue = await _readMacOsKeychainService(
      _macOsKeychainServiceName(credentials: true),
    );
    if (keychainValue == null) return null;

    return _extractClaudeAiOauthCredentials(
      keychainValue,
      _ClaudeCodeOAuthStore.keychain,
    );
  }

  Future<String?> _readStoredApiKey() async {
    if (useMacOsKeychain) {
      final keychainValue = await _readMacOsKeychainService(
        _macOsKeychainServiceName(),
      );
      if (keychainValue != null && !keychainValue.startsWith('{')) {
        return _nonBlank(keychainValue);
      }
    }

    return _readGlobalConfigApiKey();
  }

  Future<_ClaudeCodeOAuthCredentials?>
      _readClaudeAiOauthCredentialsFromFile() async {
    final configDir = _resolvedClaudeConfigDir;
    if (configDir == null) return null;

    final credentialsFile = File(path.join(configDir, '.credentials.json'));
    final decoded = await _readJsonObject(credentialsFile);
    if (decoded == null) return null;

    return _readClaudeAiOauthCredentials(
      decoded,
      _ClaudeCodeOAuthStore.file(credentialsFile, decoded),
    );
  }

  Future<String?> _readGlobalConfigApiKey() async {
    final configFile = _globalClaudeConfigFile;
    if (configFile == null) return null;

    final decoded = await _readJsonObject(configFile);
    if (decoded == null) return null;

    return _readNestedString(decoded, <String>['primaryApiKey']);
  }

  Future<Map<String, dynamic>?> _readJsonObject(File file) async {
    try {
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<dynamic, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }

    return null;
  }

  Future<String?> _readApiKeyHelperToken() async {
    if (_isBareMode || _isManagedOAuthContext) return null;

    final command = _configuredApiKeyHelper;
    if (command == null) return null;

    final ttl = _apiKeyHelperTtl;
    final cached = _apiKeyHelperCache;
    if (cached != null && DateTime.now().difference(cached.timestamp) < ttl) {
      return cached.value;
    }

    try {
      final value = _nonBlank(
        await _runApiKeyHelper(command, _apiKeyHelperTimeout),
      );
      if (value == null) {
        throw StateError('did not return a value');
      }
      _apiKeyHelperCache = _ClaudeCodeApiKeyHelperCache(value);
      return value;
    } on Object catch (error) {
      final reason = error is StateError ? error.message : '$error';
      $logger.warn(
        'Claude Code apiKeyHelper failed: '
        '${_terminalSafeNote(reason, maxLength: 200)}',
      );
      _apiKeyHelperCache = _ClaudeCodeApiKeyHelperCache(' ');
      return ' ';
    }
  }

  String? get _configuredApiKeyHelper {
    String? helper;
    bool? projectTrusted;
    for (final source in _claudeSettingsSources) {
      final value = _readJsonObjectSync(source.file)['apiKeyHelper'];
      final command = value is String ? _nonBlank(value) : null;
      if (command == null) continue;

      // A repository can ship .claude/settings*.json, and apiKeyHelper runs a
      // shell command. Like Claude Code, only honour it once the user has
      // accepted the workspace trust dialog for this folder.
      if (source.isProjectScope) {
        projectTrusted ??= _isProjectTrusted;
        if (!projectTrusted) {
          _warnIgnoredProjectApiKeyHelper(source.file);
          continue;
        }
      }

      helper = command;
    }
    return helper;
  }

  void _warnIgnoredProjectApiKeyHelper(File file) {
    if (_warnedAboutUntrustedProjectSettings) return;
    _warnedAboutUntrustedProjectSettings = true;
    $logger.warn(
      'Ignoring apiKeyHelper from ${file.path} because this folder is not '
      'trusted in Claude Code. Open it with `claude` and accept the trust '
      'prompt to use project settings.',
    );
  }

  List<({File file, bool isProjectScope})> get _claudeSettingsSources {
    final userSettingsFileName =
        _isEnvTruthy(_env['CLAUDE_CODE_USE_COWORK_PLUGINS'])
            ? 'cowork_settings.json'
            : 'settings.json';
    final configDir = _resolvedClaudeConfigDir;
    final projectDirectory = _resolvedProjectDirectory;
    return <({File file, bool isProjectScope})>[
      if (configDir != null)
        (
          file: File(path.join(configDir, userSettingsFileName)),
          isProjectScope: false,
        ),
      (
        file: File(path.join(projectDirectory, '.claude', 'settings.json')),
        isProjectScope: true,
      ),
      (
        file: File(
          path.join(projectDirectory, '.claude', 'settings.local.json'),
        ),
        isProjectScope: true,
      ),
      for (final file in _managedSettingsFiles)
        (file: file, isProjectScope: false),
    ];
  }

  String get _resolvedProjectDirectory =>
      _nonBlank(_projectDirectory) ?? Directory.current.path;

  /// Whether Claude Code's global config records that the user accepted the
  /// workspace trust dialog for exactly this project directory.
  ///
  /// This is deliberately stricter than Claude Code: parent folders,
  /// sandboxed sessions and bypass-permissions acceptance do not count.
  bool get _isProjectTrusted {
    final configFile = _globalClaudeConfigFile;
    if (configFile == null) return false;

    final projects = _readJsonObjectSync(configFile)['projects'];
    if (projects is! Map<dynamic, dynamic>) return false;

    for (final key in _projectConfigKeys) {
      final project = projects[key];
      if (project is Map<dynamic, dynamic> &&
          project['hasTrustDialogAccepted'] == true) {
        return true;
      }
    }
    return false;
  }

  /// Keys Claude Code may have used for this project in `projects`: the
  /// normalized absolute path with forward slashes, before and after
  /// resolving symlinks (e.g. macOS /var vs /private/var).
  Set<String> get _projectConfigKeys {
    String toKey(String directory) =>
        path.normalize(directory).replaceAll(r'\', '/');

    final directory = path.absolute(_resolvedProjectDirectory);
    final keys = <String>{toKey(directory)};
    try {
      keys.add(toKey(Directory(directory).resolveSymbolicLinksSync()));
    } on FileSystemException {
      // The literal path is still checked.
    }
    return keys;
  }

  /// Claude Code's global config file: a legacy `.config.json` in the config
  /// directory if present, otherwise `.claude<oauth suffix>.json` in
  /// CLAUDE_CONFIG_DIR or the home directory.
  File? get _globalClaudeConfigFile {
    final configDir = _resolvedClaudeConfigDir;
    if (configDir != null) {
      final legacyConfig = File(path.join(configDir, '.config.json'));
      if (legacyConfig.existsSync()) return legacyConfig;
    }

    final baseDirectory = _nonBlank(_claudeConfigDir) ??
        _nonBlank(_env['CLAUDE_CONFIG_DIR']) ??
        _homeDirectory;
    if (baseDirectory == null) return null;

    return File(path.join(baseDirectory, '.claude$_oauthFileSuffix.json'));
  }

  List<File> get _managedSettingsFiles {
    final managedPath = _managedSettingsPath;
    final files = <File>[
      File(path.join(managedPath, 'managed-settings.json')),
    ];

    final dropInDir = Directory(path.join(managedPath, 'managed-settings.d'));
    try {
      if (dropInDir.existsSync()) {
        final dropIns = dropInDir.listSync().whereType<File>().where((file) {
          final name = path.basename(file.path);
          return name.endsWith('.json') && !name.startsWith('.');
        }).toList()
          ..sort(
            (left, right) =>
                path.basename(left.path).compareTo(path.basename(right.path)),
          );
        files.addAll(dropIns);
      }
    } on FileSystemException {
      return files;
    }

    return files;
  }

  String get _managedSettingsPath {
    final explicit = _nonBlank(_managedSettingsPathOverride);
    if (explicit != null) return explicit;

    if (_env['USER_TYPE'] == 'ant') {
      final override = _nonBlank(_env['CLAUDE_CODE_MANAGED_SETTINGS_PATH']);
      if (override != null) return override;
    }

    if (Platform.isMacOS) return '/Library/Application Support/ClaudeCode';
    if (Platform.isWindows) return r'C:\Program Files\ClaudeCode';
    return '/etc/claude-code';
  }

  Map<String, dynamic> _readJsonObjectSync(File file) {
    try {
      if (!file.existsSync()) return <String, dynamic>{};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<dynamic, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return <String, dynamic>{};
    } on FileSystemException {
      return <String, dynamic>{};
    }

    return <String, dynamic>{};
  }

  Duration get _apiKeyHelperTtl {
    final raw = _nonBlank(_env['CLAUDE_CODE_API_KEY_HELPER_TTL_MS']);
    if (raw == null) return _apiKeyHelperDefaultTtl;

    final milliseconds = int.tryParse(raw);
    if (milliseconds == null || milliseconds < 0) {
      return _apiKeyHelperDefaultTtl;
    }
    return Duration(milliseconds: milliseconds);
  }

  Future<String?> _readMacOsKeychainService(String service) async {
    final injectedReader = _readMacOsKeychain;
    if (injectedReader != null) {
      final value = await injectedReader(service);
      if (value == null) return null;
      return _decodeMacOsKeychainPassword(value);
    }

    if (!Platform.isMacOS) return null;

    final account = _nonBlank(_env['USER']) ?? _nonBlank(_env['LOGNAME']);
    if (account == null) return null;

    try {
      final result = await Process.run(
        'security',
        <String>[
          'find-generic-password',
          '-a',
          account,
          '-w',
          '-s',
          service,
        ],
      );

      if (result.exitCode != 0) return null;
      return _decodeMacOsKeychainPassword(result.stdout.toString());
    } on ProcessException {
      return null;
    }
  }

  String? _readCredentialFromFileDescriptor(
    String envVar,
    String wellKnownPath,
  ) {
    if (_fileDescriptorCredentialCache.containsKey(envVar)) {
      return _fileDescriptorCredentialCache[envVar];
    }

    final fdValue = _nonBlank(_env[envVar]);
    // The well-known files belong to Claude Code's remote environment. Outside
    // it, /home/claude may be another local user's home, and its contents
    // must not override the user's own credentials.
    final readWellKnownFile = _isRemoteEnvironment;
    if (fdValue == null && !readWellKnownFile) {
      _fileDescriptorCredentialCache[envVar] = null;
      return null;
    }

    final injectedReader = _readFileDescriptorCredential;
    if (injectedReader != null) {
      final value = _nonBlank(injectedReader(envVar, wellKnownPath));
      _fileDescriptorCredentialCache[envVar] = value;
      return value;
    }

    String? value;
    if (fdValue != null) {
      final fd = int.tryParse(fdValue);
      if (fd != null) {
        final fdPath = Platform.isMacOS || Platform.operatingSystem == 'freebsd'
            ? '/dev/fd/$fd'
            : '/proc/self/fd/$fd';
        value = _readCredentialFile(fdPath);
      }
    }

    if (value == null && readWellKnownFile) {
      value = _readCredentialFile(wellKnownPath);
    }
    _fileDescriptorCredentialCache[envVar] = value;
    return value;
  }

  String? _readCredentialFile(String filePath) {
    try {
      return _nonBlank(File(filePath).readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  String? _decodeMacOsKeychainPassword(String raw) {
    final value = _nonBlank(raw);
    if (value == null) return null;
    if (!_looksLikeHex(value)) return value;

    try {
      final bytes = <int>[];
      for (var index = 0; index < value.length; index += 2) {
        bytes.add(int.parse(value.substring(index, index + 2), radix: 16));
      }
      return _nonBlank(utf8.decode(bytes));
    } on Object {
      return value;
    }
  }

  bool _looksLikeHex(String value) {
    if (value.length.isOdd || value.length < 2) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);
  }

  _ClaudeCodeOAuthCredentials? _extractClaudeAiOauthCredentials(
    String rawJson,
    _ClaudeCodeOAuthStore Function(Map<String, dynamic> root) createStore,
  ) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<dynamic, dynamic>) return null;
      final root = Map<String, dynamic>.from(decoded);
      return _readClaudeAiOauthCredentials(
        root,
        createStore(root),
      );
    } on FormatException {
      return null;
    }
  }

  _ClaudeCodeOAuthCredentials? _readClaudeAiOauthCredentials(
    Map<String, dynamic> root,
    _ClaudeCodeOAuthStore store,
  ) {
    final oauth = root['claudeAiOauth'];
    if (oauth is! Map<dynamic, dynamic>) return null;

    final oauthMap = Map<String, dynamic>.from(oauth);
    final accessToken = _nonBlank(oauthMap['accessToken']?.toString());
    if (accessToken == null) return null;

    return _ClaudeCodeOAuthCredentials(
      accessToken: accessToken,
      refreshToken: _nonBlank(oauthMap['refreshToken']?.toString()),
      expiresAt: _parseExpiresAt(oauthMap['expiresAt']),
      scopes: _readScopes(oauthMap['scopes']),
      subscriptionType: _nonBlank(oauthMap['subscriptionType']?.toString()),
      rateLimitTier: _nonBlank(oauthMap['rateLimitTier']?.toString()),
      store: store,
    );
  }

  bool _shouldRefresh(_ClaudeCodeOAuthCredentials credentials) {
    final expiresAt = credentials.expiresAt;
    if (credentials.refreshToken == null || expiresAt == null) return false;
    return DateTime.now()
        .toUtc()
        .add(_refreshBuffer)
        .isAfter(expiresAt.toUtc());
  }

  Future<_ClaudeCodeAuth?> _recoverFromUnauthorized(
    _ClaudeCodeAuth failedAuth,
  ) async {
    final failedCredentials = failedAuth.oauthCredentials;
    if (failedCredentials == null || failedCredentials.refreshToken == null) {
      return null;
    }

    final changedAuth = await _readChangedStoredOAuth(failedAuth);
    if (changedAuth != null) return changedAuth;

    return _refreshClaudeCodeOAuth(failedAuth);
  }

  Future<_ClaudeCodeAuth> _refreshClaudeCodeOAuthOrUseStored(
    _ClaudeCodeAuth auth,
  ) async {
    try {
      return await _refreshClaudeCodeOAuth(auth);
    } on AuthenticationException catch (error) {
      final changedAuth = await _readChangedStoredOAuth(auth);
      if (changedAuth != null) return changedAuth;

      $logger.warn(
        'Claude Code authentication refresh failed; trying stored access '
        'token once. ${error.message}',
      );
      return auth;
    }
  }

  Future<_ClaudeCodeAuth?> _readChangedStoredOAuth(
    _ClaudeCodeAuth failedAuth,
  ) async {
    final failedCredentials = failedAuth.oauthCredentials;
    if (failedCredentials == null) return null;

    final currentCredentials = await _readStoredOAuthCredentials();
    if (currentCredentials != null &&
        currentCredentials.accessToken != failedCredentials.accessToken) {
      return _ClaudeCodeAuth(oauthCredentials: currentCredentials);
    }

    return null;
  }

  Future<_ClaudeCodeAuth> _refreshClaudeCodeOAuth(
    _ClaudeCodeAuth auth,
  ) async {
    final credentials = auth.oauthCredentials;
    final refreshToken = credentials?.refreshToken;
    if (credentials == null || refreshToken == null) return auth;

    return _withCredentialRefreshLock(() async {
      // Another gitwhisper process may have refreshed while this one waited
      // for the lock, which spends the refresh token read earlier.
      final changedAuth = await _readChangedStoredOAuth(auth);
      if (changedAuth != null) return changedAuth;

      $logger.info('Refreshing Claude Code authentication...');
      final refreshed = await _refreshClaudeCodeOAuthCredentials(credentials);
      final saved = await _saveRefreshedClaudeAiOauthCredentials(
        previous: credentials,
        refreshed: refreshed,
      );
      return _ClaudeCodeAuth(oauthCredentials: saved);
    });
  }

  /// Runs [action] while holding an exclusive lock shared by gitwhisper
  /// processes, so only one of them refreshes and saves at a time. Locking is
  /// best effort: saving still re-reads the store before writing.
  Future<T> _withCredentialRefreshLock<T>(Future<T> Function() action) async {
    final configDir = _resolvedClaudeConfigDir;
    if (configDir == null || !Directory(configDir).existsSync()) {
      return action();
    }

    final lockFile = File(path.join(configDir, _credentialLockFileName));
    RandomAccessFile? handle;
    try {
      handle = await lockFile.open(mode: FileMode.append);
      await _acquireExclusiveLock(handle);
    } on FileSystemException catch (error) {
      $logger.detail(
        'Refreshing Claude Code credentials without a lock: ${error.message}',
      );
      await _closeQuietly(handle);
      handle = null;
    }

    try {
      return await action();
    } finally {
      if (handle != null) {
        try {
          await handle.unlock();
        } on FileSystemException {
          // Closing the file releases the lock as well.
        }
        await _closeQuietly(handle);
      }
    }
  }

  static Future<void> _acquireExclusiveLock(RandomAccessFile handle) async {
    final deadline = DateTime.now().add(_credentialLockTimeout);
    while (true) {
      try {
        // The default is a non-blocking exclusive lock; poll so a stuck
        // holder cannot hang this process forever.
        await handle.lock();
        return;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  static Future<void> _closeQuietly(RandomAccessFile? handle) async {
    try {
      await handle?.close();
    } on FileSystemException {
      // Nothing useful to do; the OS releases the handle on exit.
    }
  }

  Future<_ClaudeCodeOAuthCredentials> _refreshClaudeCodeOAuthCredentials(
    _ClaudeCodeOAuthCredentials credentials,
  ) async {
    final refreshToken = credentials.refreshToken;
    if (refreshToken == null) return credentials;

    final scopes = _refreshScopesFor(credentials.scopes);
    final body = <String, dynamic>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': _oauthClientId,
      'scope': scopes.join(' '),
    };

    final data = await _postTokenRefresh(body);
    final accessToken = _nonBlank(data['access_token']?.toString());
    final expiresIn = _parseExpiresIn(data['expires_in']);
    if (accessToken == null || expiresIn == null) {
      throw const AuthenticationException(
        message: 'Claude Code token refresh did not return usable credentials.',
      );
    }

    final responseScopes = _parseScopeString(data['scope']);
    return credentials.copyWith(
      accessToken: accessToken,
      refreshToken:
          _nonBlank(data['refresh_token']?.toString()) ?? refreshToken,
      expiresAt: DateTime.now().toUtc().add(Duration(seconds: expiresIn)),
      scopes: responseScopes.isEmpty ? scopes : responseScopes,
    );
  }

  static List<String> _refreshScopesFor(List<String> scopes) {
    if (scopes.isEmpty || scopes.contains(_claudeAiInferenceScope)) {
      return _defaultOAuthScopes;
    }
    return scopes;
  }

  Future<Map<String, dynamic>> _postTokenRefresh(
    Map<String, dynamic> body,
  ) async {
    final refreshToken = _refreshToken;
    if (refreshToken != null) {
      return refreshToken(_refreshTokenEndpoint, body);
    }

    final Response<Map<String, dynamic>> response = await $dio.postUri(
      _refreshTokenEndpoint,
      options: Options(
        headers: const <String, String>{
          'Content-Type': 'application/json',
        },
        validateStatus: (_) => true,
      ),
      data: body,
    );

    if (response.statusCode != 200 || response.data == null) {
      final detail = _refreshFailureDetail(response.data);
      throw AuthenticationException(
        message: 'Claude Code token refresh failed with status '
            '${response.statusCode ?? 0}'
            '${detail == null ? '' : ': $detail'}. '
            'Run `claude setup-token`.',
        statusCode: response.statusCode ?? 401,
      );
    }

    return response.data!;
  }

  static String? _refreshFailureDetail(Object? data) {
    if (data is! Map<dynamic, dynamic>) return null;
    final error = data['error'];
    if (error is Map<dynamic, dynamic>) {
      return _nonBlank(error['message']?.toString()) ??
          _nonBlank(error['error_description']?.toString()) ??
          _nonBlank(error['type']?.toString()) ??
          _nonBlank(error['code']?.toString());
    }
    if (error is String) return _nonBlank(error);
    return _nonBlank(data['error_description']?.toString()) ??
        _nonBlank(data['message']?.toString());
  }

  /// Saves [refreshed] without clobbering changes made to the store since
  /// [previous] was read, and returns the credentials to use from now on.
  Future<_ClaudeCodeOAuthCredentials> _saveRefreshedClaudeAiOauthCredentials({
    required _ClaudeCodeOAuthCredentials previous,
    required _ClaudeCodeOAuthCredentials refreshed,
  }) async {
    final store = refreshed.store;

    // Re-read right before writing. The refresh (and, after a 401, the
    // request before it) can take minutes, and Claude Code may have saved
    // new tokens or other entries in the meantime.
    final latestRoot = await _readOAuthStoreRoot(store);
    if (latestRoot != null) {
      final latest = _readClaudeAiOauthCredentials(
        latestRoot,
        store.withRoot(latestRoot),
      );
      final latestRefreshToken = latest?.refreshToken;
      if (latest != null &&
          latestRefreshToken != null &&
          latestRefreshToken != previous.refreshToken) {
        // Claude Code refreshed or the user logged in again; keep its tokens.
        return latest;
      }
    }

    final root = Map<String, dynamic>.from(latestRoot ?? store.root);
    root['claudeAiOauth'] = _mergeClaudeAiOauth(
      root['claudeAiOauth'],
      refreshed,
    );
    final saved = refreshed.withStore(store.withRoot(root));

    try {
      await _writeOAuthStoreRoot(store, root);
      _unsavedOAuthCredentials = null;
    } on Object catch (error) {
      // The refresh already spent the old refresh token, so going back to it
      // would sign the user out. Keep the new tokens for the rest of this run.
      _unsavedOAuthCredentials = (
        replacedRefreshToken: previous.refreshToken,
        credentials: saved,
      );
      await _reportCredentialSaveFailure(store, root, error);
    }
    return saved;
  }

  static Map<String, dynamic> _mergeClaudeAiOauth(
    Object? existing,
    _ClaudeCodeOAuthCredentials credentials,
  ) {
    final oauth = existing is Map<dynamic, dynamic>
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};

    oauth['accessToken'] = credentials.accessToken;
    if (credentials.refreshToken != null) {
      oauth['refreshToken'] = credentials.refreshToken;
    }
    if (credentials.expiresAt != null) {
      oauth['expiresAt'] = credentials.expiresAt!.millisecondsSinceEpoch;
    }
    oauth['scopes'] = credentials.scopes;
    if (credentials.subscriptionType != null) {
      oauth['subscriptionType'] = credentials.subscriptionType;
    }
    if (credentials.rateLimitTier != null) {
      oauth['rateLimitTier'] = credentials.rateLimitTier;
    }
    return oauth;
  }

  Future<Map<String, dynamic>?> _readOAuthStoreRoot(
    _ClaudeCodeOAuthStore store,
  ) async {
    final file = store.file;
    if (file != null) return _readJsonObject(file);

    final value = await _readMacOsKeychainService(
      _macOsKeychainServiceName(credentials: true),
    );
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<dynamic, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> _writeOAuthStoreRoot(
    _ClaudeCodeOAuthStore store,
    Map<String, dynamic> root,
  ) async {
    final file = store.file;
    if (file != null) {
      await _writePrivateFileAtomically(file, _encodeCredentialsFile(root));
      return;
    }

    await _writeMacOsKeychainService(
      _macOsKeychainServiceName(credentials: true),
      jsonEncode(root),
    );
  }

  Future<void> _reportCredentialSaveFailure(
    _ClaudeCodeOAuthStore store,
    Map<String, dynamic> root,
    Object error,
  ) async {
    final reason = _describeCredentialSaveError(error);
    final file = store.file;
    if (file == null) {
      $logger.warn(
        'Could not save refreshed Claude Code credentials to the macOS '
        'keychain ($reason). They will be used for this run only, so Claude '
        'Code may ask you to log in again.',
      );
      return;
    }

    final recoveryFile = File('${file.path}$_credentialRecoverySuffix');
    try {
      await _writePrivateFileAtomically(
        recoveryFile,
        _encodeCredentialsFile(root),
      );
      $logger.warn(
        'Could not save refreshed Claude Code credentials to ${file.path} '
        '($reason). They will be used for this run only. A copy readable '
        'only by you was saved to ${recoveryFile.path}; move it to '
        '${file.path} to keep Claude Code signed in.',
      );
    } on Object {
      $logger.warn(
        'Could not save refreshed Claude Code credentials to ${file.path} '
        '($reason). They will be used for this run only, so Claude Code may '
        'ask you to log in again.',
      );
    }
  }

  static String _describeCredentialSaveError(Object error) {
    if (error is FileSystemException) {
      return error.osError?.message ?? error.message;
    }
    if (error is ApiException) return error.message;
    if (error is StateError) return error.message;
    return 'unexpected error';
  }

  static String _encodeCredentialsFile(Map<String, dynamic> root) {
    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert(root)}\n';
  }

  /// Replaces [target] atomically with [contents], readable only by the
  /// owner: a temp file in the same directory is restricted to 0600,
  /// written, flushed and then renamed over the target. A symlinked target
  /// is followed so the link itself is preserved.
  static Future<void> _writePrivateFileAtomically(
    File target,
    String contents,
  ) async {
    final destination = FileSystemEntity.isLinkSync(target.path)
        ? File(target.resolveSymbolicLinksSync())
        : target;
    final temp = File(
      path.join(
        destination.parent.path,
        '.${path.basename(destination.path)}.gitwhisper-$pid-'
        '${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );

    try {
      await temp.create(exclusive: true);
      await _restrictToOwner(temp);
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeString(contents);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temp.rename(destination.path);
    } on Object {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on FileSystemException {
        // Leave the temp file; it holds nothing the target did not.
      }
      rethrow;
    }
  }

  static Future<void> _restrictToOwner(File file) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', <String>['600', file.path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not restrict permissions to the owner',
        file.path,
      );
    }
  }

  Future<void> _writeMacOsKeychainService(
    String service,
    String value,
  ) async {
    final injectedWriter = _writeMacOsKeychain;
    if (injectedWriter != null) {
      await injectedWriter(service, value);
      return;
    }

    if (!Platform.isMacOS) return;

    final account = _nonBlank(_env['USER']) ?? _nonBlank(_env['LOGNAME']);
    if (account == null) return;

    try {
      final result = await Process.run(
        'security',
        <String>[
          'add-generic-password',
          '-U',
          '-a',
          account,
          '-s',
          service,
          '-X',
          _hexEncode(value),
        ],
      );
      if (result.exitCode != 0) {
        throw AuthenticationException(
          message: 'Failed to save refreshed Claude Code credentials.',
          statusCode: result.exitCode,
        );
      }
    } on ProcessException catch (error) {
      throw AuthenticationException(
        message: 'Failed to save refreshed Claude Code credentials: '
            '${error.message}',
      );
    }
  }

  DateTime? _parseExpiresAt(Object? value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is double) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    }
    if (value is String) {
      final numeric = int.tryParse(value);
      if (numeric != null) {
        return DateTime.fromMillisecondsSinceEpoch(numeric, isUtc: true);
      }
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }

  int? _parseExpiresIn(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  List<String> _readScopes(Object? value) {
    if (value is List<dynamic>) {
      return value
          .map((scope) => _nonBlank(scope?.toString()))
          .whereType<String>()
          .toList();
    }
    if (value is String) return _parseScopeString(value);
    return const <String>[];
  }

  List<String> _parseScopeString(Object? value) {
    final raw = _nonBlank(value?.toString());
    if (raw == null) return const <String>[];
    return raw
        .split(RegExp(r'\s+'))
        .map(_nonBlank)
        .whereType<String>()
        .toList();
  }

  String? _readNestedString(
    Map<String, dynamic> object,
    List<String> pathSegments,
  ) {
    Object? current = object;
    for (final segment in pathSegments) {
      if (current is! Map<dynamic, dynamic>) return null;
      current = current[segment];
    }

    return _nonBlank(current?.toString());
  }

  Future<void> _runInteractiveLogin() async {
    $logger.info(
      'Claude Code authentication required. Starting $loginExecutable '
      '${loginArguments.join(' ')}...',
    );

    final exitCode = await _runLogin(loginExecutable, loginArguments);
    if (exitCode != 0) {
      throw AuthenticationException(
        message: '$loginExecutable ${loginArguments.join(' ')} failed with '
            'exit code $exitCode.',
      );
    }
  }

  /// The Claude Code config directory, or null when no home directory is
  /// known. Never falls back to the working directory: a repository's own
  /// `.claude/` must not be mistaken for the user's settings or credentials.
  String? get _resolvedClaudeConfigDir {
    final explicit = _nonBlank(_claudeConfigDir);
    if (explicit != null) return explicit;

    final envDir = _nonBlank(_env['CLAUDE_CONFIG_DIR']);
    if (envDir != null) return envDir;

    final home = _homeDirectory;
    if (home != null) return path.join(home, '.claude');

    return null;
  }

  String? get _homeDirectory =>
      _nonBlank(_env['HOME']) ?? _nonBlank(_env['USERPROFILE']);

  Uri get _refreshTokenEndpoint {
    final customBaseUrl = _customOAuthBaseUrl;
    if (customBaseUrl != null) {
      return Uri.parse('$customBaseUrl/v1/oauth/token');
    }

    if (_env['USER_TYPE'] == 'ant') {
      if (_isEnvTruthy(_env['USE_LOCAL_OAUTH'])) {
        final apiBase = (_nonBlank(_env['CLAUDE_LOCAL_OAUTH_API_BASE']) ??
                'http://localhost:8000')
            .replaceFirst(RegExp(r'/$'), '');
        return Uri.parse('$apiBase/v1/oauth/token');
      }

      if (_isEnvTruthy(_env['USE_STAGING_OAUTH'])) {
        return Uri.parse(
          'https://platform.staging.ant.dev/v1/oauth/token',
        );
      }
    }

    return Uri.parse('https://platform.claude.com/v1/oauth/token');
  }

  String get _oauthClientId {
    final override = _nonBlank(_env['CLAUDE_CODE_OAUTH_CLIENT_ID']);
    if (override != null) return override;

    if (_env['USER_TYPE'] == 'ant' &&
        (_isEnvTruthy(_env['USE_LOCAL_OAUTH']) ||
            _isEnvTruthy(_env['USE_STAGING_OAUTH']))) {
      return _nonProdOAuthClientId;
    }

    return _prodOAuthClientId;
  }

  String? get _customOAuthBaseUrl {
    final value = _nonBlank(_env['CLAUDE_CODE_CUSTOM_OAUTH_URL'])
        ?.replaceFirst(RegExp(r'/$'), '');
    if (value == null) return null;
    if (!_allowedCustomOAuthBaseUrls.contains(value)) {
      throw const AuthenticationException(
        message: 'CLAUDE_CODE_CUSTOM_OAUTH_URL is not an approved endpoint.',
      );
    }
    return value;
  }

  String _macOsKeychainServiceName({bool credentials = false}) {
    final credentialsSuffix = credentials ? '-credentials' : '';
    return 'Claude Code'
        '$_oauthFileSuffix$credentialsSuffix$_configDirHashSuffix';
  }

  String get _oauthFileSuffix {
    if (_nonBlank(_env['CLAUDE_CODE_CUSTOM_OAUTH_URL']) != null) {
      return '-custom-oauth';
    }
    if (_env['USER_TYPE'] == 'ant') {
      if (_isEnvTruthy(_env['USE_LOCAL_OAUTH'])) return '-local-oauth';
      if (_isEnvTruthy(_env['USE_STAGING_OAUTH'])) return '-staging-oauth';
    }
    return '';
  }

  String get _configDirHashSuffix {
    final configDir = _resolvedClaudeConfigDir;
    if (_nonBlank(_env['CLAUDE_CONFIG_DIR']) == null || configDir == null) {
      return '';
    }

    final digest = crypto.sha256
        .convert(utf8.encode(configDir))
        .toString()
        .substring(0, 8);
    return '-$digest';
  }

  static bool _isEnvTruthy(String? value) {
    final normalized = _nonBlank(value)?.toLowerCase();
    if (normalized == null) return false;
    return normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on';
  }

  bool get _isManagedOAuthContext {
    return _isRemoteEnvironment ||
        _env['CLAUDE_CODE_ENTRYPOINT'] == 'claude-desktop';
  }

  bool get _isRemoteEnvironment => _isEnvTruthy(_env['CLAUDE_CODE_REMOTE']);

  bool get _isBareMode => _isEnvTruthy(_env['CLAUDE_CODE_SIMPLE']);

  static String _hexEncode(String value) {
    return utf8
        .encode(value)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String? _nonBlank(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  static Future<int> _defaultRunLogin(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }

  static Future<String> _defaultRunApiKeyHelper(
    String command,
    Duration timeout,
  ) async {
    final executable = Platform.isWindows ? 'cmd' : '/bin/sh';
    final arguments =
        Platform.isWindows ? <String>['/c', command] : <String>['-c', command];
    final process = await Process.start(
      executable,
      arguments,
    );
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    late final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      await _killProcessTree(process);
      // A surviving grandchild may keep the pipes open; stop waiting on them.
      stdoutFuture.ignore();
      stderrFuture.ignore();
      throw StateError('timed out after ${timeout.inSeconds}s');
    }

    final stdout = (await stdoutFuture).trim();
    final stderr = (await stderrFuture).trim();
    if (exitCode != 0) {
      // Helpers can print secrets or terminal escapes on stderr, so only a
      // short, sanitized first line is shown.
      final firstLine = LineSplitter.split(stderr)
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      final note = _terminalSafeNote(
        firstLine,
        maxLength: _helperStderrNoteLength,
      );
      throw StateError(
        note.isEmpty
            ? 'exited with code $exitCode'
            : 'exited with code $exitCode ($note)',
      );
    }
    if (stdout.isEmpty) {
      throw StateError('did not return a value');
    }

    return stdout;
  }

  /// Kills a helper and the processes it started. `/bin/sh -c` keeps its own
  /// children for compound commands, so killing only the shell can leave the
  /// real helper running.
  static Future<void> _killProcessTree(Process process) async {
    if (Platform.isWindows) {
      try {
        await Process.run(
          'taskkill',
          <String>['/PID', '${process.pid}', '/T', '/F'],
        );
      } on ProcessException {
        // Fall through to killing the direct child.
      }
      process.kill();
      return;
    }

    final descendants = await _descendantPids(process.pid);
    process.kill(ProcessSignal.sigkill);
    for (final pid in descendants) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }

  static Future<List<int>> _descendantPids(int rootPid) async {
    final descendants = <int>[];
    final pending = <int>[rootPid];
    while (pending.isNotEmpty) {
      final parent = pending.removeLast();
      final ProcessResult result;
      try {
        result = await Process.run('pgrep', <String>['-P', '$parent']);
      } on ProcessException {
        break;
      }
      for (final line in LineSplitter.split(result.stdout.toString())) {
        final child = int.tryParse(line.trim());
        if (child != null && !descendants.contains(child)) {
          descendants.add(child);
          pending.add(child);
        }
      }
    }
    return descendants;
  }

  /// Strips control characters (including terminal escapes) and truncates
  /// [value] so it is safe to show in a one-line warning.
  static String _terminalSafeNote(String value, {required int maxLength}) {
    final printable = value
        .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (printable.length <= maxLength) return printable;
    return '${printable.substring(0, maxLength)}...';
  }
}

class _ClaudeCodeApiKeyHelperCache {
  _ClaudeCodeApiKeyHelperCache(this.value) : timestamp = DateTime.now();

  final String value;
  final DateTime timestamp;
}

class _ClaudeCodeAuth {
  const _ClaudeCodeAuth({
    this.apiKey,
    this.bearerToken,
    this.bearerSource,
    this.oauthCredentials,
  });

  final String? apiKey;
  final String? bearerToken;
  final _ClaudeCodeBearerSource? bearerSource;
  final _ClaudeCodeOAuthCredentials? oauthCredentials;

  String? get accessToken => bearerToken ?? oauthCredentials?.accessToken;

  Map<String, String> get headers {
    final token = accessToken;
    final usesClaudeAiOAuth = oauthCredentials != null ||
        bearerSource == _ClaudeCodeBearerSource.claudeCodeOAuthToken;
    final betas = <String>{
      'claude-code-20250219',
      if (usesClaudeAiOAuth) 'oauth-2025-04-20',
    };

    return <String, String>{
      if (apiKey != null) 'x-api-key': apiKey!,
      if (token != null) ...<String, String>{
        'Authorization': 'Bearer $token',
      },
      'anthropic-beta': betas.join(','),
    };
  }
}

enum _ClaudeCodeBearerSource {
  anthropicAuthToken,
  apiKeyHelper,
  claudeCodeOAuthToken,
}

class _ClaudeCodeOAuthCredentials {
  const _ClaudeCodeOAuthCredentials({
    required this.accessToken,
    required this.store,
    this.refreshToken,
    this.expiresAt,
    this.scopes = const <String>[],
    this.subscriptionType,
    this.rateLimitTier,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final List<String> scopes;
  final String? subscriptionType;
  final String? rateLimitTier;
  final _ClaudeCodeOAuthStore store;

  _ClaudeCodeOAuthCredentials copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    List<String>? scopes,
  }) {
    return _ClaudeCodeOAuthCredentials(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      scopes: scopes ?? this.scopes,
      subscriptionType: subscriptionType,
      rateLimitTier: rateLimitTier,
      store: store,
    );
  }

  _ClaudeCodeOAuthCredentials withStore(_ClaudeCodeOAuthStore store) {
    return _ClaudeCodeOAuthCredentials(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      scopes: scopes,
      subscriptionType: subscriptionType,
      rateLimitTier: rateLimitTier,
      store: store,
    );
  }
}

class _ClaudeCodeOAuthStore {
  const _ClaudeCodeOAuthStore.file(this.file, this.root);

  const _ClaudeCodeOAuthStore.keychain(this.root) : file = null;

  const _ClaudeCodeOAuthStore._(this.file, this.root);

  final File? file;
  final Map<String, dynamic> root;

  _ClaudeCodeOAuthStore withRoot(Map<String, dynamic> root) {
    return _ClaudeCodeOAuthStore._(file, root);
  }
}

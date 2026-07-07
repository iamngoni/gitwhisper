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
    Map<String, String>? environment,
    ClaudeCodeLoginRunner? runLogin,
    ClaudeCodeMessagesStreamer? streamMessages,
    ClaudeCodeTokenRefresher? refreshToken,
    ClaudeCodeKeychainReader? readMacOsKeychainService,
    ClaudeCodeKeychainWriter? writeMacOsKeychainService,
    ClaudeCodeFileDescriptorCredentialReader? readFileDescriptorCredential,
    ClaudeCodeApiKeyHelperRunner? runApiKeyHelper,
    this.loginExecutable = 'claude',
    this.loginArguments = const <String>['setup-token'],
    this.useMacOsKeychain = true,
  })  : _explicitApiKey = apiKey,
        _claudeConfigDir = claudeConfigDir,
        _environment = environment,
        _runLogin = runLogin ?? _defaultRunLogin,
        _streamMessages = streamMessages,
        _refreshToken = refreshToken,
        _readMacOsKeychain = readMacOsKeychainService,
        _writeMacOsKeychain = writeMacOsKeychainService,
        _readFileDescriptorCredential = readFileDescriptorCredential,
        _runApiKeyHelper = runApiKeyHelper ?? _defaultRunApiKeyHelper,
        super(
          apiKey,
          variant: variant,
          baseUrl: baseUrl ??
              (environment ?? Platform.environment)['ANTHROPIC_BASE_URL'],
        );

  static const String _systemPrompt =
      "You are a Claude agent, built on Anthropic's Claude Agent SDK.";
  static const String _prodOAuthClientId =
      '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const String _nonProdOAuthClientId =
      '22422756-60c9-4084-8eb7-27705fd5cf9a';
  static const Duration _refreshBuffer = Duration(minutes: 5);
  static const Duration _apiKeyHelperDefaultTtl = Duration(minutes: 5);
  static const Duration _apiKeyHelperTimeout = Duration(minutes: 10);
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
  final Map<String, String>? _environment;
  final ClaudeCodeLoginRunner _runLogin;
  final ClaudeCodeMessagesStreamer? _streamMessages;
  final ClaudeCodeTokenRefresher? _refreshToken;
  final ClaudeCodeKeychainReader? _readMacOsKeychain;
  final ClaudeCodeKeychainWriter? _writeMacOsKeychain;
  final ClaudeCodeFileDescriptorCredentialReader? _readFileDescriptorCredential;
  final ClaudeCodeApiKeyHelperRunner _runApiKeyHelper;
  final String loginExecutable;
  final List<String> loginArguments;
  final bool useMacOsKeychain;
  final Map<String, String?> _fileDescriptorCredentialCache =
      <String, String?>{};
  _ClaudeCodeApiKeyHelperCache? _apiKeyHelperCache;

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
    final keychainCredentials =
        await _readClaudeAiOauthCredentialsFromMacOsKeychain();
    if (keychainCredentials != null) return keychainCredentials;

    return _readClaudeAiOauthCredentialsFromFile();
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
    final credentialsFile = File(
      path.join(_resolvedClaudeConfigDir, '.credentials.json'),
    );
    final decoded = await _readJsonObject(credentialsFile);
    if (decoded == null) return null;

    return _readClaudeAiOauthCredentials(
      decoded,
      _ClaudeCodeOAuthStore.file(credentialsFile, decoded),
    );
  }

  Future<String?> _readGlobalConfigApiKey() async {
    final home = _env['HOME'];
    if (home == null || home.isEmpty) return null;

    final decoded =
        await _readJsonObject(File(path.join(home, '.claude.json')));
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
      $logger.warn('Claude Code apiKeyHelper failed: $error');
      _apiKeyHelperCache = _ClaudeCodeApiKeyHelperCache(' ');
      return ' ';
    }
  }

  String? get _configuredApiKeyHelper {
    String? helper;
    for (final file in _claudeSettingsFiles) {
      final settings = _readJsonObjectSync(file);
      final value = settings['apiKeyHelper'];
      if (value is String) {
        helper = _nonBlank(value) ?? helper;
      }
    }
    return helper;
  }

  List<File> get _claudeSettingsFiles {
    final userSettingsFileName =
        _isEnvTruthy(_env['CLAUDE_CODE_USE_COWORK_PLUGINS'])
            ? 'cowork_settings.json'
            : 'settings.json';
    return <File>[
      File(path.join(_resolvedClaudeConfigDir, userSettingsFileName)),
      File(path.join(Directory.current.path, '.claude', 'settings.json')),
      File(path.join(Directory.current.path, '.claude', 'settings.local.json')),
      ..._managedSettingsFiles,
    ];
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

    final injectedReader = _readFileDescriptorCredential;
    if (injectedReader != null) {
      final value = _nonBlank(injectedReader(envVar, wellKnownPath));
      _fileDescriptorCredentialCache[envVar] = value;
      return value;
    }

    final fdValue = _nonBlank(_env[envVar]);
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

    value ??= _readCredentialFile(wellKnownPath);
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

    $logger.info('Refreshing Claude Code authentication...');
    final refreshed = await _refreshClaudeCodeOAuthCredentials(credentials);
    await _saveClaudeAiOauthCredentials(refreshed);
    return _ClaudeCodeAuth(oauthCredentials: refreshed);
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

  Future<void> _saveClaudeAiOauthCredentials(
    _ClaudeCodeOAuthCredentials credentials,
  ) async {
    final store = credentials.store;
    final oauth = store.root['claudeAiOauth'] is Map<dynamic, dynamic>
        ? Map<String, dynamic>.from(
            store.root['claudeAiOauth'] as Map<dynamic, dynamic>,
          )
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
    store.root['claudeAiOauth'] = oauth;

    final file = store.file;
    if (file != null) {
      const encoder = JsonEncoder.withIndent('  ');
      final value = '${encoder.convert(store.root)}\n';
      await file.writeAsString(value);
      return;
    }

    final value = jsonEncode(store.root);
    await _writeMacOsKeychainService(
      _macOsKeychainServiceName(credentials: true),
      value,
    );
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

  String get _resolvedClaudeConfigDir {
    final explicit = _nonBlank(_claudeConfigDir);
    if (explicit != null) return explicit;

    final envDir = _nonBlank(_env['CLAUDE_CONFIG_DIR']);
    if (envDir != null) return envDir;

    final home = _nonBlank(_env['HOME']);
    if (home != null) return path.join(home, '.claude');

    return path.join(Directory.current.path, '.claude');
  }

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
    if (_nonBlank(_env['CLAUDE_CONFIG_DIR']) == null) return '';

    final digest = crypto.sha256
        .convert(utf8.encode(_resolvedClaudeConfigDir))
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
    return _isEnvTruthy(_env['CLAUDE_CODE_REMOTE']) ||
        _env['CLAUDE_CODE_ENTRYPOINT'] == 'claude-desktop';
  }

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
      process.kill();
      throw StateError('timed out');
    }

    final stdout = (await stdoutFuture).trim();
    final stderr = (await stderrFuture).trim();
    if (exitCode != 0) {
      throw StateError(
        stderr.isEmpty ? 'exited $exitCode' : 'exited $exitCode: $stderr',
      );
    }
    if (stdout.isEmpty) {
      throw StateError('did not return a value');
    }

    return stdout;
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
}

class _ClaudeCodeOAuthStore {
  const _ClaudeCodeOAuthStore.file(this.file, this.root);

  const _ClaudeCodeOAuthStore.keychain(this.root) : file = null;

  final File? file;
  final Map<String, dynamic> root;
}

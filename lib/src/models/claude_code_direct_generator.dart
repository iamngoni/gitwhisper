import 'dart:convert';
import 'dart:io';

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
    this.loginExecutable = 'claude',
    this.loginArguments = const <String>['setup-token'],
    this.useMacOsKeychain = true,
  })  : _explicitApiKey = apiKey,
        _claudeConfigDir = claudeConfigDir,
        _environment = environment,
        _runLogin = runLogin ?? _defaultRunLogin,
        _streamMessages = streamMessages,
        _refreshToken = refreshToken,
        super(
          apiKey,
          variant: variant,
          baseUrl: baseUrl ??
              (environment ?? Platform.environment)['ANTHROPIC_BASE_URL'],
        );

  static const String _systemPrompt =
      "You are a Claude agent, built on Anthropic's Claude Agent SDK.";
  static final Uri _refreshTokenEndpoint =
      Uri.parse('https://console.anthropic.com/v1/oauth/token');
  static const String _oauthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
  static const Duration _refreshBuffer = Duration(minutes: 5);
  static const List<String> _defaultOAuthScopes = <String>[
    'user:profile',
    'user:inference',
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
  final String loginExecutable;
  final List<String> loginArguments;
  final bool useMacOsKeychain;

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
        if (!retriedAfterUnauthorized &&
            error.response?.statusCode == 401) {
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
              block['text'] =
                  '${block['text'] ?? ''}${delta['text'] ?? ''}';
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
    final envAuth = _readEnvironmentAuth();
    if (envAuth != null) return envAuth;

    final storedOAuthCredentials = await _readStoredOAuthCredentials();
    if (storedOAuthCredentials != null) {
      final auth = _ClaudeCodeAuth(oauthCredentials: storedOAuthCredentials);
      if (_shouldRefresh(storedOAuthCredentials)) {
        return _refreshClaudeCodeOAuth(auth);
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

  _ClaudeCodeAuth? _readEnvironmentAuth() {
    final apiKey = _nonBlank(_explicitApiKey) ??
        _nonBlank(_env['ANTHROPIC_API_KEY']) ??
        _nonBlank(_env['CLAUDE_API_KEY']);
    final bearerToken = _nonBlank(_env['CLAUDE_CODE_OAUTH_TOKEN']) ??
        _nonBlank(_env['ANTHROPIC_AUTH_TOKEN']);

    if (apiKey == null && bearerToken == null) return null;
    return _ClaudeCodeAuth(apiKey: apiKey, bearerToken: bearerToken);
  }

  Future<_ClaudeCodeOAuthCredentials?> _readStoredOAuthCredentials() async {
    final fileCredentials = await _readClaudeAiOauthCredentialsFromFile();
    if (fileCredentials != null) return fileCredentials;

    if (!useMacOsKeychain) return null;
    final keychainValue = await _readMacOsKeychainService(
      'Claude Code-credentials',
    );
    if (keychainValue == null) return null;

    return _extractClaudeAiOauthCredentials(
      keychainValue,
      _ClaudeCodeOAuthStore.keychain,
    );
  }

  Future<String?> _readStoredApiKey() async {
    final globalConfigKey = await _readGlobalConfigApiKey();
    if (globalConfigKey != null) return globalConfigKey;

    if (!useMacOsKeychain) return null;
    final keychainValue = await _readMacOsKeychainService('Claude Code');
    if (keychainValue == null || keychainValue.startsWith('{')) return null;

    return _nonBlank(keychainValue);
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

  Future<String?> _readMacOsKeychainService(String service) async {
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
      return _nonBlank(result.stdout.toString());
    } on ProcessException {
      return null;
    }
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

    final currentCredentials = await _readStoredOAuthCredentials();
    if (currentCredentials != null &&
        currentCredentials.accessToken != failedCredentials.accessToken) {
      return _ClaudeCodeAuth(oauthCredentials: currentCredentials);
    }

    return _refreshClaudeCodeOAuth(failedAuth);
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

    final scopes =
        credentials.scopes.isEmpty ? _defaultOAuthScopes : credentials.scopes;
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
      throw AuthenticationException(
        message: 'Claude Code token refresh failed with status '
            '${response.statusCode ?? 0}. Run `claude setup-token`.',
        statusCode: response.statusCode ?? 401,
      );
    }

    return response.data!;
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

    const encoder = JsonEncoder.withIndent('  ');
    final value = '${encoder.convert(store.root)}\n';
    final file = store.file;
    if (file != null) {
      await file.writeAsString(value);
      return;
    }

    await _writeMacOsKeychainService('Claude Code-credentials', value);
  }

  Future<void> _writeMacOsKeychainService(
    String service,
    String value,
  ) async {
    if (!Platform.isMacOS) return;

    final account = _nonBlank(_env['USER']) ?? _nonBlank(_env['LOGNAME']);
    if (account == null) return;

    try {
      final result = await Process.run(
        'security',
        <String>[
          'add-generic-password',
          '-a',
          account,
          '-s',
          service,
          '-w',
          value,
          '-U',
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
}

class _ClaudeCodeAuth {
  const _ClaudeCodeAuth({
    this.apiKey,
    this.bearerToken,
    this.oauthCredentials,
  });

  final String? apiKey;
  final String? bearerToken;
  final _ClaudeCodeOAuthCredentials? oauthCredentials;

  String? get accessToken => bearerToken ?? oauthCredentials?.accessToken;

  Map<String, String> get headers {
    final token = accessToken;
    final betas = <String>{
      if (token != null) 'oauth-2025-04-20',
      'claude-code-20250219',
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

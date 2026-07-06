import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import '../agent/agent_commit_generator.dart';
import '../agent/git_agent_tools.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

typedef CodexResponsesPoster = Future<Map<String, dynamic>> Function(
  Uri endpoint,
  Map<String, String> headers,
  Map<String, dynamic> body,
);

typedef CodexLoginRunner = Future<int> Function(
  String executable,
  List<String> arguments,
);

class CodexDirectGenerator extends CommitGenerator
    implements AgentCommitGenerator {
  CodexDirectGenerator({
    String? codexHome,
    Map<String, String>? environment,
    Uri? endpointOverride,
    CodexResponsesPoster? postResponses,
    CodexLoginRunner? runLogin,
    this.loginExecutable = 'codex',
    super.variant,
  })  : _codexHome = codexHome,
        _environment = environment,
        _endpointOverride = endpointOverride,
        _postResponses = postResponses,
        _runLogin = runLogin ?? _defaultRunLogin,
        super(null);

  static final Uri _openAiResponsesEndpoint =
      Uri.parse('https://api.openai.com/v1/responses');
  static final Uri _chatGptCodexResponsesEndpoint =
      Uri.parse('https://chatgpt.com/backend-api/codex/responses');
  static final Uri _refreshTokenEndpoint =
      Uri.parse('https://auth.openai.com/oauth/token');

  static const String _oauthClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';

  final String? _codexHome;
  final Map<String, String>? _environment;
  final Uri? _endpointOverride;
  final CodexResponsesPoster? _postResponses;
  final CodexLoginRunner _runLogin;
  final String loginExecutable;

  Map<String, String> get _env => _environment ?? Platform.environment;

  @override
  String get modelName => 'codex';

  @override
  String get defaultVariant =>
      _configuredDefaultVariant() ?? ModelVariants.getDefault(modelName);

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) {
    return _runResponsesPrompt(
      prompt: getCommitPrompt(
        diff,
        language,
        prefix: prefix,
        withEmoji: withEmoji,
      ),
      maxOutputTokens: maxTokens,
    );
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    return _runResponsesPrompt(
      prompt: getAnalysisPrompt(diff, language),
      maxOutputTokens: maxAnalysisTokens,
    );
  }

  @override
  Future<String> generateAgentCommitMessage(AgentCommitRequest request) {
    return _runResponsesPrompt(
      prompt: getAgentCommitPrompt(
        request.language,
        prefix: request.prefix,
        withEmoji: request.withEmoji,
      ),
      maxOutputTokens: maxTokens,
      tools: request.tools,
      maxToolCalls: request.maxToolCalls,
    );
  }

  Future<String> _runResponsesPrompt({
    required String prompt,
    required int maxOutputTokens,
    GitAgentTools? tools,
    int maxToolCalls = 0,
  }) async {
    var auth = await _loadAuth();
    final input = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'input_text',
            'text': prompt,
          },
        ],
      },
    ];

    var toolCallCount = 0;
    var retriedAfterRefresh = false;

    while (true) {
      final body = _requestBody(
        input: input,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      );

      late final Map<String, dynamic> response;
      try {
        response = await _post(auth, body);
      } on DioException catch (error) {
        if (!retriedAfterRefresh &&
            auth.canRefresh &&
            error.response?.statusCode == 401) {
          auth = await _refreshChatGptAuth(auth);
          retriedAfterRefresh = true;
          continue;
        }
        throw ErrorParser.parseProviderError(modelName, error);
      }

      final outputItems = _extractOutputItems(response);
      final toolCalls = _extractToolCalls(outputItems);

      if (toolCalls.isEmpty) {
        final text = _extractText(response).trim();
        if (text.isEmpty) {
          throw const FormatException(
            'Codex response did not include final text.',
          );
        }
        return text;
      }

      if (tools == null) {
        throw const FormatException(
          'Codex requested tools for a non-agent request.',
        );
      }

      toolCallCount += toolCalls.length;
      if (toolCallCount > maxToolCalls) {
        throw StateError(
          'Agent mode exceeded $maxToolCalls tool calls.',
        );
      }

      input.addAll(outputItems);
      for (final toolCall in toolCalls) {
        final output = await _executeToolCall(tools, toolCall);
        input.add(<String, dynamic>{
          'type': 'function_call_output',
          'call_id': toolCall.callId,
          'output': output,
        });
      }
    }
  }

  Map<String, dynamic> _requestBody({
    required List<Map<String, dynamic>> input,
    required int maxOutputTokens,
    GitAgentTools? tools,
  }) {
    return <String, dynamic>{
      'model': actualVariant,
      'input': input,
      'store': false,
      'stream': false,
      'max_output_tokens': maxOutputTokens,
      if (tools != null) ...<String, dynamic>{
        'tools': _responsesToolDefinitions,
        'tool_choice': 'auto',
        'parallel_tool_calls': true,
      },
    };
  }

  Future<Map<String, dynamic>> _post(
    _CodexAuth auth,
    Map<String, dynamic> body,
  ) async {
    final endpoint = _endpointOverride ?? auth.endpoint;
    final headers = auth.headers;
    final postResponses = _postResponses;
    if (postResponses != null) {
      return postResponses(endpoint, headers, body);
    }

    final Response<Map<String, dynamic>> response = await $dio.postUri(
      endpoint,
      options: Options(headers: headers),
      data: body,
    );

    if (response.statusCode != 200) {
      throw ServerException(
        message: 'Unexpected response from Codex API',
        statusCode: response.statusCode ?? 500,
      );
    }

    final data = response.data;
    if (data == null) {
      throw const FormatException('Codex response was empty.');
    }
    return data;
  }

  Future<_CodexAuth> _loadAuth({bool allowLogin = true}) async {
    final envApiKey = _nonEmptyString(_env['OPENAI_API_KEY']);
    if (envApiKey != null) {
      return _CodexAuth.apiKey(envApiKey);
    }

    final authFile = File(path.join(_resolvedCodexHome, 'auth.json'));
    if (!authFile.existsSync()) {
      if (allowLogin) {
        await _login();
        return _loadAuth(allowLogin: false);
      }
      throw const AuthenticationException(
        message: 'Codex auth.json was not found. Run `codex login`.',
      );
    }

    final decoded = jsonDecode(authFile.readAsStringSync());
    if (decoded is! Map<dynamic, dynamic>) {
      throw const FormatException('Codex auth.json must contain an object.');
    }
    final authJson = Map<String, dynamic>.from(decoded);
    var auth = _CodexAuth.fromJson(authFile, authJson);

    if (auth.canRefresh && _shouldRefresh(auth.token)) {
      auth = await _refreshChatGptAuth(auth);
    }

    return auth;
  }

  Future<void> _login() async {
    $logger.info('Codex authentication required. Starting codex login...');
    final exitCode = await _runLogin(loginExecutable, const <String>['login']);
    if (exitCode != 0) {
      throw AuthenticationException(
        message: 'codex login failed with exit code $exitCode.',
      );
    }
  }

  Future<_CodexAuth> _refreshChatGptAuth(_CodexAuth auth) async {
    final refreshToken = auth.refreshToken;
    final authFile = auth.authFile;
    final authJson = auth.authJson;
    if (refreshToken == null || authFile == null || authJson == null) {
      return auth;
    }

    final Response<Map<String, dynamic>> response = await $dio.postUri(
      _refreshTokenEndpoint,
      options: Options(
        headers: const <String, String>{
          'Content-Type': 'application/json',
        },
      ),
      data: <String, dynamic>{
        'client_id': _oauthClientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );

    if (response.statusCode != 200 || response.data == null) {
      throw AuthenticationException(
        message: 'Codex token refresh failed with status '
            '${response.statusCode ?? 0}.',
      );
    }

    final data = response.data!;
    final tokens = Map<String, dynamic>.from(
      (authJson['tokens'] as Map<dynamic, dynamic>?) ?? <String, dynamic>{},
    );
    final idToken = _nonEmptyString(data['id_token']);
    final accessToken = _nonEmptyString(data['access_token']);
    final newRefreshToken = _nonEmptyString(data['refresh_token']);

    if (idToken != null) tokens['id_token'] = idToken;
    if (accessToken != null) tokens['access_token'] = accessToken;
    if (newRefreshToken != null) tokens['refresh_token'] = newRefreshToken;

    authJson['tokens'] = tokens;
    authJson['last_refresh'] = DateTime.now().toUtc().toIso8601String();

    const encoder = JsonEncoder.withIndent('  ');
    await authFile.writeAsString('${encoder.convert(authJson)}\n');

    return _CodexAuth.fromJson(authFile, authJson);
  }

  String get _resolvedCodexHome {
    final explicit = _codexHome ?? _env['CODEX_HOME'];
    if (explicit != null && explicit.trim().isNotEmpty) return explicit;
    final home = _env['HOME'] ?? _env['USERPROFILE'] ?? Directory.current.path;
    return path.join(home, '.codex');
  }

  String? _configuredDefaultVariant() {
    final configFile = File(path.join(_resolvedCodexHome, 'config.toml'));
    if (!configFile.existsSync()) return null;

    for (final line in configFile.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) return null;
      final match = RegExp(r'^model\s*=\s*"([^"]+)"').firstMatch(trimmed);
      final model = match?.group(1);
      if (model != null && model.trim().isNotEmpty) return model;
    }
    return null;
  }

  bool _shouldRefresh(String token) {
    final expiry = _jwtExpiry(token);
    if (expiry == null) return false;
    return expiry.isBefore(
      DateTime.now().toUtc().add(
            const Duration(minutes: 5),
          ),
    );
  }

  DateTime? _jwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(
          base64Url.normalize(parts[1]),
        ),
      );
      final decoded = jsonDecode(payload);
      if (decoded is! Map<dynamic, dynamic>) return null;
      final exp = decoded['exp'];
      if (exp is int) {
        return DateTime.fromMillisecondsSinceEpoch(
          exp * 1000,
          isUtc: true,
        );
      }
      return null;
    } on Object {
      return null;
    }
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

  static List<Map<String, dynamic>> get _responsesToolDefinitions {
    return GitAgentTools.openAiToolDefinitions.map((tool) {
      final function = Map<String, dynamic>.from(
        tool['function'] as Map<dynamic, dynamic>,
      );
      return <String, dynamic>{
        'type': 'function',
        'name': function['name'],
        'description': function['description'],
        'parameters': function['parameters'],
      };
    }).toList();
  }

  static List<Map<String, dynamic>> _extractOutputItems(
    Map<String, dynamic> response,
  ) {
    final output = response['output'];
    if (output is! List<dynamic>) return <Map<String, dynamic>>[];
    return output
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  static List<_CodexToolCall> _extractToolCalls(
    List<Map<String, dynamic>> outputItems,
  ) {
    final calls = <_CodexToolCall>[];
    for (final item in outputItems) {
      final type = item['type'];
      if (type != 'function_call') continue;

      final name = _nonEmptyString(item['name']);
      final callId =
          _nonEmptyString(item['call_id']) ?? _nonEmptyString(item['id']);
      if (name == null || callId == null) continue;

      calls.add(
        _CodexToolCall(
          callId: callId,
          name: name,
          arguments: _decodeToolArguments(item['arguments']),
        ),
      );
    }
    return calls;
  }

  static String _extractText(Map<String, dynamic> response) {
    final topLevelText = _nonEmptyString(response['output_text']);
    if (topLevelText != null) return topLevelText;

    final buffer = StringBuffer();
    for (final item in _extractOutputItems(response)) {
      if (item['type'] != 'message') continue;
      final content = item['content'];
      if (content is String) {
        buffer.write(content);
      } else if (content is List<dynamic>) {
        for (final part in content.whereType<Map<dynamic, dynamic>>()) {
          final text = _nonEmptyString(part['text']) ??
              _nonEmptyString(part['output_text']);
          if (text != null) buffer.write(text);
        }
      }
    }
    return buffer.toString();
  }

  static Future<String> _executeToolCall(
    GitAgentTools tools,
    _CodexToolCall toolCall,
  ) async {
    try {
      return await tools.execute(toolCall.name, toolCall.arguments);
    } on Object catch (error) {
      return 'ERROR: $error';
    }
  }

  static Map<String, dynamic> _decodeToolArguments(Object? arguments) {
    if (arguments is Map<String, dynamic>) return arguments;
    if (arguments is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(arguments);
    }
    if (arguments is! String || arguments.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(arguments);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(decoded);
    }
    return <String, dynamic>{};
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _CodexAuth {
  const _CodexAuth({
    required this.token,
    required this.endpoint,
    required this.authMode,
    this.accountId,
    this.isFedrampAccount = false,
    this.refreshToken,
    this.authFile,
    this.authJson,
  });

  factory _CodexAuth.apiKey(String apiKey) {
    return _CodexAuth(
      token: apiKey,
      endpoint: CodexDirectGenerator._openAiResponsesEndpoint,
      authMode: 'apikey',
    );
  }

  factory _CodexAuth.fromJson(
    File authFile,
    Map<String, dynamic> authJson,
  ) {
    final authMode = CodexDirectGenerator._nonEmptyString(
          authJson['auth_mode'],
        ) ??
        '';
    final openAiApiKey = CodexDirectGenerator._nonEmptyString(
      authJson['OPENAI_API_KEY'],
    );
    final tokens = authJson['tokens'] is Map<dynamic, dynamic>
        ? Map<String, dynamic>.from(authJson['tokens'] as Map<dynamic, dynamic>)
        : <String, dynamic>{};
    final accessToken = CodexDirectGenerator._nonEmptyString(
      tokens['access_token'],
    );

    if (authMode == 'apikey' && openAiApiKey != null) {
      return _CodexAuth.apiKey(openAiApiKey);
    }

    if (accessToken != null) {
      final accountId = CodexDirectGenerator._nonEmptyString(
            tokens['account_id'],
          ) ??
          _accountIdFromIdToken(tokens['id_token']);
      final fedramp = _fedrampFromIdToken(tokens['id_token']);
      return _CodexAuth(
        token: accessToken,
        endpoint: CodexDirectGenerator._chatGptCodexResponsesEndpoint,
        authMode: authMode.isEmpty ? 'chatgpt' : authMode,
        accountId: accountId,
        isFedrampAccount: fedramp,
        refreshToken: CodexDirectGenerator._nonEmptyString(
          tokens['refresh_token'],
        ),
        authFile: authFile,
        authJson: authJson,
      );
    }

    if (openAiApiKey != null) {
      return _CodexAuth.apiKey(openAiApiKey);
    }

    final personalAccessToken = CodexDirectGenerator._nonEmptyString(
      authJson['personal_access_token'],
    );
    if (personalAccessToken != null) {
      return _CodexAuth(
        token: personalAccessToken,
        endpoint: CodexDirectGenerator._chatGptCodexResponsesEndpoint,
        authMode: 'personal',
        authFile: authFile,
        authJson: authJson,
      );
    }

    if (authJson.containsKey('agent_identity')) {
      throw const AuthenticationException(
        message: 'Codex agent identity auth is not supported by GitWhisper '
            'direct mode yet.',
      );
    }

    throw const AuthenticationException(
      message: 'Codex auth.json did not contain usable credentials. '
          'Run `codex login`.',
    );
  }

  final String token;
  final Uri endpoint;
  final String authMode;
  final String? accountId;
  final bool isFedrampAccount;
  final String? refreshToken;
  final File? authFile;
  final Map<String, dynamic>? authJson;

  bool get canRefresh =>
      authMode == 'chatgpt' && refreshToken != null && authFile != null;

  Map<String, String> get headers {
    return <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      if (accountId != null) 'ChatGPT-Account-ID': accountId!,
      if (isFedrampAccount) 'X-OpenAI-Fedramp': 'true',
    };
  }

  static String? _accountIdFromIdToken(Object? idToken) {
    final payload = _jwtPayload(idToken);
    final auth = payload?['https://api.openai.com/auth'];
    if (auth is! Map<dynamic, dynamic>) return null;
    return CodexDirectGenerator._nonEmptyString(auth['chatgpt_account_id']);
  }

  static bool _fedrampFromIdToken(Object? idToken) {
    final payload = _jwtPayload(idToken);
    final auth = payload?['https://api.openai.com/auth'];
    if (auth is! Map<dynamic, dynamic>) return false;
    return auth['chatgpt_account_is_fedramp'] == true;
  }

  static Map<String, dynamic>? _jwtPayload(Object? idToken) {
    final token = CodexDirectGenerator._nonEmptyString(idToken);
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(
          base64Url.normalize(parts[1]),
        ),
      );
      final decoded = jsonDecode(payload);
      if (decoded is! Map<dynamic, dynamic>) return null;
      return Map<String, dynamic>.from(decoded);
    } on Object {
      return null;
    }
  }
}

class _CodexToolCall {
  const _CodexToolCall({
    required this.callId,
    required this.name,
    required this.arguments,
  });

  final String callId;
  final String name;
  final Map<String, dynamic> arguments;
}

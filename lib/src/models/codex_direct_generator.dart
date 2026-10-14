import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import '../agent/agent_commit_generator.dart';
import '../agent/git_agent_tools.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import '../git_utils.dart';
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
  static const String _commitRetryPrompt =
      'You stopped before returning the final commit message. Using the '
      'staged-change context you already inspected, return only the final '
      'conventional commit message now. No explanation, no planning text, no '
      'Markdown.';

  final String? _codexHome;
  final Map<String, String>? _environment;
  final Uri? _endpointOverride;
  final CodexResponsesPoster? _postResponses;
  final CodexLoginRunner _runLogin;
  final String loginExecutable;
  ({String? replacedRefreshToken, _CodexAuth auth})? _unsavedAuth;

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
    );
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    return _runResponsesPrompt(
      prompt: getAnalysisPrompt(diff, language),
    );
  }

  @override
  Future<String> generateAgentCommitMessage(AgentCommitRequest request) {
    return _runResponsesPrompt(
      prompt: getAgentCommitPrompt(
        request.language,
        prefix: request.prefix,
        withEmoji: request.withEmoji,
        additionalContext: request.additionalContext,
      ),
      tools: request.tools,
      maxToolCalls: request.maxToolCalls,
    );
  }

  Future<String> _runResponsesPrompt({
    required String prompt,
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
    var retriedForCommitMessage = false;

    while (true) {
      final body = _requestBody(
        input: input,
        tools: tools,
      );

      late final Map<String, dynamic> response;
      try {
        response = await _post(auth, body);
      } on DioException catch (error) {
        if (!retriedAfterRefresh &&
            auth.canRefresh &&
            error.response?.statusCode == 401) {
          auth = await _recoverFromUnauthorized(auth);
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
        if (tools != null &&
            !retriedForCommitMessage &&
            _shouldRetryForCommitMessage(text)) {
          input
            ..addAll(outputItems.map(_stripResponseItemForInput))
            ..add(_inputTextMessage(_commitRetryPrompt));
          retriedForCommitMessage = true;
          continue;
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

      input.addAll(outputItems.map(_stripResponseItemForInput));
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

  static bool _shouldRetryForCommitMessage(String text) {
    final normalized = text.trim().toLowerCase();
    if (normalized.isEmpty ||
        normalized.contains('upgrade your plan to continue') ||
        normalized.contains('payment required') ||
        normalized.contains('paid credits') ||
        normalized.contains('out of credits') ||
        normalized.contains('quota exceeded') ||
        normalized.contains('rate limit') ||
        normalized.startsWith('error:')) {
      return false;
    }
    return GitUtils.sanitizeGeneratedCommitMessage(
      text,
      requireConventionalCommit: true,
    ).trim().isEmpty;
  }

  static Map<String, dynamic> _inputTextMessage(String text) {
    return <String, dynamic>{
      'role': 'user',
      'content': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'input_text',
          'text': text,
        },
      ],
    };
  }

  Map<String, dynamic> _requestBody({
    required List<Map<String, dynamic>> input,
    GitAgentTools? tools,
  }) {
    return <String, dynamic>{
      'model': actualVariant,
      'input': input,
      'tool_choice': 'auto',
      'parallel_tool_calls': tools != null,
      'reasoning': null,
      'store': false,
      'stream': true,
      'include': <String>[],
      if (tools != null) ...<String, dynamic>{
        'tools': _responsesToolDefinitions,
      },
    };
  }

  Future<Map<String, dynamic>> _post(
    _CodexAuth auth,
    Map<String, dynamic> body,
  ) async {
    final endpoint = _endpointOverride ?? auth.endpoint;
    final headers = <String, String>{
      ...auth.headers,
      'Accept': 'text/event-stream',
    };
    final postResponses = _postResponses;
    if (postResponses != null) {
      return postResponses(endpoint, headers, body);
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
      throw DioException(
        requestOptions: response.requestOptions,
        response: Response<dynamic>(
          requestOptions: response.requestOptions,
          statusCode: response.statusCode,
          statusMessage: response.statusMessage,
          data: _decodeErrorBody(errorBody) ?? errorBody,
        ),
      );
    }

    final responseBody = response.data;
    if (responseBody == null) {
      throw const FormatException('Codex response stream was empty.');
    }
    return _readStreamingResponse(responseBody);
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

  static Object? _decodeErrorBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;

    try {
      return jsonDecode(trimmed);
    } on FormatException {
      return <String, dynamic>{
        'error': <String, dynamic>{
          'message': trimmed,
        },
      };
    }
  }

  Future<Map<String, dynamic>> _readStreamingResponse(
    ResponseBody responseBody,
  ) async {
    final output = <Map<String, dynamic>>[];
    final outputText = StringBuffer();
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
          output: output,
          outputText: outputText,
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
        output: output,
        outputText: outputText,
        markCompleted: () => completed = true,
      );
    }

    if (!completed) {
      throw const FormatException(
        'Codex response stream closed before response.completed.',
      );
    }

    return <String, dynamic>{
      'output': output,
      if (outputText.isNotEmpty) 'output_text': outputText.toString(),
    };
  }

  static void _consumeSseEvent({
    required String eventName,
    required List<String> dataLines,
    required List<Map<String, dynamic>> output,
    required StringBuffer outputText,
    required void Function() markCompleted,
  }) {
    if (dataLines.isEmpty) return;

    final data = dataLines.join('\n').trim();
    if (data.isEmpty || data == '[DONE]') return;

    final decoded = jsonDecode(data);
    if (decoded is! Map<dynamic, dynamic>) return;

    final event = Map<String, dynamic>.from(decoded);
    final type = _nonEmptyString(event['type']) ?? eventName;

    switch (type) {
      case 'response.output_item.done':
        final item = event['item'];
        if (item is Map<dynamic, dynamic>) {
          output.add(Map<String, dynamic>.from(item));
        }
      case 'response.output_text.delta':
        final delta = event['delta'];
        if (delta is String) outputText.write(delta);
      case 'response.completed':
        markCompleted();
      case 'response.failed':
        _throwStreamingFailure(event, fallback: 'Codex response failed.');
      case 'response.incomplete':
        _throwStreamingFailure(
          event,
          fallback: 'Codex response was incomplete.',
        );
    }
  }

  static Never _throwStreamingFailure(
    Map<String, dynamic> event, {
    required String fallback,
  }) {
    final response = event['response'];
    final error = response is Map<dynamic, dynamic> ? response['error'] : null;
    if (error is Map<dynamic, dynamic>) {
      final errorMap = Map<String, dynamic>.from(error);
      final message = _nonEmptyString(errorMap['message']) ?? fallback;
      throw InvalidRequestException(message: message);
    }

    throw FormatException(fallback);
  }

  Future<_CodexAuth> _loadAuth({bool allowLogin = true}) async {
    final envApiKey = _nonEmptyString(_env['OPENAI_API_KEY']);
    if (envApiKey != null) {
      return _CodexAuth.apiKey(envApiKey);
    }

    final codexHome = _resolvedCodexHome;
    if (codexHome == null) {
      throw const AuthenticationException(
        message: 'Could not find the Codex home directory. Set CODEX_HOME '
            'or HOME.',
      );
    }

    final authFile = File(path.join(codexHome, 'auth.json'));
    if (!authFile.existsSync()) {
      if (allowLogin) {
        await _login();
        return _loadAuth(allowLogin: false);
      }
      throw const AuthenticationException(
        message: 'Codex auth.json was not found. Run `codex login`.',
      );
    }

    var auth = _CodexAuth.fromJson(authFile, _readAuthJson(authFile));

    // Refreshed tokens that could not be saved stay in use for this run while
    // auth.json still holds the refresh token they replaced.
    final unsaved = _unsavedAuth;
    if (unsaved != null) {
      if (auth.refreshToken == unsaved.replacedRefreshToken) {
        return unsaved.auth;
      }
      _unsavedAuth = null;
    }

    if (auth.canRefresh && _shouldRefresh(auth.token)) {
      auth = await _refreshChatGptAuth(auth);
    }

    return auth;
  }

  static Map<String, dynamic> _readAuthJson(File authFile) {
    final decoded = jsonDecode(authFile.readAsStringSync());
    if (decoded is! Map<dynamic, dynamic>) {
      throw const FormatException('Codex auth.json must contain an object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static _CodexAuth? _readStoredAuth(File authFile) {
    try {
      return _CodexAuth.fromJson(authFile, _readAuthJson(authFile));
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } on AuthenticationException {
      return null;
    }
  }

  /// After a 401, prefers a token Codex saved since this run read auth.json
  /// and only refreshes when the file still holds the rejected token.
  Future<_CodexAuth> _recoverFromUnauthorized(_CodexAuth failedAuth) async {
    final authFile = failedAuth.authFile;
    final stored = authFile == null ? null : _readStoredAuth(authFile);
    if (stored != null && stored.token != failedAuth.token) return stored;

    return _refreshChatGptAuth(
      stored != null && stored.canRefresh ? stored : failedAuth,
    );
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
    final snapshotJson = auth.authJson;
    if (refreshToken == null || authFile == null || snapshotJson == null) {
      return auth;
    }

    $logger.info('Refreshing Codex authentication...');
    final data = await _postTokenRefresh(refreshToken);
    final idToken = _nonEmptyString(data['id_token']);
    final accessToken = _nonEmptyString(data['access_token']);
    final newRefreshToken = _nonEmptyString(data['refresh_token']);

    // Re-read right before writing: Codex may have refreshed (rotating the
    // refresh token) or changed other fields while the request was running.
    Map<String, dynamic>? latestJson;
    try {
      latestJson = _readAuthJson(authFile);
    } on FormatException {
      latestJson = null;
    } on FileSystemException {
      latestJson = null;
    }

    if (latestJson != null) {
      final latestTokens = latestJson['tokens'];
      final latestRefreshToken = latestTokens is Map<dynamic, dynamic>
          ? _nonEmptyString(latestTokens['refresh_token'])
          : null;
      if (latestRefreshToken != null && latestRefreshToken != refreshToken) {
        // Codex refreshed or the user logged in again; keep its tokens.
        try {
          return _CodexAuth.fromJson(authFile, latestJson);
        } on AuthenticationException {
          // Unusable; save the tokens from this refresh instead.
        }
      }
    }

    final authJson =
        Map<String, dynamic>.from(latestJson ?? Map.of(snapshotJson));
    final existingTokens = authJson['tokens'];
    final tokens = existingTokens is Map<dynamic, dynamic>
        ? Map<String, dynamic>.from(existingTokens)
        : <String, dynamic>{};

    if (idToken != null) tokens['id_token'] = idToken;
    if (accessToken != null) tokens['access_token'] = accessToken;
    if (newRefreshToken != null) tokens['refresh_token'] = newRefreshToken;

    authJson['tokens'] = tokens;
    authJson['last_refresh'] = DateTime.now().toUtc().toIso8601String();
    final refreshed = _CodexAuth.fromJson(authFile, authJson);

    const encoder = JsonEncoder.withIndent('  ');
    try {
      await _writePrivateFileAtomically(
        authFile,
        '${encoder.convert(authJson)}\n',
      );
      _unsavedAuth = null;
    } on Object catch (error) {
      // The refresh already spent the old refresh token, so going back to it
      // would sign the user out. Keep the new tokens for the rest of this run.
      _unsavedAuth = (replacedRefreshToken: refreshToken, auth: refreshed);
      final reason = error is FileSystemException
          ? error.osError?.message ?? error.message
          : 'unexpected error';
      $logger.warn(
        'Could not save refreshed Codex credentials to ${authFile.path} '
        '($reason). They will be used for this run only, so Codex may ask '
        'you to log in again.',
      );
    }

    return refreshed;
  }

  Future<Map<String, dynamic>> _postTokenRefresh(String refreshToken) async {
    final Response<dynamic> response;
    try {
      response = await $dio.postUri<dynamic>(
        _refreshTokenEndpoint,
        options: Options(
          headers: const <String, String>{
            'Content-Type': 'application/json',
          },
          validateStatus: (_) => true,
        ),
        data: <String, dynamic>{
          'client_id': _oauthClientId,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        },
      );
    } on DioException catch (error) {
      final failedResponse = error.response;
      if (failedResponse == null) {
        throw ErrorParser.parseProviderError(modelName, error);
      }
      throw _refreshFailure(
        failedResponse.statusCode,
        failedResponse.data,
        refreshToken,
      );
    }

    final data = response.data;
    if (response.statusCode != 200 || data is! Map<dynamic, dynamic>) {
      throw _refreshFailure(response.statusCode, data, refreshToken);
    }
    return Map<String, dynamic>.from(data);
  }

  static AuthenticationException _refreshFailure(
    int? statusCode,
    Object? data,
    String refreshToken,
  ) {
    final detail = _refreshFailureDetail(data, refreshToken);
    return AuthenticationException(
      message: 'Codex token refresh failed with status ${statusCode ?? 0}'
          '${detail == null ? '' : ': $detail'}. Run `codex login`.',
      statusCode: statusCode ?? 401,
    );
  }

  /// The server's error text, with the refresh token redacted, control
  /// characters removed and the length capped.
  static String? _refreshFailureDetail(Object? data, String refreshToken) {
    String? detail;
    if (data is Map<dynamic, dynamic>) {
      final error = data['error'];
      if (error is Map<dynamic, dynamic>) {
        detail = _nonEmptyString(error['message']) ??
            _nonEmptyString(error['error_description']) ??
            _nonEmptyString(error['code']) ??
            _nonEmptyString(error['type']);
      } else {
        detail = _nonEmptyString(data['error_description']) ??
            _nonEmptyString(error) ??
            _nonEmptyString(data['message']);
      }
    } else {
      detail = _nonEmptyString(data);
    }
    if (detail == null) return null;

    final sanitized = detail
        .replaceAll(refreshToken, '[redacted]')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (sanitized.length <= 200) return sanitized;
    return '${sanitized.substring(0, 200)}...';
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
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', <String>['600', temp.path]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'Could not restrict permissions to the owner',
            temp.path,
          );
        }
      }
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

  /// The Codex home directory, or null when no home directory is known.
  /// Never falls back to the working directory: a repository's own `.codex/`
  /// must not be mistaken for the user's credentials or settings.
  String? get _resolvedCodexHome {
    final explicit = _nonEmptyString(_codexHome ?? _env['CODEX_HOME']);
    if (explicit != null) return explicit;
    final home =
        _nonEmptyString(_env['HOME']) ?? _nonEmptyString(_env['USERPROFILE']);
    if (home == null) return null;
    return path.join(home, '.codex');
  }

  String? _configuredDefaultVariant() {
    final codexHome = _resolvedCodexHome;
    if (codexHome == null) return null;
    final configFile = File(path.join(codexHome, 'config.toml'));
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

  static Map<String, dynamic> _stripResponseItemForInput(
    Map<String, dynamic> item,
  ) {
    return Map<String, dynamic>.from(item)..remove('id');
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

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

class ClaudeCodeDirectGenerator extends ClaudeGenerator {
  ClaudeCodeDirectGenerator({
    String? apiKey,
    String? variant,
    String? baseUrl,
    String? claudeConfigDir,
    Map<String, String>? environment,
    ClaudeCodeLoginRunner? runLogin,
    ClaudeCodeMessagesStreamer? streamMessages,
    this.loginExecutable = 'claude',
    this.loginArguments = const <String>['setup-token'],
    this.useMacOsKeychain = true,
  })  : _explicitApiKey = apiKey,
        _claudeConfigDir = claudeConfigDir,
        _environment = environment,
        _runLogin = runLogin ?? _defaultRunLogin,
        _streamMessages = streamMessages,
        super(
          apiKey,
          variant: variant,
          baseUrl: baseUrl ??
              (environment ?? Platform.environment)['ANTHROPIC_BASE_URL'],
        );

  static const String _systemPrompt =
      "You are a Claude agent, built on Anthropic's Claude Agent SDK.";

  final String? _explicitApiKey;
  final String? _claudeConfigDir;
  final Map<String, String>? _environment;
  final ClaudeCodeLoginRunner _runLogin;
  final ClaudeCodeMessagesStreamer? _streamMessages;
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
    return <String, String>{
      'anthropic-version': '2023-06-01',
      ...auth.headers,
    };
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
    final endpoint = Uri.parse(messagesEndpoint);
    final headers = <String, String>{
      ...await resolveHeaders(),
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
      throw ErrorParser.parseProviderError(
        'claude',
        DioException(
          requestOptions: response.requestOptions,
          response: Response<dynamic>(
            requestOptions: response.requestOptions,
            statusCode: response.statusCode,
            statusMessage: response.statusMessage,
            data: decodedError ?? errorBody,
          ),
        ),
      );
    }

    final responseBody = response.data;
    if (responseBody == null) {
      throw const FormatException('Claude response stream was empty.');
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

    final storedOAuthToken = await _readStoredOAuthToken();
    if (storedOAuthToken != null) {
      return _ClaudeCodeAuth(bearerToken: storedOAuthToken);
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

  Future<String?> _readStoredOAuthToken() async {
    final fileToken = await _readClaudeAiOauthTokenFromFile();
    if (fileToken != null) return fileToken;

    if (!useMacOsKeychain) return null;
    final keychainValue = await _readMacOsKeychainService(
      'Claude Code-credentials',
    );
    if (keychainValue == null) return null;

    return _extractClaudeAiOauthToken(keychainValue);
  }

  Future<String?> _readStoredApiKey() async {
    final globalConfigKey = await _readGlobalConfigApiKey();
    if (globalConfigKey != null) return globalConfigKey;

    if (!useMacOsKeychain) return null;
    final keychainValue = await _readMacOsKeychainService('Claude Code');
    if (keychainValue == null || keychainValue.startsWith('{')) return null;

    return _nonBlank(keychainValue);
  }

  Future<String?> _readClaudeAiOauthTokenFromFile() async {
    final credentialsFile = File(
      path.join(_resolvedClaudeConfigDir, '.credentials.json'),
    );
    final decoded = await _readJsonObject(credentialsFile);
    if (decoded == null) return null;

    return _readNestedString(decoded, <String>[
      'claudeAiOauth',
      'accessToken',
    ]);
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

  String? _extractClaudeAiOauthToken(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<dynamic, dynamic>) return null;
      return _readNestedString(
        Map<String, dynamic>.from(decoded),
        <String>['claudeAiOauth', 'accessToken'],
      );
    } on FormatException {
      return null;
    }
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
  });

  final String? apiKey;
  final String? bearerToken;

  Map<String, String> get headers {
    final betas = <String>{
      if (bearerToken != null) 'oauth-2025-04-20',
      'claude-code-20250219',
    };

    return <String, String>{
      if (apiKey != null) 'x-api-key': apiKey!,
      if (bearerToken != null) ...<String, String>{
        'Authorization': 'Bearer $bearerToken',
      },
      'anthropic-beta': betas.join(','),
    };
  }
}

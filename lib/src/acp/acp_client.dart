import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef AcpProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

typedef AcpRetryPredicate = bool Function(String text, int turn);

class AcpException implements Exception {
  const AcpException(this.message, {this.details});

  factory AcpException.fromJsonRpcError(Object? error) {
    final rawMessage = error.toString();
    if (error is Map<String, dynamic>) {
      final authMethods = _authMethodsFromError(error);
      if (authMethods.isNotEmpty) {
        return AcpAuthenticationRequiredException(
          authMethods,
          details: jsonEncode(error),
        );
      }

      final fallbackAuthMethods = _fallbackAuthMethodsFromError(error);
      if (fallbackAuthMethods.isNotEmpty) {
        return AcpAuthenticationRequiredException(
          fallbackAuthMethods,
          details: jsonEncode(error),
        );
      }
    }

    final normalized = rawMessage.toLowerCase();

    if (normalized.contains('401 unauthorized') ||
        normalized.contains('api key') ||
        normalized.contains('authorization header')) {
      return AcpException(
        'The ACP agent started, but its model provider is not authenticated.\n'
        'Configure that agent/provider and retry. If the agent has a login '
        'command, run it, or set the provider API key it is configured to use.',
        details: rawMessage,
      );
    }

    return AcpException(rawMessage);
  }

  final String message;
  final String? details;

  @override
  String toString() => message;

  static List<AcpAuthMethod> _authMethodsFromError(Map<String, dynamic> error) {
    final data = error['data'];
    final rawAuthMethods = data is Map<String, dynamic>
        ? data['authMethods']
        : error['authMethods'];
    if (rawAuthMethods is! List) return const <AcpAuthMethod>[];

    return rawAuthMethods
        .whereType<Map<String, dynamic>>()
        .map(AcpAuthMethod.fromJson)
        .where((method) => method.id.isNotEmpty)
        .toList();
  }

  static List<AcpAuthMethod> _fallbackAuthMethodsFromError(
    Map<String, dynamic> error,
  ) {
    final errorMessage = error['message']?.toString() ?? '';
    final data = error['data'];
    final dataMessage = data is Map<String, dynamic>
        ? data['message']?.toString() ?? ''
        : data?.toString() ?? '';
    final combined = '$errorMessage\n$dataMessage';

    if (!combined.toLowerCase().contains('auth')) {
      return const <AcpAuthMethod>[];
    }

    final command = _extractBacktickCommand(dataMessage) ??
        _extractBacktickCommand(errorMessage) ??
        _extractQuotedCommand(dataMessage) ??
        _extractQuotedCommand(errorMessage);
    final methodId = _extractAuthenticateMethodId(dataMessage) ??
        _extractAuthenticateMethodId(errorMessage);
    if ((command == null || command.isEmpty) && methodId == null) {
      return const <AcpAuthMethod>[];
    }

    return <AcpAuthMethod>[
      AcpAuthMethod(
        id: methodId ?? 'terminal-auth',
        name: 'Terminal authentication',
        description: dataMessage.isNotEmpty ? dataMessage : errorMessage,
        type: 'terminal',
        command: command ?? const <String>[],
        authenticateMethodId: methodId,
      ),
    ];
  }

  static List<String>? _extractBacktickCommand(String value) {
    final match = RegExp('`([^`]+)`').firstMatch(value);
    final command = match?.group(1)?.trim();
    if (command == null || command.isEmpty) return null;
    return command.split(RegExp(r'\s+'));
  }

  static List<String>? _extractQuotedCommand(String value) {
    final match = RegExp("'([^']+)'").firstMatch(value);
    final command = match?.group(1)?.trim();
    if (command == null || command.isEmpty) return null;
    return command.split(RegExp(r'\s+'));
  }

  static String? _extractAuthenticateMethodId(String value) {
    final match = RegExp(r"methodId\s+'([^']+)'").firstMatch(value);
    return match?.group(1)?.trim();
  }
}

class AcpAuthenticationRequiredException extends AcpException {
  AcpAuthenticationRequiredException(
    this.authMethods, {
    String? details,
  }) : super(_formatAuthMessage(authMethods), details: details);

  final List<AcpAuthMethod> authMethods;

  static String _formatAuthMessage(List<AcpAuthMethod> authMethods) {
    final buffer = StringBuffer()
      ..writeln('Authentication required for this ACP agent.')
      ..writeln('Authenticate the agent, then run GitWhisper again.')
      ..writeln()
      ..writeln('Available auth methods:');

    for (final method in authMethods) {
      final label = method.name.isNotEmpty ? method.name : method.id;

      buffer.write('- $label');
      if (method.type.isNotEmpty) buffer.write(' (${method.type})');
      if (method.description.isNotEmpty) {
        buffer.write(': ${method.description}');
      } else if (method.args.isNotEmpty) {
        buffer.write(
          ': run the agent auth command with `${method.args.join(' ')}`',
        );
      }
      buffer.writeln();

      if (method.environment.isNotEmpty) {
        buffer.writeln(
          '  Required environment: ${method.environment.keys.join(', ')}',
        );
      }
    }

    return buffer.toString().trimRight();
  }
}

class AcpAuthMethod {
  const AcpAuthMethod({
    required this.id,
    required this.name,
    required this.description,
    required this.type,
    this.args = const <String>[],
    this.command = const <String>[],
    this.authenticateMethodId,
    this.environment = const <String, String>{},
  });

  factory AcpAuthMethod.fromJson(Map<String, dynamic> json) {
    final args = json['args'];
    final env = json['env'];
    final meta = json['_meta'];
    final terminalAuth =
        meta is Map<String, dynamic> ? meta['terminal-auth'] : null;
    final terminalAuthMap =
        terminalAuth is Map<String, dynamic> ? terminalAuth : null;
    final terminalCommand = terminalAuthMap?['command'];
    final terminalArgs = terminalAuthMap?['args'];
    final terminalEnv = terminalAuthMap?['env'];
    return AcpAuthMethod(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      type: terminalAuthMap?['type']?.toString() ??
          json['type']?.toString() ??
          'agent',
      args: args is List<dynamic>
          ? args.map((arg) => arg.toString()).toList()
          : const <String>[],
      command: terminalCommand == null
          ? const <String>[]
          : <String>[
              terminalCommand.toString(),
              if (terminalArgs is List<dynamic>)
                ...terminalArgs.map((arg) => arg.toString()),
            ],
      environment: terminalEnv is Map<dynamic, dynamic>
          ? terminalEnv.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : env is Map<dynamic, dynamic>
              ? env.map(
                  (key, value) => MapEntry(key.toString(), value.toString()),
                )
              : const <String, String>{},
    );
  }

  final String id;
  final String name;
  final String description;
  final String type;
  final List<String> args;
  final List<String> command;
  final String? authenticateMethodId;
  final Map<String, String> environment;

  bool get isTerminal => type == 'terminal';

  bool get isAgent => type == 'agent' || type.isEmpty;
}

class AcpClient {
  AcpClient({
    required this.executable,
    required this.arguments,
    this.environment,
    this.workingDirectory,
    this.mcpServers = const <Map<String, dynamic>>[],
    this.logFile,
    this.timeout = const Duration(minutes: 5),
    AcpProcessStarter? startProcess,
  }) : _startProcess = startProcess ?? Process.start;

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
  final String? workingDirectory;
  final List<Map<String, dynamic>> mcpServers;
  final File? logFile;
  final Duration timeout;
  final AcpProcessStarter _startProcess;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  Future<String>? _stderrFuture;
  IOSink? _logSink;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _agentText = StringBuffer();
  List<AcpAuthMethod> _authMethods = const <AcpAuthMethod>[];
  var _nextId = 0;

  Future<String> prompt({
    required String cwd,
    required String text,
    List<String> retryPrompts = const <String>[],
    AcpRetryPredicate? shouldRetry,
  }) async {
    await _start();

    try {
      await _initialize();

      final session = await _request(
        'session/new',
        <String, dynamic>{
          'cwd': cwd,
          'mcpServers': mcpServers,
        },
      );

      final result = session['result'];
      final sessionId = result is Map<String, dynamic>
          ? result['sessionId']?.toString()
          : null;
      if (sessionId == null || sessionId.isEmpty) {
        throw const AcpException('ACP agent did not return a sessionId.');
      }

      final prompts = <String>[text, ...retryPrompts];
      for (var index = 0; index < prompts.length; index++) {
        _agentText.clear();
        await _request(
          'session/prompt',
          <String, dynamic>{
            'sessionId': sessionId,
            'prompt': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': prompts[index]},
            ],
          },
        );

        final agentText = _agentText.toString().trim();
        _log('final_agent_text', agentText);
        if (shouldRetry == null || !shouldRetry(agentText, index)) {
          return agentText;
        }
        _log('retry_prompt', 'ACP agent response did not pass validation.');
      }

      return _agentText.toString().trim();
    } finally {
      await close();
    }
  }

  Future<void> authenticate({required String methodId}) async {
    await _start();

    try {
      await _initialize();
      await _request(
        'authenticate',
        <String, dynamic>{'methodId': methodId},
      );
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    final process = _process;
    _process = null;
    if (process != null) {
      try {
        await process.stdin.close();
      } on Object {
        // Process may already be gone.
      }

      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill();
      }
    }

    await _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    await _logSink?.flush();
    await _logSink?.close();
    _logSink = null;
  }

  Future<void> _start() async {
    await _openLog();
    _log(
      'start',
      jsonEncode(<String, dynamic>{
        'executable': executable,
        'arguments': arguments,
        'workingDirectory': workingDirectory,
      }),
    );
    try {
      final process = await _startProcess(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      _process = process;
      _stderrFuture = utf8.decodeStream(process.stderr).then((stderr) {
        if (stderr.trim().isNotEmpty) _log('stderr', stderr);
        return stderr;
      });
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine, onError: _failPending);
    } on ProcessException catch (error) {
      throw ProcessException(
        executable,
        arguments,
        'ACP agent launcher was not found or could not start.\n'
        '${error.message}',
        error.errorCode,
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });

    return completer.future.timeout(
      timeout,
      onTimeout: () async {
        final stderr = await _stderrFuture?.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => '',
        );
        throw AcpException(
          'ACP request "$method" timed out.'
          '${stderr == null || stderr.trim().isEmpty ? '' : '\n$stderr'}',
        );
      },
    );
  }

  Future<void> _initialize() {
    return _request(
      'initialize',
      <String, dynamic>{
        'protocolVersion': 1,
        'clientCapabilities': <String, dynamic>{
          'auth': <String, dynamic>{'terminal': true},
        },
        'clientInfo': <String, dynamic>{
          'name': 'gitwhisper',
          'title': 'GitWhisper',
          'version': '1.0.0',
        },
      },
    );
  }

  void _send(Map<String, dynamic> message) {
    final process = _process;
    if (process == null) {
      throw const AcpException('ACP process is not running.');
    }
    final encoded = jsonEncode(message);
    _log('send', encoded);
    process.stdin.writeln(encoded);
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    _log('receive', line);

    final decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) return;

    if (decoded.containsKey('id') && !decoded.containsKey('method')) {
      final id = decoded['id'];
      if (id is int) {
        final completer = _pending.remove(id);
        if (completer != null && !completer.isCompleted) {
          if (decoded['error'] != null) {
            final error = AcpException.fromJsonRpcError(decoded['error']);
            if (error is! AcpAuthenticationRequiredException &&
                _looksLikeAuthError(decoded['error']) &&
                _authMethods.isNotEmpty) {
              completer.completeError(
                AcpAuthenticationRequiredException(_authMethods),
              );
            } else {
              completer.completeError(error);
            }
          } else {
            if (_isInitializeResponse(id)) {
              _authMethods = _authMethodsFromResponse(decoded);
            }
            completer.complete(decoded);
          }
        }
      }
      return;
    }

    final method = decoded['method'];
    if (method == 'session/update') {
      _handleSessionUpdate(decoded['params']);
      return;
    }

    if (decoded.containsKey('id') && method == 'session/request_permission') {
      _handlePermissionRequest(decoded['id'], decoded['params']);
      return;
    }

    if (decoded.containsKey('id') && method is String) {
      _log('unsupported_method', method);
      _send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': decoded['id'],
        'error': <String, dynamic>{
          'code': -32601,
          'message': 'GitWhisper ACP client does not support "$method".',
        },
      });
    }
  }

  bool _isInitializeResponse(int id) => id == 0;

  void _handlePermissionRequest(Object? id, Object? params) {
    final paramsMap = params is Map<String, dynamic> ? params : null;
    final toolCall = paramsMap?['toolCall'];
    final toolCallMap = toolCall is Map<String, dynamic> ? toolCall : null;
    final title = toolCallMap?['title']?.toString() ?? '';
    final kind = toolCallMap?['kind']?.toString() ?? '';
    final content = toolCallMap?['content']?.toString() ?? '';
    final isGitWhisperTool = title.contains('gitwhisper') ||
        kind.contains('gitwhisper') ||
        content.contains('gitwhisper');
    final options = paramsMap?['options'];
    final optionMaps = options is List<dynamic>
        ? options.whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];

    final selectedOption = isGitWhisperTool
        ? _permissionOption(optionMaps, 'allow_once') ??
            _permissionOptionById(optionMaps, 'allow-once') ??
            _permissionOption(optionMaps, 'allow_always')
        : _permissionOption(optionMaps, 'reject_once') ??
            _permissionOptionById(optionMaps, 'reject-once');

    final optionId = selectedOption?['optionId']?.toString();
    final outcome = optionId == null || optionId.isEmpty
        ? <String, dynamic>{'outcome': 'cancelled'}
        : <String, dynamic>{'outcome': 'selected', 'optionId': optionId};

    _log(
      'permission_request',
      jsonEncode(<String, dynamic>{
        'title': title,
        'kind': kind,
        'isGitWhisperTool': isGitWhisperTool,
        'outcome': outcome,
      }),
    );
    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, dynamic>{'outcome': outcome},
    });
  }

  Map<String, dynamic>? _permissionOption(
    List<Map<String, dynamic>> options,
    String kind,
  ) {
    for (final option in options) {
      if (option['kind']?.toString() == kind) return option;
    }
    return null;
  }

  Map<String, dynamic>? _permissionOptionById(
    List<Map<String, dynamic>> options,
    String optionId,
  ) {
    for (final option in options) {
      if (option['optionId']?.toString() == optionId) return option;
    }
    return null;
  }

  bool _looksLikeAuthError(Object? error) {
    return error.toString().toLowerCase().contains('auth');
  }

  List<AcpAuthMethod> _authMethodsFromResponse(Map<String, dynamic> response) {
    final result = response['result'];
    if (result is! Map<String, dynamic>) return const <AcpAuthMethod>[];
    final rawAuthMethods = result['authMethods'];
    if (rawAuthMethods is! List) return const <AcpAuthMethod>[];
    return rawAuthMethods
        .whereType<Map<String, dynamic>>()
        .map(AcpAuthMethod.fromJson)
        .where((method) => method.id.isNotEmpty)
        .toList();
  }

  void _handleSessionUpdate(Object? params) {
    if (params is! Map<String, dynamic>) return;
    final update = params['update'];
    if (update is! Map<String, dynamic>) return;

    if (update['sessionUpdate'] != 'agent_message_chunk') return;
    _appendText(update['content']);
  }

  void _appendText(Object? content) {
    if (content is Map<String, dynamic>) {
      final text = content['text'];
      if (text is String) {
        _log('agent_message_chunk', text);
        _agentText.write(text);
      }
      final nested = content['content'];
      if (nested != null) _appendText(nested);
    } else if (content is List<dynamic>) {
      for (final item in content) {
        _appendText(item);
      }
    }
  }

  void _failPending(Object error) {
    _log('pending_error', error.toString());
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _openLog() async {
    final file = logFile;
    if (file == null || _logSink != null) return;
    await file.parent.create(recursive: true);
    _logSink = file.openWrite(mode: FileMode.append);
  }

  void _log(String event, String message) {
    final sink = _logSink;
    if (sink == null) return;
    sink.writeln(
      jsonEncode(<String, dynamic>{
        'time': DateTime.now().toIso8601String(),
        'event': event,
        'message': message,
      }),
    );
  }
}

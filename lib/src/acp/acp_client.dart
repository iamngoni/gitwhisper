import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef AcpProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

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
        'Configure that agent/provider and retry. For VTCode, run '
        '`vtcode auth` or set the provider API key it is configured to use '
        '(its default is OPENAI_API_KEY unless you change provider/config).',
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
        _extractBacktickCommand(errorMessage);
    if (command == null || command.isEmpty) {
      return const <AcpAuthMethod>[];
    }

    return <AcpAuthMethod>[
      AcpAuthMethod(
        id: 'terminal-auth',
        name: 'Terminal authentication',
        description: dataMessage.isNotEmpty ? dataMessage : errorMessage,
        type: 'terminal',
        command: command,
      ),
    ];
  }

  static List<String>? _extractBacktickCommand(String value) {
    final match = RegExp('`([^`]+)`').firstMatch(value);
    final command = match?.group(1)?.trim();
    if (command == null || command.isEmpty) return null;
    return command.split(RegExp(r'\s+'));
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
    this.environment = const <String, String>{},
  });

  factory AcpAuthMethod.fromJson(Map<String, dynamic> json) {
    final args = json['args'];
    final env = json['env'];
    return AcpAuthMethod(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      type: json['type']?.toString() ?? 'agent',
      args: args is List<dynamic>
          ? args.map((arg) => arg.toString()).toList()
          : const <String>[],
      environment: env is Map<dynamic, dynamic>
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
    this.timeout = const Duration(minutes: 5),
    AcpProcessStarter? startProcess,
  }) : _startProcess = startProcess ?? Process.start;

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
  final String? workingDirectory;
  final Duration timeout;
  final AcpProcessStarter _startProcess;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  Future<String>? _stderrFuture;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _agentText = StringBuffer();
  var _nextId = 0;

  Future<String> prompt({
    required String cwd,
    required String text,
  }) async {
    await _start();

    try {
      await _initialize();

      final session = await _request(
        'session/new',
        <String, dynamic>{
          'cwd': cwd,
          'mcpServers': <Map<String, dynamic>>[],
        },
      );

      final result = session['result'];
      final sessionId = result is Map<String, dynamic>
          ? result['sessionId']?.toString()
          : null;
      if (sessionId == null || sessionId.isEmpty) {
        throw const AcpException('ACP agent did not return a sessionId.');
      }

      await _request(
        'session/prompt',
        <String, dynamic>{
          'sessionId': sessionId,
          'prompt': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': text},
          ],
        },
      );

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
  }

  Future<void> _start() async {
    try {
      final process = await _startProcess(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      _process = process;
      _stderrFuture = utf8.decodeStream(process.stderr);
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
    process.stdin.writeln(jsonEncode(message));
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;

    final decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) return;

    if (decoded.containsKey('id') && !decoded.containsKey('method')) {
      final id = decoded['id'];
      if (id is int) {
        final completer = _pending.remove(id);
        if (completer != null && !completer.isCompleted) {
          if (decoded['error'] != null) {
            completer.completeError(
              AcpException.fromJsonRpcError(decoded['error']),
            );
          } else {
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

    if (decoded.containsKey('id') && method is String) {
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
      if (text is String) _agentText.write(text);
      final nested = content['content'];
      if (nested != null) _appendText(nested);
    } else if (content is List<dynamic>) {
      for (final item in content) {
        _appendText(item);
      }
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}

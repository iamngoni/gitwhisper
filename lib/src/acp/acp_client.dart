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
  const AcpException(this.message);

  final String message;

  @override
  String toString() => message;
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
      await _request(
        'initialize',
        <String, dynamic>{
          'protocolVersion': 1,
          'clientCapabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{
            'name': 'gitwhisper',
            'title': 'GitWhisper',
            'version': '1.0.0',
          },
        },
      );

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
            completer.completeError(AcpException(decoded['error'].toString()));
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

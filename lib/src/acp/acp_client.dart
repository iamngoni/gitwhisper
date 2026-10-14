import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../private_files.dart';
import 'acp_permission_policy.dart';

typedef AcpProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

typedef AcpRetryPredicate = bool Function(String text, int turn);

/// Callback invoked when the agent reports tool activity during a prompt, so
/// the UI can show live progress instead of a silent wait.
typedef AcpActivityCallback = void Function(AcpToolActivity activity);

/// Callback invoked for ACP lifecycle milestones before tool activity starts.
typedef AcpStatusCallback = void Function(AcpStatusEvent status);

enum AcpStatusPhase { started, completed, failed }

class AcpStatusEvent {
  const AcpStatusEvent({
    required this.title,
    required this.phase,
    this.elapsed,
  });

  const AcpStatusEvent.started(String title)
      : this(title: title, phase: AcpStatusPhase.started);

  const AcpStatusEvent.completed(String title, Duration elapsed)
      : this(
          title: title,
          phase: AcpStatusPhase.completed,
          elapsed: elapsed,
        );

  const AcpStatusEvent.failed(String title, Duration elapsed)
      : this(title: title, phase: AcpStatusPhase.failed, elapsed: elapsed);

  final String title;
  final AcpStatusPhase phase;
  final Duration? elapsed;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'title': title,
      'phase': phase.name,
      if (elapsed != null) 'elapsedMs': elapsed!.inMilliseconds,
    };
  }
}

/// A single tool call reported by the agent through `session/update`.
class AcpToolActivity {
  const AcpToolActivity({
    required this.title,
    this.path,
    this.hunkIndex,
    this.kind,
    this.status,
  });

  final String title;

  /// File the tool acted on, when the agent reports one. Different agents place
  /// arguments differently (`rawInput.path` vs `rawInput.arguments.path`), so
  /// this is normalized by [AcpClient].
  final String? path;
  final int? hunkIndex;
  final String? kind;
  final String? status;
}

class _ToolCallActivityState {
  String? title;
  String? path;
  int? hunkIndex;
  bool emitted = false;

  /// Agent-assigned facts about the call, kept for permission decisions.
  final kinds = <String>{};
  final toolNames = <String>{};
}

class _AcpTimedStatus {
  _AcpTimedStatus(this.title) : stopwatch = Stopwatch()..start();

  final String title;
  final Stopwatch stopwatch;
  bool finished = false;
}

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
    Duration? initializeTimeout,
    this.onActivity,
    this.onStatus,
    AcpProcessStarter? startProcess,
    AcpToolPermissionPolicy? permissionPolicy,
  })  : initializeTimeout = initializeTimeout ?? const Duration(minutes: 2),
        _startProcess = startProcess ?? Process.start,
        _permissionPolicy =
            permissionPolicy ?? AcpToolPermissionPolicy.gitWhisper();

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
  final String? workingDirectory;
  final List<Map<String, dynamic>> mcpServers;

  /// Optional debug log. It records the shape of the JSON-RPC traffic
  /// (methods, ids, sizes), never prompt or tool content.
  final File? logFile;
  final Duration timeout;

  /// Shorter timeout for the `initialize` handshake so a stuck launch (first
  /// run download, missing auth) fails fast with a clear message instead of
  /// hanging for the full [timeout].
  final Duration initializeTimeout;

  /// Optional live activity callback for agent tool calls.
  final AcpActivityCallback? onActivity;

  /// Optional callback for process/session milestones.
  final AcpStatusCallback? onStatus;

  final AcpProcessStarter _startProcess;
  final AcpToolPermissionPolicy _permissionPolicy;

  /// Session mode ids agents use for a read-only session (codex-acp uses
  /// `read-only`). GitWhisper switches to one when the agent offers it, so
  /// the agent cannot edit files even if it tries.
  static const _readOnlyModeIds = <String>[
    'read-only',
    'readonly',
    'read_only',
  ];

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  Future<String>? _stderrFuture;
  IOSink? _logSink;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _agentText = StringBuffer();
  final _toolCalls = <String, _ToolCallActivityState>{};
  List<AcpAuthMethod> _authMethods = const <AcpAuthMethod>[];
  _AcpTimedStatus? _promptWaitStatus;
  var _nextId = 0;

  Future<String> prompt({
    required String cwd,
    required String text,
    List<String> retryPrompts = const <String>[],
    AcpRetryPredicate? shouldRetry,
  }) async {
    await _withStatus('Launching ACP process', _start);

    try {
      await _withStatus('Initializing ACP agent', _initialize);

      final session = await _withStatus(
        'Starting ACP session',
        () => _request(
          'session/new',
          <String, dynamic>{
            'cwd': cwd,
            'mcpServers': mcpServers,
          },
        ),
      );

      final result = session['result'];
      final sessionId = result is Map<String, dynamic>
          ? result['sessionId']?.toString()
          : null;
      if (sessionId == null || sessionId.isEmpty) {
        throw const AcpException('ACP agent did not return a sessionId.');
      }

      await _preferReadOnlyMode(sessionId, result as Map<String, dynamic>);

      final prompts = <String>[text, ...retryPrompts];
      for (var index = 0; index < prompts.length; index++) {
        _agentText.clear();
        final promptStatus = _startStatus(
          index == 0
              ? 'Waiting for ACP agent to inspect staged changes'
              : 'Asking ACP agent for the final commit message',
        );
        _promptWaitStatus = promptStatus;
        try {
          await _request(
            'session/prompt',
            <String, dynamic>{
              'sessionId': sessionId,
              'prompt': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': prompts[index]},
              ],
            },
          );
          _completeStatus(promptStatus);
        } catch (_) {
          _failStatus(promptStatus);
          rethrow;
        } finally {
          if (identical(_promptWaitStatus, promptStatus)) {
            _promptWaitStatus = null;
          }
        }

        final agentText = _agentText.toString().trim();
        _log('final_agent_text', '${agentText.length} characters');
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
    await _withStatus('Launching ACP process', _start);

    try {
      await _withStatus('Initializing ACP agent', _initialize);
      await _withStatus(
        'Running ACP authentication',
        () => _request(
          'authenticate',
          <String, dynamic>{'methodId': methodId},
        ),
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
        // dart:async's TimeoutException, thrown by Future.timeout. This file
        // does not import GitWhisper's API exceptions (whose timeout type is
        // ApiTimeoutException), so the name cannot be shadowed here.
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
      <String, dynamic>{
        'executable': executable,
        'arguments': arguments,
        'workingDirectory': workingDirectory,
      },
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
        // Agents can echo prompts or file content to stderr; log its size.
        if (stderr.trim().isNotEmpty) {
          _log('stderr', '${stderr.length} characters');
        }
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
    Map<String, dynamic> params, {
    Duration? timeoutOverride,
    String? timeoutHint,
  }) async {
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
      timeoutOverride ?? timeout,
      onTimeout: () async {
        final stderr = await _stderrFuture?.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => '',
        );
        final hint = timeoutHint == null ? '' : '\n$timeoutHint';
        throw AcpException(
          'ACP request "$method" timed out.$hint'
          '${stderr == null || stderr.trim().isEmpty ? '' : '\n$stderr'}',
        );
      },
    );
  }

  /// Switches the session to a read-only mode when the agent advertises one.
  ///
  /// Best effort: agents without modes, or that reject the switch, keep their
  /// default mode, and GitWhisper's permission policy still rejects any edit
  /// or command the agent asks to run.
  Future<void> _preferReadOnlyMode(
    String sessionId,
    Map<String, dynamic> session,
  ) async {
    final modes = session['modes'];
    if (modes is! Map<String, dynamic>) return;
    final availableModes = modes['availableModes'];
    if (availableModes is! List<dynamic>) return;

    final availableIds = availableModes
        .whereType<Map<String, dynamic>>()
        .map((mode) => mode['id']?.toString())
        .whereType<String>()
        .toSet();
    String? modeId;
    for (final candidate in _readOnlyModeIds) {
      if (availableIds.contains(candidate)) {
        modeId = candidate;
        break;
      }
    }
    if (modeId == null || modes['currentModeId'] == modeId) return;

    try {
      await _request(
        'session/set_mode',
        <String, dynamic>{'sessionId': sessionId, 'modeId': modeId},
        timeoutOverride: initializeTimeout,
      );
      _log('session_mode', modeId);
    } on AcpException catch (error) {
      _log('session_mode_failed', '$modeId: ${error.runtimeType}');
    }
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
      timeoutOverride: initializeTimeout,
      timeoutHint:
          'The agent did not start in time. On first run it may still be '
          'downloading, or it may need authentication. Try running the agent '
          'directly once to finish setup, then retry.',
    );
  }

  void _send(Map<String, dynamic> message) {
    final process = _process;
    if (process == null) {
      throw const AcpException('ACP process is not running.');
    }
    final encoded = jsonEncode(message);
    _logMessage('send', message, encoded.length);
    process.stdin.writeln(encoded);
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Some agents print plain log lines on stdout; they are not ACP.
      _log('receive_unparsed', '${line.length} characters');
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    _logMessage('receive', decoded, line.length);

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

  /// Answers `session/request_permission`.
  ///
  /// Only GitWhisper's own read-only MCP tools are approved, and only for
  /// this one call (`allow_once`, never `allow_always`, which some agents
  /// persist). Everything else (shell commands, edits, fetches, other MCP
  /// servers) is rejected with `reject_once`.
  void _handlePermissionRequest(Object? id, Object? params) {
    final paramsMap = params is Map<String, dynamic> ? params : null;
    final toolCall = paramsMap?['toolCall'];
    final toolCallMap = toolCall is Map<String, dynamic> ? toolCall : null;
    final toolCallId = toolCallMap?['toolCallId']?.toString();
    final tracked = toolCallId == null ? null : _toolCalls[toolCallId];

    final title = toolCallMap?['title'];
    final kind = toolCallMap?['kind'];
    final metaToolName = _metaToolName(toolCallMap);
    final subject = AcpPermissionSubject(
      titles: <String>[if (title is String) title],
      toolNames: <String>{
        if (metaToolName != null) metaToolName,
        ...?tracked?.toolNames,
      }.toList(),
      kinds: <String>{
        if (kind is String && kind.isNotEmpty) kind,
        ...?tracked?.kinds,
      }.toList(),
    );
    final approvedTool = _permissionPolicy.approvedToolName(subject);

    final options = paramsMap?['options'];
    final optionMaps = options is List<dynamic>
        ? options.whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];
    final rejectOption =
        _permissionOption(optionMaps, kind: 'reject_once', id: 'reject-once');
    // Without an allow-once option, reject rather than pick allow_always.
    final selectedOption = approvedTool != null
        ? _permissionOption(optionMaps, kind: 'allow_once', id: 'allow-once') ??
            rejectOption
        : rejectOption;

    final optionId = selectedOption?['optionId']?.toString();
    final outcome = optionId == null || optionId.isEmpty
        ? <String, dynamic>{'outcome': 'cancelled'}
        : <String, dynamic>{'outcome': 'selected', 'optionId': optionId};

    _log(
      'permission_request',
      <String, dynamic>{
        'toolCallId': toolCallId,
        'kinds': subject.kinds,
        'approvedTool': approvedTool,
        'outcome': outcome,
      },
    );
    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, dynamic>{'outcome': outcome},
    });
  }

  /// Finds the permission option with [kind], or, for agents that omit
  /// option kinds, the conventional option [id].
  Map<String, dynamic>? _permissionOption(
    List<Map<String, dynamic>> options, {
    required String kind,
    required String id,
  }) {
    for (final option in options) {
      if (option['kind']?.toString() == kind) return option;
    }
    for (final option in options) {
      if (option['kind'] == null && option['optionId']?.toString() == id) {
        return option;
      }
    }
    return null;
  }

  /// Tool name Claude Code adapters attach as `_meta.claudeCode.toolName`.
  static String? _metaToolName(Map<String, dynamic>? toolCall) {
    final meta = toolCall?['_meta'];
    if (meta is! Map<String, dynamic>) return null;
    final claudeCode = meta['claudeCode'];
    if (claudeCode is! Map<String, dynamic>) return null;
    final toolName = claudeCode['toolName'];
    return toolName is String && toolName.isNotEmpty ? toolName : null;
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

    final kind = update['sessionUpdate'];
    if (kind == 'agent_message_chunk') {
      _appendText(update['content']);
      return;
    }

    if (kind == 'tool_call' || kind == 'tool_call_update') {
      _reportToolActivity(update);
    }
  }

  void _reportToolActivity(Map<String, dynamic> update) {
    final id = update['toolCallId']?.toString();
    if (id == null || id.isEmpty) return;

    // A single tool call is reported across several messages: the initial
    // `tool_call` then one or more `tool_call_update`s. Some agents (codex)
    // include the file path up front; others (claude) only send it in a later
    // update. Accumulate fields and emit exactly once — as soon as a path is
    // known, or when the call finishes if it never carries one.
    final state = _toolCalls.putIfAbsent(id, _ToolCallActivityState.new);
    final kind = update['kind'];
    if (kind is String && kind.isNotEmpty) state.kinds.add(kind);
    final metaToolName = _metaToolName(update);
    if (metaToolName != null) state.toolNames.add(metaToolName);
    if (state.emitted) return;

    final title = update['title']?.toString();
    if (title != null && title.trim().isNotEmpty) state.title = title.trim();

    final rawInput = update['rawInput'];
    state.path ??= _activityString(rawInput, 'path');
    state.hunkIndex ??= _activityInt(rawInput, 'hunkIndex');

    if (state.title == null) return;

    final status = update['status']?.toString();
    final terminal =
        status == 'completed' || status == 'failed' || status == 'cancelled';
    if (state.path == null && !terminal) return;

    state.emitted = true;
    _completePromptWaitStatus();

    final callback = onActivity;
    if (callback == null) return;

    callback(
      AcpToolActivity(
        title: state.title!,
        path: state.path,
        hunkIndex: state.hunkIndex,
        kind: update['kind']?.toString(),
        status: status,
      ),
    );
  }

  static String? _activityString(Object? rawInput, String key) {
    if (rawInput is! Map) return null;
    final direct = rawInput[key];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    final args = rawInput['arguments'];
    if (args is Map) {
      final nested = args[key];
      if (nested is String && nested.trim().isNotEmpty) return nested.trim();
    }
    return null;
  }

  static int? _activityInt(Object? rawInput, String key) {
    if (rawInput is! Map) return null;
    var value = rawInput[key];
    if (value == null && rawInput['arguments'] is Map) {
      value = (rawInput['arguments'] as Map)[key];
    }
    if (value is int) return value;
    return int.tryParse('${value ?? ''}');
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

  Future<T> _withStatus<T>(
    String title,
    Future<T> Function() action,
  ) async {
    final status = _startStatus(title);
    try {
      final result = await action();
      _completeStatus(status);
      return result;
    } catch (_) {
      _failStatus(status);
      rethrow;
    }
  }

  _AcpTimedStatus _startStatus(String title) {
    final status = _AcpTimedStatus(title);
    _reportStatus(AcpStatusEvent.started(title));
    return status;
  }

  void _completePromptWaitStatus() {
    final status = _promptWaitStatus;
    if (status == null) return;
    _completeStatus(status);
    _promptWaitStatus = null;
  }

  void _completeStatus(_AcpTimedStatus status) {
    if (status.finished) return;
    status
      ..finished = true
      ..stopwatch.stop();
    _reportStatus(
      AcpStatusEvent.completed(status.title, status.stopwatch.elapsed),
    );
  }

  void _failStatus(_AcpTimedStatus status) {
    if (status.finished) return;
    status
      ..finished = true
      ..stopwatch.stop();
    _reportStatus(
      AcpStatusEvent.failed(status.title, status.stopwatch.elapsed),
    );
  }

  void _reportStatus(AcpStatusEvent status) {
    final callback = onStatus;
    if (callback != null) callback(status);
    _log('status', status.toJson());
  }

  void _failPending(Object error) {
    // Error text (for example a FormatException) can quote agent output.
    _log('pending_error', error.runtimeType.toString());
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _openLog() async {
    final file = logFile;
    if (file == null || _logSink != null) return;
    // Logs live in an owner-only directory as owner-only files.
    await ensurePrivateDirectory(file.parent);
    if (!file.existsSync()) await createPrivateFile(file);
    _logSink = file.openWrite(mode: FileMode.append);
  }

  /// Logs one JSON-RPC message by its shape only: direction, method, id,
  /// size, and a few protocol fields. Prompts carry staged diffs and tool
  /// results carry file content, so message bodies are never written.
  void _logMessage(String event, Map<String, dynamic> message, int bytes) {
    if (_logSink == null) return;
    final summary = <String, dynamic>{'bytes': bytes};
    final method = message['method'];
    if (method is String) summary['method'] = method;
    if (message.containsKey('id')) summary['id'] = message['id'];

    final error = message['error'];
    if (error is Map<String, dynamic>) summary['errorCode'] = error['code'];

    final result = message['result'];
    if (result is Map<String, dynamic> && result['stopReason'] is String) {
      summary['stopReason'] = result['stopReason'];
    }

    final params = message['params'];
    final update = params is Map<String, dynamic> ? params['update'] : null;
    if (method == 'session/update' && update is Map<String, dynamic>) {
      for (final key in const <String>[
        'sessionUpdate',
        'toolCallId',
        'kind',
        'status',
      ]) {
        final value = update[key];
        if (value is String) summary[key] = value;
      }
    }

    _log(event, summary);
  }

  void _log(String event, Object message) {
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

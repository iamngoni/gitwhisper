import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../agent/git_agent_tools.dart';
import '../version.dart';

class GitToolsMcpServer {
  GitToolsMcpServer({
    required String cwd,
    Stream<List<int>>? input,
    StringSink? output,
  })  : _tools = GitAgentTools(
          folderPath: cwd,
          onToolUse: (_) {},
        ),
        _input = input ?? stdin,
        _output = output ?? stdout;

  final GitAgentTools _tools;
  final Stream<List<int>> _input;
  final StringSink _output;

  Future<void> serve() async {
    await for (final line
        in _input.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      await _handleLine(line);
    }
  }

  Future<void> _handleLine(String line) async {
    Object? id;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;

      id = decoded['id'];
      final method = decoded['method']?.toString();
      final params = decoded['params'];

      if (id == null) return;

      switch (method) {
        case 'initialize':
          _writeResult(id, _initializeResult(params));
        case 'ping':
          _writeResult(id, <String, dynamic>{});
        case 'tools/list':
          _writeResult(id, <String, dynamic>{
            'tools': GitAgentTools.mcpToolDefinitions,
          });
        case 'tools/call':
          _writeResult(id, await _callTool(params));
        case 'resources/list':
          _writeResult(id, <String, dynamic>{'resources': <dynamic>[]});
        case 'prompts/list':
          _writeResult(id, <String, dynamic>{'prompts': <dynamic>[]});
        default:
          _writeError(id, -32601, 'Method not found: $method');
      }
    } on Object catch (error) {
      if (id != null) {
        _writeError(id, -32603, error.toString());
      }
    }
  }

  Map<String, dynamic> _initializeResult(Object? params) {
    final requestedVersion = params is Map<String, dynamic>
        ? params['protocolVersion']?.toString()
        : null;
    return <String, dynamic>{
      'protocolVersion': requestedVersion ?? '2025-06-18',
      'capabilities': <String, dynamic>{
        'tools': <String, dynamic>{},
      },
      'serverInfo': <String, dynamic>{
        'name': 'gitwhisper',
        'version': packageVersion,
      },
    };
  }

  Future<Map<String, dynamic>> _callTool(Object? params) async {
    if (params is! Map<String, dynamic>) {
      throw const FormatException('tools/call params must be an object.');
    }

    final name = params['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('tools/call requires a tool name.');
    }

    final arguments = params['arguments'];
    final input = arguments is Map<String, dynamic>
        ? arguments
        : arguments is Map<dynamic, dynamic>
            ? Map<String, dynamic>.from(arguments)
            : <String, dynamic>{};

    try {
      final result = await _tools.execute(name, input);
      return <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'text',
            'text': result,
          },
        ],
        'isError': false,
      };
    } on Object catch (error) {
      return <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'text',
            'text': 'ERROR: $error',
          },
        ],
        'isError': true,
      };
    }
  }

  void _writeResult(Object id, Map<String, dynamic> result) {
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
  }

  void _writeError(Object id, int code, String message) {
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, dynamic>{
        'code': code,
        'message': message,
      },
    });
  }

  void _write(Map<String, dynamic> message) {
    _output.writeln(jsonEncode(message));
  }
}

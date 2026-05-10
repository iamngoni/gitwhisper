import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

class GitAgentTools {
  const GitAgentTools({
    this.folderPath,
    this.maxOutputCharacters = 30000,
  });

  final String? folderPath;
  final int maxOutputCharacters;

  static List<Map<String, dynamic>> get openAiToolDefinitions => [
        _openAiTool(
          name: 'list_staged_files',
          description: 'List files that currently have staged changes. '
              'Returns JSON containing each staged path and its git status. '
              'Use this before requesting individual file diffs.',
          parameters: _emptyParameters(),
        ),
        _openAiTool(
          name: 'get_diff_stat',
          description: 'Return a compact git diff stat for staged changes. '
              'Use this to understand the size and spread of the staged work '
              'before deciding which file diffs to inspect.',
          parameters: _emptyParameters(),
        ),
        _openAiTool(
          name: 'get_file_diff',
          description: 'Return the staged diff for one staged file path. '
              'The path must come from list_staged_files. This tool rejects '
              'absolute paths, traversal paths, and files without staged '
              'changes.',
          parameters: _pathParameters(),
        ),
        _openAiTool(
          name: 'get_file_content',
          description: 'Return the current working-tree content for one '
              'staged file path when extra context is needed. The path must '
              'come from list_staged_files. Deleted files may not have content.',
          parameters: _pathParameters(),
        ),
      ];

  static List<Map<String, dynamic>> get claudeToolDefinitions => [
        _claudeTool(
          name: 'list_staged_files',
          description: 'List files that currently have staged changes. '
              'Returns JSON containing each staged path and its git status. '
              'Use this before requesting individual file diffs.',
          inputSchema: _emptyParameters(),
        ),
        _claudeTool(
          name: 'get_diff_stat',
          description: 'Return a compact git diff stat for staged changes. '
              'Use this to understand the size and spread of the staged work '
              'before deciding which file diffs to inspect.',
          inputSchema: _emptyParameters(),
        ),
        _claudeTool(
          name: 'get_file_diff',
          description: 'Return the staged diff for one staged file path. '
              'The path must come from list_staged_files. This tool rejects '
              'absolute paths, traversal paths, and files without staged '
              'changes.',
          inputSchema: _pathParameters(),
        ),
        _claudeTool(
          name: 'get_file_content',
          description: 'Return the current working-tree content for one '
              'staged file path when extra context is needed. The path must '
              'come from list_staged_files. Deleted files may not have content.',
          inputSchema: _pathParameters(),
        ),
      ];

  Future<String> execute(String name, Map<String, dynamic> input) async {
    return switch (name) {
      'list_staged_files' => _listStagedFiles(),
      'get_diff_stat' => _getDiffStat(),
      'get_file_diff' => _getFileDiff(input),
      'get_file_content' => _getFileContent(input),
      _ => throw ArgumentError.value(name, 'name', 'Unsupported agent tool'),
    };
  }

  Future<String> _listStagedFiles() async {
    final output = await _runGit(<String>['diff', '--cached', '--name-status']);
    final files = <Map<String, String>>[];

    for (final line in output.split('\n')) {
      if (line.trim().isEmpty) continue;

      final parts = line.split('\t');
      if (parts.length < 2) continue;

      final status = parts.first;
      if ((status.startsWith('R') || status.startsWith('C')) &&
          parts.length >= 3) {
        files.add(<String, String>{
          'status': status,
          'oldPath': parts[1],
          'path': parts[2],
        });
      } else {
        files.add(<String, String>{
          'status': status,
          'path': parts[1],
        });
      }
    }

    return jsonEncode(<String, dynamic>{'files': files});
  }

  Future<String> _getDiffStat() async {
    final output = await _runGit(<String>['diff', '--cached', '--stat']);
    return output.trim().isEmpty ? 'No staged changes.' : _truncate(output);
  }

  Future<String> _getFileDiff(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final output = await _runGit(
      <String>['diff', '--cached', '--', stagedPath],
    );
    return output.trim().isEmpty ? 'No staged diff for $stagedPath.' : _truncate(output);
  }

  Future<String> _getFileContent(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final root = path.normalize(path.absolute(folderPath ?? Directory.current.path));
    final fullPath = path.normalize(
      path.joinAll(<String>[root, ...stagedPath.split('/')]),
    );

    if (!path.equals(root, fullPath) && !path.isWithin(root, fullPath)) {
      throw ArgumentError.value(stagedPath, 'path', 'Path escapes repository');
    }

    final file = File(fullPath);
    if (!await file.exists()) {
      return 'File $stagedPath does not exist in the working tree.';
    }

    try {
      return _truncate(await file.readAsString());
    } on FormatException {
      return 'File $stagedPath is not valid UTF-8 text.';
    }
  }

  Future<String> _validateStagedPath(Map<String, dynamic> input) async {
    final rawPath = input['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) {
      throw ArgumentError.value(rawPath, 'path', 'A staged file path is required');
    }

    final normalized = _normalizeGitPath(rawPath);
    final stagedPaths = await _stagedPaths();
    if (!stagedPaths.contains(normalized)) {
      throw ArgumentError.value(
        normalized,
        'path',
        'Path does not have staged changes',
      );
    }

    return normalized;
  }

  Future<Set<String>> _stagedPaths() async {
    final output = await _runGit(
      <String>['diff', '--cached', '--name-only', '-z'],
    );
    return output
        .split('\u0000')
        .where((value) => value.trim().isNotEmpty)
        .map(_normalizeGitPath)
        .toSet();
  }

  String _normalizeGitPath(String rawPath) {
    final normalized = path.posix.normalize(rawPath.replaceAll(r'\', '/'));
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        path.posix.isAbsolute(normalized)) {
      throw ArgumentError.value(rawPath, 'path', 'Invalid staged file path');
    }

    return normalized;
  }

  Future<String> _runGit(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: folderPath,
    );

    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        args,
        result.stderr.toString(),
        result.exitCode,
      );
    }

    return result.stdout.toString();
  }

  String _truncate(String value) {
    if (value.length <= maxOutputCharacters) return value.trim();

    return '${value.substring(0, maxOutputCharacters)}\n\n'
        '[Output truncated by GitWhisper.]';
  }

  static Map<String, dynamic> _openAiTool({
    required String name,
    required String description,
    required Map<String, dynamic> parameters,
  }) {
    return <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };
  }

  static Map<String, dynamic> _claudeTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
  }) {
    return <String, dynamic>{
      'name': name,
      'description': description,
      'input_schema': inputSchema,
    };
  }

  static Map<String, dynamic> _emptyParameters() {
    return <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
      'additionalProperties': false,
    };
  }

  static Map<String, dynamic> _pathParameters() {
    return <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{
          'type': 'string',
          'description': 'A staged file path returned by list_staged_files.',
        },
      },
      'required': <String>['path'],
      'additionalProperties': false,
    };
  }
}

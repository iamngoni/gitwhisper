import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../constants.dart';

class GitAgentTools {
  const GitAgentTools({
    this.folderPath,
    this.maxOutputCharacters = 30000,
    this.onToolUse,
  });

  final String? folderPath;
  final int maxOutputCharacters;
  final void Function(String message)? onToolUse;

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
              'come from list_staged_files. Deleted files may not have '
              'content.',
          parameters: _pathParameters(),
        ),
        _openAiTool(
          name: 'get_file_diff_hunks',
          description: 'Return a compact index of staged diff hunks for one '
              'staged file path. Use this when get_file_diff says output was '
              'truncated or when only specific hunks need inspection.',
          parameters: _pathParameters(),
        ),
        _openAiTool(
          name: 'get_file_diff_hunk',
          description: 'Return one staged diff hunk by hunkIndex for one '
              'staged file path. Call get_file_diff_hunks first.',
          parameters: _hunkParameters(),
        ),
        _openAiTool(
          name: 'get_file_content_chunk',
          description: 'Return a bounded line range from the current '
              'working-tree content for one staged file path.',
          parameters: _lineRangeParameters(),
        ),
        _openAiTool(
          name: 'search_file_content',
          description: 'Search current working-tree content for a staged file '
              'path and return matching line numbers with previews.',
          parameters: _searchParameters(),
        ),
        _openAiTool(
          name: 'get_staged_file_summary',
          description: 'Return a deterministic summary of one staged file: '
              'additions, deletions, hunk count, size, and changed-line '
              'previews.',
          parameters: _pathParameters(),
        ),
        _openAiTool(
          name: 'get_related_files',
          description: 'Return tracked repository files that appear related '
              'to one staged path by basename, directory, or test naming.',
          parameters: _pathParameters(),
        ),
        _openAiTool(
          name: 'get_blame',
          description: 'Return git blame metadata for a bounded line range '
              'from one staged file path.',
          parameters: _lineRangeParameters(),
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
              'come from list_staged_files. Deleted files may not have '
              'content.',
          inputSchema: _pathParameters(),
        ),
        _claudeTool(
          name: 'get_file_diff_hunks',
          description: 'Return a compact index of staged diff hunks for one '
              'staged file path. Use this when get_file_diff says output was '
              'truncated or when only specific hunks need inspection.',
          inputSchema: _pathParameters(),
        ),
        _claudeTool(
          name: 'get_file_diff_hunk',
          description: 'Return one staged diff hunk by hunkIndex for one '
              'staged file path. Call get_file_diff_hunks first.',
          inputSchema: _hunkParameters(),
        ),
        _claudeTool(
          name: 'get_file_content_chunk',
          description: 'Return a bounded line range from the current '
              'working-tree content for one staged file path.',
          inputSchema: _lineRangeParameters(),
        ),
        _claudeTool(
          name: 'search_file_content',
          description: 'Search current working-tree content for a staged file '
              'path and return matching line numbers with previews.',
          inputSchema: _searchParameters(),
        ),
        _claudeTool(
          name: 'get_staged_file_summary',
          description: 'Return a deterministic summary of one staged file: '
              'additions, deletions, hunk count, size, and changed-line '
              'previews.',
          inputSchema: _pathParameters(),
        ),
        _claudeTool(
          name: 'get_related_files',
          description: 'Return tracked repository files that appear related '
              'to one staged path by basename, directory, or test naming.',
          inputSchema: _pathParameters(),
        ),
        _claudeTool(
          name: 'get_blame',
          description: 'Return git blame metadata for a bounded line range '
              'from one staged file path.',
          inputSchema: _lineRangeParameters(),
        ),
      ];

  Future<String> execute(String name, Map<String, dynamic> input) async {
    _logToolUse(name, input);

    return switch (name) {
      'list_staged_files' => _listStagedFiles(),
      'get_diff_stat' => _getDiffStat(),
      'get_file_diff' => _getFileDiff(input),
      'get_file_content' => _getFileContent(input),
      'get_file_diff_hunks' => _getFileDiffHunks(input),
      'get_file_diff_hunk' => _getFileDiffHunk(input),
      'get_file_content_chunk' => _getFileContentChunk(input),
      'search_file_content' => _searchFileContent(input),
      'get_staged_file_summary' => _getStagedFileSummary(input),
      'get_related_files' => _getRelatedFiles(input),
      'get_blame' => _getBlame(input),
      _ => throw ArgumentError.value(name, 'name', 'Unsupported agent tool'),
    };
  }

  void _logToolUse(String name, Map<String, dynamic> input) {
    final pathValue = input['path'];
    final toolLabel = pathValue is String && pathValue.trim().isNotEmpty
        ? '$name($pathValue)'
        : name;
    final message = 'Agent tool: $toolLabel';

    final log = onToolUse;
    if (log != null) {
      log(message);
    } else {
      $logger.info(message);
    }
  }

  Future<String> _listStagedFiles() async {
    final output = await _runGit(<String>['diff', '--cached', '--name-status']);
    final files = <Map<String, dynamic>>[];

    for (final line in output.split('\n')) {
      if (line.trim().isEmpty) continue;

      final parts = line.split('\t');
      if (parts.length < 2) continue;

      final status = parts.first;
      if ((status.startsWith('R') || status.startsWith('C')) &&
          parts.length >= 3) {
        files.add(<String, dynamic>{
          'status': status,
          'oldPath': parts[1],
          'path': parts[2],
        });
      } else {
        files.add(<String, dynamic>{
          'status': status,
          'path': parts[1],
        });
      }
    }

    for (final file in files) {
      final filePath = file['path'] as String;
      final diff = await _fileDiff(filePath);
      final stats = _diffStats(diff);
      file
        ..addAll(stats)
        ..['diffSize'] = diff.length
        ..['isBinary'] = _isBinaryDiff(diff)
        ..['isLikelyGenerated'] = _isLikelyGenerated(filePath)
        ..['isLockfile'] = _isLockfile(filePath);
    }

    return jsonEncode(<String, dynamic>{'files': files});
  }

  Future<String> _getDiffStat() async {
    final output = await _runGit(<String>['diff', '--cached', '--stat']);
    return output.trim().isEmpty ? 'No staged changes.' : _truncate(output);
  }

  Future<String> _getFileDiff(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final output = await _fileDiff(stagedPath);
    if (output.trim().isEmpty) return 'No staged diff for $stagedPath.';
    return _boundedTextJson(
      value: output,
      path: stagedPath,
      nextTools: <String>['get_file_diff_hunks', 'get_file_diff_hunk'],
    );
  }

  Future<String> _getFileContent(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final root =
        path.normalize(path.absolute(folderPath ?? Directory.current.path));
    final fullPath = path.normalize(
      path.joinAll(<String>[root, ...stagedPath.split('/')]),
    );

    if (!path.equals(root, fullPath) && !path.isWithin(root, fullPath)) {
      throw ArgumentError.value(stagedPath, 'path', 'Path escapes repository');
    }

    final file = File(fullPath);
    if (!file.existsSync()) {
      return 'File $stagedPath does not exist in the working tree.';
    }

    try {
      return _boundedTextJson(
        value: await file.readAsString(),
        path: stagedPath,
        nextTools: <String>['get_file_content_chunk', 'search_file_content'],
      );
    } on FormatException {
      return 'File $stagedPath is not valid UTF-8 text.';
    }
  }

  Future<String> _getFileDiffHunks(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final diff = await _fileDiff(stagedPath);
    final hunks = _splitDiffHunks(diff);

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'hunkCount': hunks.length,
      'hunks': [
        for (var i = 0; i < hunks.length; i++)
          <String, dynamic>{
            'index': i,
            'header': _hunkHeader(hunks[i]),
            'additions': _diffStats(hunks[i])['additions'],
            'deletions': _diffStats(hunks[i])['deletions'],
            'preview': _previewChangedLines(hunks[i], limit: 4),
          },
      ],
    });
  }

  Future<String> _getFileDiffHunk(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final hunkIndex = _readNonNegativeInt(
      input,
      'hunkIndex',
      defaultValue: 0,
    );
    final hunks = _splitDiffHunks(await _fileDiff(stagedPath));
    if (hunkIndex >= hunks.length) {
      throw ArgumentError.value(hunkIndex, 'hunkIndex', 'Hunk not found');
    }

    final hunk = hunks[hunkIndex];
    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'hunkIndex': hunkIndex,
      'truncated': hunk.length > maxOutputCharacters,
      'originalCharacters': hunk.length,
      'diff': _truncate(hunk),
    });
  }

  Future<String> _getFileContentChunk(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final lines = await _readTextFileLines(stagedPath);
    final startLine = _readPositiveInt(input, 'startLine', defaultValue: 1);
    final maxLines = _readPositiveInt(input, 'maxLines', defaultValue: 80);
    final startIndex = (startLine - 1).clamp(0, lines.length);
    final endIndex = (startIndex + maxLines).clamp(0, lines.length);

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'startLine': startIndex + 1,
      'endLine': endIndex,
      'totalLines': lines.length,
      'hasMore': endIndex < lines.length,
      'content': lines.sublist(startIndex, endIndex).join('\n'),
    });
  }

  Future<String> _searchFileContent(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final query = input['query'];
    if (query is! String || query.trim().isEmpty) {
      throw ArgumentError.value(query, 'query', 'A search query is required');
    }

    final normalizedQuery = query.toLowerCase();
    final lines = await _readTextFileLines(stagedPath);
    final matches = <Map<String, dynamic>>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().contains(normalizedQuery)) {
        matches.add(<String, dynamic>{
          'line': i + 1,
          'content': lines[i],
        });
      }
      if (matches.length >= 25) break;
    }

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'query': query,
      'matches': matches,
      'truncated': matches.length >= 25,
    });
  }

  Future<String> _getStagedFileSummary(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final diff = await _fileDiff(stagedPath);
    final stats = _diffStats(diff);
    final hunks = _splitDiffHunks(diff);

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      ...stats,
      'diffSize': diff.length,
      'hunkCount': hunks.length,
      'isBinary': _isBinaryDiff(diff),
      'isLikelyGenerated': _isLikelyGenerated(stagedPath),
      'isLockfile': _isLockfile(stagedPath),
      'previews': _previewChangedLines(diff, limit: 12),
    });
  }

  Future<String> _getRelatedFiles(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final trackedOutput = await _runGit(<String>['ls-files']);
    final trackedFiles = trackedOutput
        .split('\n')
        .where((value) => value.trim().isNotEmpty)
        .map(_normalizeGitPath)
        .toList();
    final stagedBase = path.posix.basenameWithoutExtension(stagedPath);
    final stagedDir = path.posix.dirname(stagedPath);
    final related = <String>[];

    for (final candidate in trackedFiles) {
      if (candidate == stagedPath) continue;
      final candidateBase = path.posix.basenameWithoutExtension(candidate);
      final candidateDir = path.posix.dirname(candidate);
      final sameBase = candidateBase == stagedBase ||
          candidateBase == '${stagedBase}_test' ||
          candidateBase == '${stagedBase}_spec';
      final sameDir = candidateDir == stagedDir;
      final mirrorsTest = candidate.contains('/${stagedBase}_test.');
      if (sameBase || mirrorsTest || (sameDir && related.length < 8)) {
        related.add(candidate);
      }
      if (related.length >= 25) break;
    }

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'relatedFiles': related,
    });
  }

  Future<String> _getBlame(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final startLine = _readPositiveInt(input, 'startLine', defaultValue: 1);
    final maxLines = _readPositiveInt(input, 'maxLines', defaultValue: 20);
    final endLine = startLine + maxLines - 1;
    final output = await _runGit(
      <String>['blame', '-L', '$startLine,$endLine', '--', stagedPath],
    );

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'startLine': startLine,
      'endLine': endLine,
      'lines': output
          .split('\n')
          .where((value) => value.trim().isNotEmpty)
          .take(maxLines)
          .toList(),
    });
  }

  Future<String> _validateStagedPath(Map<String, dynamic> input) async {
    final rawPath = input['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) {
      throw ArgumentError.value(
        rawPath,
        'path',
        'A staged file path is required',
      );
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

  Future<String> _fileDiff(String stagedPath) {
    return _runGit(<String>['diff', '--cached', '--', stagedPath]);
  }

  Future<List<String>> _readTextFileLines(String stagedPath) async {
    final root =
        path.normalize(path.absolute(folderPath ?? Directory.current.path));
    final fullPath = path.normalize(
      path.joinAll(<String>[root, ...stagedPath.split('/')]),
    );

    if (!path.equals(root, fullPath) && !path.isWithin(root, fullPath)) {
      throw ArgumentError.value(stagedPath, 'path', 'Path escapes repository');
    }

    final file = File(fullPath);
    if (!file.existsSync()) return <String>[];

    try {
      return (await file.readAsString()).split('\n');
    } on FormatException {
      throw ArgumentError.value(stagedPath, 'path', 'File is not UTF-8 text');
    }
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

  String _boundedTextJson({
    required String value,
    required String path,
    required List<String> nextTools,
  }) {
    if (value.length <= maxOutputCharacters) return value.trim();

    return jsonEncode(<String, dynamic>{
      'path': path,
      'truncated': true,
      'originalCharacters': value.length,
      'returnedCharacters': maxOutputCharacters,
      'content': value.substring(0, maxOutputCharacters),
      'nextTools': nextTools,
    });
  }

  Map<String, int> _diffStats(String diff) {
    var additions = 0;
    var deletions = 0;
    for (final line in diff.split('\n')) {
      if (line.startsWith('+++') || line.startsWith('---')) continue;
      if (line.startsWith('+')) additions++;
      if (line.startsWith('-')) deletions++;
    }
    return <String, int>{'additions': additions, 'deletions': deletions};
  }

  List<String> _splitDiffHunks(String diff) {
    final hunks = <String>[];
    final fileHeader = <String>[];
    final current = <String>[];
    var inHunk = false;

    for (final line in diff.split('\n')) {
      if (line.startsWith('@@')) {
        if (current.isNotEmpty) {
          hunks.add([...fileHeader, ...current].join('\n'));
          current.clear();
        }
        inHunk = true;
        current.add(line);
      } else if (inHunk) {
        current.add(line);
      } else if (line.startsWith('diff --git') ||
          line.startsWith('index ') ||
          line.startsWith('--- ') ||
          line.startsWith('+++ ')) {
        fileHeader.add(line);
      }
    }

    if (current.isNotEmpty) {
      hunks.add([...fileHeader, ...current].join('\n'));
    }
    return hunks;
  }

  String _hunkHeader(String hunk) {
    return hunk.split('\n').firstWhere(
          (line) => line.startsWith('@@'),
          orElse: () => '',
        );
  }

  List<String> _previewChangedLines(String diff, {required int limit}) {
    return diff
        .split('\n')
        .where(
          (line) =>
              (line.startsWith('+') && !line.startsWith('+++')) ||
              (line.startsWith('-') && !line.startsWith('---')),
        )
        .take(limit)
        .toList();
  }

  bool _isBinaryDiff(String diff) {
    return diff.contains('Binary files ') || diff.contains('GIT binary patch');
  }

  bool _isLockfile(String stagedPath) {
    final fileName = path.posix.basename(stagedPath).toLowerCase();
    return fileName == 'pubspec.lock' ||
        fileName == 'package-lock.json' ||
        fileName == 'yarn.lock' ||
        fileName == 'pnpm-lock.yaml' ||
        fileName == 'cargo.lock' ||
        fileName == 'gemfile.lock';
  }

  bool _isLikelyGenerated(String stagedPath) {
    final lowerPath = stagedPath.toLowerCase();
    return lowerPath.endsWith('.g.dart') ||
        lowerPath.endsWith('.freezed.dart') ||
        lowerPath.endsWith('.generated.dart') ||
        lowerPath.contains('/generated/') ||
        lowerPath.contains('/build/');
  }

  int _readPositiveInt(
    Map<String, dynamic> input,
    String key, {
    required int defaultValue,
  }) {
    final value = input[key];
    if (value == null) return defaultValue;
    final parsed = value is int ? value : int.tryParse(value.toString());
    if (parsed == null || parsed <= 0) {
      throw ArgumentError.value(value, key, 'Expected a positive integer');
    }
    return parsed;
  }

  int _readNonNegativeInt(
    Map<String, dynamic> input,
    String key, {
    required int defaultValue,
  }) {
    final value = input[key];
    if (value == null) return defaultValue;
    final parsed = value is int ? value : int.tryParse(value.toString());
    if (parsed == null || parsed < 0) {
      throw ArgumentError.value(value, key, 'Expected a non-negative integer');
    }
    return parsed;
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

  static Map<String, dynamic> _lineRangeParameters() {
    final parameters = _pathParameters();
    (parameters['properties'] as Map<String, dynamic>).addAll(<String, dynamic>{
      'startLine': <String, dynamic>{
        'type': 'integer',
        'description': '1-based start line. Defaults to 1.',
      },
      'maxLines': <String, dynamic>{
        'type': 'integer',
        'description': 'Maximum number of lines to return.',
      },
    });
    return parameters;
  }

  static Map<String, dynamic> _hunkParameters() {
    final parameters = _pathParameters();
    final properties = parameters['properties'] as Map<String, dynamic>;
    properties['hunkIndex'] = <String, dynamic>{
      'type': 'integer',
      'description': '0-based hunk index returned by get_file_diff_hunks.',
    };
    parameters['required'] = <String>['path', 'hunkIndex'];
    return parameters;
  }

  static Map<String, dynamic> _searchParameters() {
    final parameters = _pathParameters();
    final properties = parameters['properties'] as Map<String, dynamic>;
    properties['query'] = <String, dynamic>{
      'type': 'string',
      'description': 'Text to search for in the file.',
    };
    parameters['required'] = <String>['path', 'query'];
    return parameters;
  }
}

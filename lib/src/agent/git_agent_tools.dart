import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  final void Function(AgentToolUse toolUse)? onToolUse;

  static List<Map<String, dynamic>> get openAiToolDefinitions => [
        _openAiTool(
          name: 'list_staged_files',
          description: 'List files that currently have staged changes. '
              'Returns JSON containing each staged path, git status, and '
              'compact change metadata. Use this before requesting individual '
              'file diffs.',
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
          description: 'Return the staged (index) content for one staged '
              'file path when extra context is needed. The path must come '
              'from list_staged_files. Files staged for deletion have no '
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
          description: 'Return a bounded line range from the staged '
              '(index) content for one staged file path.',
          parameters: _lineRangeParameters(),
        ),
        _openAiTool(
          name: 'search_file_content',
          description: 'Search the staged (index) content of a staged file '
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
              'of the staged (index) content of one staged file path.',
          parameters: _lineRangeParameters(),
        ),
      ];

  static List<Map<String, dynamic>> get claudeToolDefinitions => [
        _claudeTool(
          name: 'list_staged_files',
          description: 'List files that currently have staged changes. '
              'Returns JSON containing each staged path, git status, and '
              'compact change metadata. Use this before requesting individual '
              'file diffs.',
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
          description: 'Return the staged (index) content for one staged '
              'file path when extra context is needed. The path must come '
              'from list_staged_files. Files staged for deletion have no '
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
          description: 'Return a bounded line range from the staged '
              '(index) content for one staged file path.',
          inputSchema: _lineRangeParameters(),
        ),
        _claudeTool(
          name: 'search_file_content',
          description: 'Search the staged (index) content of a staged file '
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
              'of the staged (index) content of one staged file path.',
          inputSchema: _lineRangeParameters(),
        ),
      ];

  static List<Map<String, dynamic>> get mcpToolDefinitions {
    return openAiToolDefinitions.map((tool) {
      final function = tool['function'] as Map<String, dynamic>;
      return <String, dynamic>{
        'name': function['name'],
        'description': function['description'],
        'inputSchema': _mcpSchema(function['parameters']),
        // Every GitWhisper tool only reads staged git data. Agents that honor
        // MCP tool annotations can run them without asking for permission.
        'annotations': <String, dynamic>{
          'readOnlyHint': true,
          'destructiveHint': false,
          'idempotentHint': true,
          'openWorldHint': false,
        },
      };
    }).toList();
  }

  /// Most lines get_file_content_chunk returns in one call.
  static const maxChunkLines = 400;

  /// Most lines get_blame returns in one call.
  static const maxBlameLines = 200;

  /// Longest line preview (search matches, changed-line previews) returned.
  static const maxPreviewLineCharacters = 240;

  static const _maxSearchMatches = 25;

  /// Largest staged blob GitWhisper reads into memory for content tools.
  static const int _maxStagedBlobBytes = 10 * 1024 * 1024;

  /// Hard ceiling applied to every tool result.
  ///
  /// Each tool already bounds its payload to [maxOutputCharacters]. The extra
  /// room covers JSON envelopes and escaping, and anything that slips past is
  /// cut here.
  int get _maxResultCharacters => maxOutputCharacters * 2 + 2048;

  Future<String> execute(String name, Map<String, dynamic> input) async {
    _logToolUse(name, input);

    return _capResult(await _executeTool(name, input));
  }

  Future<String> _executeTool(String name, Map<String, dynamic> input) {
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
    final toolUse = AgentToolUse.fromInput(name, input);

    final log = onToolUse;
    if (log != null) {
      log(toolUse);
    } else {
      $logger.info(toolUse.message);
    }
  }

  Future<String> _listStagedFiles() async {
    // -z keeps git from quoting non-ASCII and special paths, so each path is
    // the exact one the path-taking tools accept.
    final fields = (await _runGit(
      <String>['diff', '--cached', '--name-status', '-z'],
    ))
        .split('\u0000');
    final statsByPath = await _stagedNumStats();
    final files = <Map<String, dynamic>>[];

    // Each entry is a status followed by its path. Renames and copies (R and
    // C) are followed by the old path and then the new one.
    var index = 0;
    while (index < fields.length) {
      final status = fields[index++];
      if (status.isEmpty) continue;

      if (status.startsWith('R') || status.startsWith('C')) {
        if (index + 2 > fields.length) break;
        files.add(<String, dynamic>{
          'status': status,
          'oldPath': fields[index],
          'path': fields[index + 1],
        });
        index += 2;
      } else {
        if (index + 1 > fields.length) break;
        files.add(<String, dynamic>{
          'status': status,
          'path': fields[index],
        });
        index++;
      }
    }

    for (final file in files) {
      final filePath = file['path'] as String;
      final stats = statsByPath[filePath];
      file
        ..['additions'] = stats?.additions ?? 0
        ..['deletions'] = stats?.deletions ?? 0
        ..['changedLines'] = (stats?.additions ?? 0) + (stats?.deletions ?? 0)
        ..['isBinary'] = stats?.isBinary ?? false
        ..['isLikelyGenerated'] = _isLikelyGenerated(filePath)
        ..['isLockfile'] = _isLockfile(filePath);
    }

    // Huge commits (vendored code, generated assets) can stage thousands of
    // files; return as many entries as fit in the output budget.
    final returned = <Map<String, dynamic>>[];
    var characters = 0;
    for (final file in files) {
      characters += jsonEncode(file).length + 1;
      if (characters > maxOutputCharacters && returned.isNotEmpty) break;
      returned.add(file);
    }

    return jsonEncode(<String, dynamic>{
      'files': returned,
      if (returned.length < files.length) ...<String, dynamic>{
        'truncated': true,
        'totalFiles': files.length,
        'returnedFiles': returned.length,
      },
    });
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
    final bytes = await _readStagedBlob(stagedPath);
    if (bytes == null) {
      return 'File $stagedPath has no staged content (it may be staged for '
          'deletion).';
    }
    if (_looksBinary(bytes)) return 'File $stagedPath is binary.';

    return _boundedTextJson(
      value: _decodeLenient(bytes),
      path: stagedPath,
      nextTools: <String>['get_file_content_chunk', 'search_file_content'],
    );
  }

  Future<String> _getFileDiffHunks(Map<String, dynamic> input) async {
    final stagedPath = await _validateStagedPath(input);
    final diff = await _fileDiff(stagedPath);
    final hunks = _splitDiffHunks(diff);

    final entries = <Map<String, dynamic>>[];
    var characters = 0;
    for (var i = 0; i < hunks.length; i++) {
      final stats = _diffStats(hunks[i]);
      final entry = <String, dynamic>{
        'index': i,
        'header': _clipLine(_hunkHeader(hunks[i])),
        'additions': stats['additions'],
        'deletions': stats['deletions'],
        'preview': _previewChangedLines(hunks[i], limit: 4),
      };
      characters += jsonEncode(entry).length + 1;
      if (characters > maxOutputCharacters && entries.isNotEmpty) break;
      entries.add(entry);
    }

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'hunkCount': hunks.length,
      'hunks': entries,
      if (entries.length < hunks.length) 'truncated': true,
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
    final maxLines = _readPositiveInt(input, 'maxLines', defaultValue: 80)
        .clamp(1, maxChunkLines);
    final startIndex = (startLine - 1).clamp(0, lines.length);
    final endIndex = (startIndex + maxLines).clamp(0, lines.length);
    final content = lines.sublist(startIndex, endIndex).join('\n');

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'startLine': startIndex + 1,
      'endLine': endIndex,
      'totalLines': lines.length,
      'hasMore': endIndex < lines.length,
      if (content.length > maxOutputCharacters) 'truncated': true,
      'content': _capText(content),
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
      final matchIndex = lines[i].toLowerCase().indexOf(normalizedQuery);
      if (matchIndex >= 0) {
        matches.add(<String, dynamic>{
          'line': i + 1,
          'content': _clipLine(lines[i], around: matchIndex),
          if (lines[i].length > maxPreviewLineCharacters)
            'lineCharacters': lines[i].length,
        });
      }
      if (matches.length >= _maxSearchMatches) break;
    }

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'query': _clipLine(query),
      'matches': matches,
      'truncated': matches.length >= _maxSearchMatches,
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
    final trackedOutput = await _runGit(<String>['ls-files', '-z']);
    final trackedFiles = trackedOutput
        .split('\u0000')
        .where((value) => value.isNotEmpty)
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
    final maxLines = _readPositiveInt(input, 'maxLines', defaultValue: 20)
        .clamp(1, maxBlameLines);
    final staged = await _readStagedBlob(stagedPath);
    if (staged == null) {
      return 'File $stagedPath has no staged content to blame (it may be '
          'staged for deletion).';
    }
    final lineCount = _countLines(staged);
    if (startLine > lineCount) {
      throw ArgumentError.value(
        startLine,
        'startLine',
        'File has only $lineCount staged lines',
      );
    }
    final endLine = (startLine + maxLines - 1).clamp(startLine, lineCount);

    // Blame the staged content, not the working tree, so unstaged edits are
    // never attributed or shown.
    final output = await _runGit(
      <String>[
        'blame',
        '--contents',
        '-',
        '-L',
        '$startLine,$endLine',
        '--',
        stagedPath,
      ],
      stdinBytes: staged,
    );

    return jsonEncode(<String, dynamic>{
      'path': stagedPath,
      'startLine': startLine,
      'endLine': endLine,
      'lines': output
          .split('\n')
          .where((value) => value.trim().isNotEmpty)
          .take(maxLines)
          .map(
            (line) => _clipLine(
              line.replaceFirst(_blameContentsLabel, _blameStagedLabel),
            ),
          )
          .toList(),
    });
  }

  // `git blame --contents` labels lines that differ from HEAD with this
  // author; report them as staged instead.
  static const _blameContentsLabel = 'External file (--contents)';
  static const _blameStagedLabel = 'Staged, not committed';

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
    // A literal pathspec, so a name such as `*.txt` matches only itself.
    return _runGit(
      <String>['--literal-pathspecs', 'diff', '--cached', '--', stagedPath],
    );
  }

  Future<Map<String, _StagedNumStat>> _stagedNumStats() async {
    final fields = (await _runGit(
      <String>['diff', '--cached', '--numstat', '-z'],
    ))
        .split('\u0000');
    final stats = <String, _StagedNumStat>{};

    // Entries are "<added>\t<deleted>\t<path>". A rename or copy leaves the
    // path empty and is followed by the old path and then the new one.
    var index = 0;
    while (index < fields.length) {
      final parts = fields[index++].split('\t');
      if (parts.length < 3) continue;

      var rawPath = parts.sublist(2).join('\t');
      if (rawPath.isEmpty) {
        if (index + 2 > fields.length) break;
        rawPath = fields[index + 1];
        index += 2;
      }

      final additions = int.tryParse(parts[0]) ?? 0;
      final deletions = int.tryParse(parts[1]) ?? 0;
      final stagedPath = _normalizeGitPath(rawPath);
      stats[stagedPath] = _StagedNumStat(
        additions: additions,
        deletions: deletions,
        isBinary: parts[0] == '-' || parts[1] == '-',
      );
    }

    return stats;
  }

  Future<List<String>> _readTextFileLines(String stagedPath) async {
    final bytes = await _readStagedBlob(stagedPath);
    if (bytes == null) return <String>[];
    if (_looksBinary(bytes)) {
      throw ArgumentError.value(stagedPath, 'path', 'File is binary');
    }
    return _decodeLenient(bytes).split('\n');
  }

  /// Reads the staged (index) version of [stagedPath] as raw bytes, or null
  /// when the path has no blob in the index (for example a staged deletion).
  ///
  /// Content tools read from the index, never the working tree. Unstaged
  /// edits are not reported as staged, and a staged symlink yields its link
  /// text instead of the content of whatever it points to (such as a key
  /// outside the repository). `:<path>` names the index entry literally,
  /// relative to the repository root, the same form `git diff --cached
  /// --name-only` reports.
  Future<List<int>?> _readStagedBlob(String stagedPath) async {
    final object = ':$stagedPath';
    final type = await _runGitProcess(<String>['cat-file', '-t', object]);
    if (type.exitCode != 0) return null;

    final objectType = _decodeLenient(type.stdout as List<int>).trim();
    if (objectType != 'blob') {
      throw ArgumentError.value(
        stagedPath,
        'path',
        'Staged entry is a $objectType, not a file',
      );
    }

    final size = int.tryParse(
      _decodeLenient(
        (await _runGitProcess(<String>['cat-file', '-s', object])).stdout
            as List<int>,
      ).trim(),
    );
    if (size == null || size > _maxStagedBlobBytes) {
      throw ArgumentError.value(
        stagedPath,
        'path',
        'Staged file is too large to read (${size ?? 'unknown'} bytes)',
      );
    }

    final blob = await _runGitProcess(<String>['cat-file', 'blob', object]);
    if (blob.exitCode != 0) return null;
    return blob.stdout as List<int>;
  }

  /// Git's own heuristic: content with a NUL byte near the start is binary.
  bool _looksBinary(List<int> bytes) {
    final end = bytes.length < 8000 ? bytes.length : 8000;
    for (var i = 0; i < end; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  int _countLines(List<int> bytes) {
    if (bytes.isEmpty) return 0;
    var lines = 0;
    for (final byte in bytes) {
      if (byte == 0x0A) lines++;
    }
    return bytes.last == 0x0A ? lines : lines + 1;
  }

  /// Decodes git output leniently: invalid UTF-8 becomes U+FFFD instead of
  /// throwing, matching how GitUtils reads diffs.
  String _decodeLenient(List<int> bytes) {
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Shortens one line to [maxPreviewLineCharacters]. The kept window starts
  /// a little before [around] (for example a search match) so the relevant
  /// part stays visible.
  String _clipLine(String line, {int around = 0}) {
    if (line.length <= maxPreviewLineCharacters) return line;
    final start = (around - maxPreviewLineCharacters ~/ 4)
        .clamp(0, line.length - maxPreviewLineCharacters);
    final end = start + maxPreviewLineCharacters;
    final prefix = start > 0 ? '…' : '';
    final suffix = end < line.length ? '…' : '';
    return '$prefix${line.substring(start, end)}$suffix';
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

  Future<String> _runGit(List<String> args, {List<int>? stdinBytes}) async {
    final result = await _runGitProcess(args, stdinBytes: stdinBytes);

    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        args,
        _decodeLenient(result.stderr as List<int>),
        result.exitCode,
      );
    }

    return _decodeLenient(result.stdout as List<int>);
  }

  /// Runs git and captures stdout/stderr as raw bytes (`List<int>`).
  ///
  /// Git output can contain binary or non-UTF-8 content, and the default UTF-8
  /// stream decoding used by Process.run throws "Unexpected extension byte" on
  /// the first invalid byte. Callers decode with [_decodeLenient] instead.
  ///
  /// `core.quotePath=false` keeps non-ASCII paths readable in diff headers
  /// and stats (`café.txt`, not `"caf\303\251.txt"`), so the model sees the
  /// same paths list_staged_files returns.
  Future<ProcessResult> _runGitProcess(
    List<String> args, {
    List<int>? stdinBytes,
  }) async {
    final gitArgs = <String>['-c', 'core.quotePath=false', ...args];
    if (stdinBytes == null) {
      return Process.run(
        'git',
        gitArgs,
        workingDirectory: folderPath,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
    }

    final process = await Process.start(
      'git',
      gitArgs,
      workingDirectory: folderPath,
    );
    final stdoutBytes = _collectBytes(process.stdout);
    final stderrBytes = _collectBytes(process.stderr);
    process.stdin.add(stdinBytes);
    await process.stdin.close();
    final exitCode = await process.exitCode;
    return ProcessResult(
      process.pid,
      exitCode,
      await stdoutBytes,
      await stderrBytes,
    );
  }

  static Future<List<int>> _collectBytes(Stream<List<int>> stream) {
    return stream
        .fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) => builder..add(chunk),
        )
        .then((builder) => builder.takeBytes());
  }

  String _truncate(String value) {
    if (value.length <= maxOutputCharacters) return value.trim();

    return '${value.substring(0, maxOutputCharacters)}\n\n'
        '[Output truncated by GitWhisper.]';
  }

  /// Like [_truncate], but keeps leading and trailing whitespace (file content
  /// indentation matters).
  String _capText(String value) {
    if (value.length <= maxOutputCharacters) return value;

    return '${value.substring(0, maxOutputCharacters)}\n\n'
        '[Output truncated by GitWhisper.]';
  }

  String _capResult(String result) {
    final limit = _maxResultCharacters;
    if (result.length <= limit) return result;

    return '${result.substring(0, limit)}\n\n'
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
        .map(_clipLine)
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

  static Map<String, dynamic> _mcpSchema(Object? value) {
    if (value is! Map) return <String, dynamic>{};
    final schema = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (key == 'additionalProperties') continue;
      final child = entry.value;
      schema[key] = switch (child) {
        Map() => _mcpSchema(child),
        List() =>
          child.map((item) => item is Map ? _mcpSchema(item) : item).toList(),
        _ => child,
      };
    }
    return schema;
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
        'description': 'Maximum number of lines to return. Large values '
            'are capped.',
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

class _StagedNumStat {
  const _StagedNumStat({
    required this.additions,
    required this.deletions,
    required this.isBinary,
  });

  final int additions;
  final int deletions;
  final bool isBinary;
}

class AgentToolUse {
  const AgentToolUse({
    required this.name,
    this.path,
    this.hunkIndex,
  });

  factory AgentToolUse.fromInput(String name, Map<String, dynamic> input) {
    final pathValue = input['path'];
    final hunkValue = input['hunkIndex'];
    return AgentToolUse(
      name: name,
      path: pathValue is String && pathValue.trim().isNotEmpty
          ? pathValue.trim()
          : null,
      hunkIndex: hunkValue is int ? hunkValue : int.tryParse('$hunkValue'),
    );
  }

  final String name;
  final String? path;
  final int? hunkIndex;

  String get label {
    final pathValue = path;
    return pathValue == null ? name : '$name($pathValue)';
  }

  String get message => 'Agent tool: $label';
}

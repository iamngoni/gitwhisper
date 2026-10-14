//
//  gitwhisper
//  git_utils.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'constants.dart';

/// A git operation that failed. [message] says what went wrong and, where
/// possible, how to fix it.
class GitException implements Exception {
  const GitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Utility class for Git operations
class GitUtils {
  /// Returns a list of subdirectories (1 level down) that are git repositories.
  /// If current directory is a git repo, returns an empty list.
  ///
  /// Searches [folderPath] instead of the current directory when given.
  static Future<List<String>> findGitReposInSubfolders({
    String? folderPath,
  }) async {
    final dir = folderPath != null ? Directory(folderPath) : Directory.current;
    final subdirs =
        dir.listSync(followLinks: false).whereType<Directory>().toList();

    final List<String> gitRepos = [];

    for (final subdir in subdirs) {
      final gitDir = Directory('${subdir.path}/.git');
      if (gitDir.existsSync()) {
        // Quick check: .git folder exists, but let's confirm with git command
        final subResult = await Process.run(
          'git',
          ['rev-parse', '--is-inside-work-tree'],
          workingDirectory: subdir.path,
        );
        if (subResult.exitCode == 0 &&
            (subResult.stdout as String).trim() == 'true') {
          gitRepos.add(subdir.path);
        }
      }
    }

    return gitRepos;
  }

  /// Run a git command capturing stdout as raw bytes and decode it leniently.
  ///
  /// `Process.run` defaults to decoding stdout with [systemEncoding] (UTF-8),
  /// which throws "Unexpected extension byte" as soon as the stream contains a
  /// byte that is not valid UTF-8 — for example when a `git diff` includes a
  /// binary file or a file saved in a non-UTF-8 encoding. Reading the raw bytes
  /// and decoding with `allowMalformed: true` replaces the offending bytes with
  /// the Unicode replacement character instead of crashing.
  static Future<String> _gitText(
    List<String> args, {
    String? folderPath,
  }) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: folderPath,
      stdoutEncoding: null,
    );
    if (result.exitCode != 0) return '';
    return utf8.decode(result.stdout as List<int>, allowMalformed: true);
  }

  /// Get the diff of staged changes
  static Future<String> getStagedDiff({String? folderPath}) async {
    return _gitText(['diff', '--cached'], folderPath: folderPath);
  }

  /// Get the diff of unstagged changes
  static Future<String> getUnstagedDiff({String? folderPath}) async {
    return _gitText(['diff'], folderPath: folderPath);
  }

  /// Returns the paths with unresolved merge conflicts, relative to the
  /// repository root. Covers the whole repository even when [folderPath] is a
  /// subdirectory, which plain `git ls-files -u` would not.
  static Future<List<String>> getUnmergedFiles({String? folderPath}) async {
    final output = await _gitText(
      ['ls-files', '--unmerged', '--full-name', '-z', '--', ':/'],
      folderPath: folderPath,
    );
    // Entries look like "<mode> <object> <stage>\t<path>", one per stage.
    final files = <String>{};
    for (final entry in output.split('\x00')) {
      final tab = entry.indexOf('\t');
      if (tab != -1) files.add(entry.substring(tab + 1));
    }
    return files.toList();
  }

  /// Check if there are staged changes
  static Future<bool> hasStagedChanges({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['diff', '--cached', '--name-only'],
      workingDirectory: folderPath,
    );
    return result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty;
  }

  /// Returns a list of folder paths (from the input) that have staged changes.
  static Future<List<String>> foldersWithStagedChanges(
      List<String> folders) async {
    final result = <String>[];
    for (final folder in folders) {
      final gitResult = await Process.run(
        'git',
        ['diff', '--cached', '--name-only'],
        workingDirectory: folder,
      );
      if (gitResult.exitCode == 0 &&
          (gitResult.stdout as String).trim().isNotEmpty) {
        result.add(folder);
      }
    }
    return result;
  }

  /// Returns a list of folder paths (from the input) that have unstaged changes.
  static Future<List<String>> foldersWithUnstagedChanges(
      List<String> folders) async {
    final result = <String>[];
    for (final folder in folders) {
      final gitResult = await Process.run(
        'git',
        ['diff', '--name-only'],
        workingDirectory: folder,
      );
      if (gitResult.exitCode == 0 &&
          (gitResult.stdout as String).trim().isNotEmpty) {
        result.add(folder);
      }
    }
    return result;
  }

  /// Check if there are unstaged changes
  static Future<bool> hasUnstagedChanges({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['diff', '--name-only'],
      workingDirectory: folderPath,
    );
    return result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty;
  }

  /// Check if there are untracked files
  static Future<bool> hasUntrackedFiles({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['ls-files', '--others', '--exclude-standard'],
      workingDirectory: folderPath,
    );
    return result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty;
  }

  /// Returns a list of folder paths (from the input) that have untracked files.
  static Future<List<String>> foldersWithUntrackedFiles(
      List<String> folders) async {
    final result = <String>[];
    for (final folder in folders) {
      final gitResult = await Process.run(
        'git',
        ['ls-files', '--others', '--exclude-standard'],
        workingDirectory: folder,
      );
      if (gitResult.exitCode == 0 &&
          (gitResult.stdout as String).trim().isNotEmpty) {
        result.add(folder);
      }
    }
    return result;
  }

  /// Returns the top-level directory of the work tree containing [folderPath]
  /// (or the current directory), or null outside a work tree.
  static Future<String?> getRepositoryRoot({String? folderPath}) {
    return _gitValue(
      ['rev-parse', '--show-toplevel'],
      folderPath: folderPath,
    );
  }

  /// The work tree root for [folderPath], falling back to [folderPath] (or
  /// the current directory) when git cannot tell.
  static Future<String> _workTreeRoot(String? folderPath) async {
    return await getRepositoryRoot(folderPath: folderPath) ??
        folderPath ??
        Directory.current.path;
  }

  /// Check if the current directory (or [folderPath]) is a Git repository
  static Future<bool> isGitRepository({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['rev-parse', '--is-inside-work-tree'],
      workingDirectory: folderPath,
    );
    return result.exitCode == 0 && (result.stdout as String).trim() == 'true';
  }

  /// Commits the staged changes with [message].
  ///
  /// Tagging and pushing are separate steps ([createTag], [pushCurrentBranch],
  /// [pushTag]) so callers can report a failure there without implying that
  /// the commit itself failed.
  static Future<void> runGitCommit({
    required String message,
    String? folderPath,
  }) async {
    final result = await Process.run(
      'git',
      ['commit', '-m', message],
      workingDirectory: folderPath,
    );
    if (result.exitCode != 0) {
      throw GitException('git commit failed: ${_errorText(result)}');
    }
  }

  /// Creates a lightweight [tag] on HEAD.
  static Future<void> createTag(String tag, {String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['tag', tag],
      workingDirectory: folderPath,
    );
    if (result.exitCode != 0) {
      throw GitException('Could not create tag $tag: ${_errorText(result)}');
    }
  }

  /// Returns the names of the configured remotes.
  static Future<List<String>> getRemotes({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['remote'],
      workingDirectory: folderPath,
    );
    if (result.exitCode != 0) return [];
    return (result.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// Pushes the current branch.
  ///
  /// A branch with an upstream on a remote is pushed with a plain `git push`
  /// when git can say where that goes (`@{push}` resolves), so the user's
  /// push settings apply. Otherwise, for example after `git checkout -b
  /// feature origin/main` with `push.default=simple`, the branch is pushed
  /// under its own name to its push remote, leaving the upstream unchanged.
  /// Without an upstream, or with a local one, a repository with exactly one
  /// remote is pushed there with `-u` to set the upstream.
  /// Throws a [GitException] explaining what to do for a detached HEAD, no
  /// remote, several remotes and no upstream, or a rejected push.
  ///
  /// Returns the remote pushed to and a `remote/branch` description.
  static Future<({String remote, String target})> pushCurrentBranch({
    String? folderPath,
  }) async {
    final branch = await _gitValue(
      ['symbolic-ref', '--quiet', '--short', 'HEAD'],
      folderPath: folderPath,
    );
    if (branch == null) {
      throw const GitException(
        'HEAD is detached, so there is no branch to push. Check out a branch '
        'and push it manually.',
      );
    }

    final upstream = await _gitValue(
      ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'],
      folderPath: folderPath,
    );
    final remote = upstream == null
        ? null
        : await _pushRemote(branch, folderPath: folderPath);
    // A local upstream (remote ".") is handled like no upstream below.
    if (remote != null && remote != '.') {
      final pushTarget = await _gitValue(
        ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{push}'],
        folderPath: folderPath,
      );
      if (pushTarget != null) {
        await _push(['push'], folderPath: folderPath);
        return (remote: remote, target: pushTarget);
      }

      await _push(
        ['push', remote, 'refs/heads/$branch:refs/heads/$branch'],
        folderPath: folderPath,
      );
      return (remote: remote, target: '$remote/$branch');
    }

    final remotes = await getRemotes(folderPath: folderPath);
    if (remotes.isEmpty) {
      throw GitException(
        'No git remote is configured. Add one with '
        '`git remote add origin <url>`, then run `git push -u origin $branch`.',
      );
    }
    if (remotes.length > 1) {
      throw GitException(
        'Branch $branch has no upstream and this repository has several '
        'remotes (${remotes.join(', ')}). Push it once with '
        '`git push -u <remote> $branch` to choose one.',
      );
    }

    final onlyRemote = remotes.single;
    await _push(['push', '-u', onlyRemote, branch], folderPath: folderPath);
    return (remote: onlyRemote, target: '$onlyRemote/$branch');
  }

  /// Pushes [tag] to [remote].
  static Future<void> pushTag(
    String tag, {
    required String remote,
    String? folderPath,
  }) async {
    await _push(['push', remote, 'refs/tags/$tag'], folderPath: folderPath);
  }

  static Future<void> _push(List<String> args, {String? folderPath}) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: folderPath,
    );
    if (result.exitCode != 0) {
      throw GitException('git ${args.join(' ')} failed: ${_errorText(result)}');
    }
  }

  /// The remote a plain `git push` of [branch] goes to, following git's
  /// order: branch pushRemote, remote.pushDefault, then the branch remote.
  static Future<String> _pushRemote(String branch, {String? folderPath}) async {
    for (final key in [
      'branch.$branch.pushRemote',
      'remote.pushDefault',
      'branch.$branch.remote',
    ]) {
      final value = await _gitValue(
        ['config', '--get', key],
        folderPath: folderPath,
      );
      if (value != null) return value;
    }
    return 'origin';
  }

  /// Runs git and returns its trimmed stdout, or null on failure or no output.
  static Future<String?> _gitValue(
    List<String> args, {
    String? folderPath,
  }) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: folderPath,
    );
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty ? null : value;
  }

  /// git reports most errors on stderr, but some (e.g. "nothing to commit")
  /// on stdout.
  static String _errorText(ProcessResult result) {
    final stderr = (result.stderr as String).trim();
    return stderr.isNotEmpty ? stderr : (result.stdout as String).trim();
  }

  /// Stages all unstaged changes (including new files) and returns the number
  /// of files added to the index
  static Future<int> stageAllUnstagedFilesAndCount({String? folderPath}) async {
    // Get currently staged files before
    final beforeResult = await Process.run(
      'git',
      ['diff', '--cached', '--name-only'],
      workingDirectory: folderPath,
    );
    if (beforeResult.exitCode != 0) {
      throw Exception(
        'Failed to get staged files before: ${beforeResult.stderr}',
      );
    }
    final before = (beforeResult.stdout as String)
        .trim()
        .split('\n')
        .where((f) => f.isNotEmpty)
        .toSet();

    // Stage all changes (including new files and deletions) in the whole
    // repository. `git add .` would only cover the current subdirectory.
    final addResult = await Process.run(
      'git',
      ['add', '-A'],
      workingDirectory: folderPath,
    );
    if (addResult.exitCode != 0) {
      throw Exception('Failed to stage all changes: ${addResult.stderr}');
    }

    // Get currently staged files after
    final afterResult = await Process.run(
      'git',
      ['diff', '--cached', '--name-only'],
      workingDirectory: folderPath,
    );
    if (afterResult.exitCode != 0) {
      throw Exception(
        'Failed to get staged files after: ${afterResult.stderr}',
      );
    }
    final after = (afterResult.stdout as String)
        .trim()
        .split('\n')
        .where((f) => f.isNotEmpty)
        .toSet();

    // Return the number of files newly staged
    return after.difference(before).length;
  }

  /// Opens the user's configured Git editor to edit a commit message.
  ///
  /// This function:
  /// 1. Gets the user's Git editor configuration (or falls back to $EDITOR or vi)
  /// 2. Writes the initial message to a temporary file
  /// 3. Opens the editor for the user to edit the message
  /// 4. Reads back the edited message and cleans it up
  ///
  /// Returns the edited message, or null if the user left it empty or the
  /// editor exited with an error. Throws if the editor cannot be started.
  ///
  /// [folderPath] is the repository whose `core.editor` applies.
  static Future<String?> openGitEditor(
    String initialMessage, {
    String? folderPath,
  }) async {
    // Get the configured Git editor
    final editorResult = await Process.run(
      'git',
      ['var', 'GIT_EDITOR'],
      workingDirectory: folderPath,
    );
    String editor;

    if (editorResult.exitCode == 0 &&
        (editorResult.stdout as String).trim().isNotEmpty) {
      editor = (editorResult.stdout as String).trim();
    } else {
      // Fall back to EDITOR environment variable or vi
      editor = Platform.environment['EDITOR'] ??
          (Platform.isWindows ? 'notepad' : 'vi');
    }

    // Create a temporary file for the commit message
    final tempDir = Directory.systemTemp;
    final tempFile = File(
        '${tempDir.path}/GITWHISPER_EDITMSG_${DateTime.now().millisecondsSinceEpoch}');

    try {
      // Write the initial message to the temp file
      await tempFile.writeAsString(initialMessage);

      // Open the editor (use Process.start to allow interactive editing)
      final (executable, arguments) = editorCommand(
        editor,
        tempFile.path,
        windows: Platform.isWindows,
      );
      final process = await Process.start(
        executable,
        arguments,
        mode: ProcessStartMode.inheritStdio,
      );

      final exitCode = await process.exitCode;

      if (exitCode != 0) {
        $logger.err('Editor exited with code $exitCode');
        return null;
      }

      // Read the edited message
      final editedMessage = await tempFile.readAsString();

      // Clean up: remove comment lines (lines starting with #) and trim
      final cleanedLines = editedMessage
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('#'))
          .toList();

      final cleaned = cleanedLines.join('\n').trim();

      return cleaned.isNotEmpty ? cleaned : null;
    } finally {
      // Clean up the temp file
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  /// Builds the process that opens [editor] (a `GIT_EDITOR` command line such
  /// as `code --wait`) on [filePath].
  ///
  /// Elsewhere the editor runs through `/bin/sh -c`, as git does. On Windows
  /// there is no `/bin/sh`, so the editor runs through `cmd /c`, which also
  /// resolves `.cmd` shims such as `code`. An editor whose executable path
  /// contains spaces is started directly instead, because cmd strips the
  /// quotes around such a path.
  static (String, List<String>) editorCommand(
    String editor,
    String filePath, {
    required bool windows,
  }) {
    if (!windows) {
      return ('/bin/sh', ['-c', '$editor "$filePath"']);
    }

    final parts = _splitCommandLine(editor);
    if (parts.isEmpty) return ('notepad', [filePath]);
    if (parts.first.contains(' ')) {
      return (parts.first, [...parts.skip(1), filePath]);
    }
    return ('cmd', ['/c', ...parts, filePath]);
  }

  /// Splits a command line on whitespace outside quotes. Backslashes are kept
  /// literally so Windows paths survive.
  static List<String> _splitCommandLine(String commandLine) {
    final parts = <String>[];
    final current = StringBuffer();
    String? quote;
    var inToken = false;

    for (final char in commandLine.split('')) {
      if (quote != null) {
        if (char == quote) {
          quote = null;
        } else {
          current.write(char);
        }
      } else if (char == '"' || char == "'") {
        quote = char;
        inToken = true;
      } else if (char.trim().isEmpty) {
        if (inToken) {
          parts.add(current.toString());
          current.clear();
          inToken = false;
        }
      } else {
        current.write(char);
        inToken = true;
      }
    }
    if (inToken) parts.add(current.toString());
    return parts;
  }

  /// Removes Markdown-style code block markers (``` or ```dart) from a string.
  ///
  /// This is useful when dealing with AI-generated or Markdown-formatted text
  /// that includes code fences around commit messages or snippets.
  ///
  /// Example:
  /// ```dart
  /// final raw = '```dart\nfix: improve performance of query\n```';
  /// final cleaned = stripMarkdownCodeBlocks(raw);
  /// print(cleaned); // Output: fix: improve performance of query
  /// ```
  ///
  /// - Removes opening code fences like ``` or ```dart at the start of the string
  /// - Removes closing ``` at the end of the string
  /// - Trims any leading/trailing whitespace
  ///
  /// [input] is the original string with possible Markdown code block syntax.
  /// Returns the cleaned string without Markdown code block delimiters.
  static String stripMarkdownCodeBlocks(String input) {
    final codeBlockPattern = RegExp(r'^```(\w+)?\n?|```$', multiLine: true);
    return input.replaceAll(codeBlockPattern, '').trim();
  }

  static const _commitTypes =
      'feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert';

  /// A whole line that is a commit message, optionally after a list marker
  /// and a `<prefix> ->` written by the model. Types match case-insensitively
  /// and the full-width colon used in Chinese, Japanese and Korean output is
  /// accepted; both are normalised by [_normalizeCommitLine].
  static final _commitLinePattern = RegExp(
    r'^(?:[-*•]\s+|\d+[.)]\s+)?'
    r'(?:(?<prefix>.+?)\s*->\s*)?'
    '(?<type>$_commitTypes)'
    r'(?<scope>\([^)]+\))?(?<breaking>!)?(?::\s+|：\s*)(?<description>\S.*)$',
    caseSensitive: false,
  );

  /// A commit message preceded by other text on the same line, e.g. an agent
  /// preface such as "I'll inspect the changes.docs: Add note". Only lowercase
  /// types count here, and the type must start a word so prose such as
  /// "the default prefix: now reads" does not yield "fix: now reads".
  static final _commitSubstringPattern = RegExp(
    '\\b(?<type>$_commitTypes)'
    r'(?<scope>\([^)]+\))?(?<breaking>!)?(?::\s+|：\s*)(?<description>\S.*)$',
  );

  /// Removes Markdown fences and extracts valid commit lines from noisy output.
  ///
  /// Commit types are lowercased and a full-width colon becomes `: `. When
  /// [prefix] is set, any `<something> ->` the model put before the type is
  /// dropped and `$prefix -> ` is applied to every line, so the configured
  /// prefix always survives regardless of its format.
  static String sanitizeGeneratedCommitMessage(
    String input, {
    bool requireConventionalCommit = false,
    String? prefix,
  }) {
    final cleaned = stripMarkdownCodeBlocks(input);
    final ticket = prefix?.trim() ?? '';
    final commitLines = cleaned
        .split('\n')
        .map((line) => _normalizeCommitLine(line.trim(), ticket))
        .whereType<String>()
        .fold<List<String>>(<String>[], (lines, line) {
      if (!lines.contains(line)) lines.add(line);
      return lines;
    });

    if (commitLines.isNotEmpty) return commitLines.join('\n').trim();
    if (requireConventionalCommit) return '';
    if (ticket.isEmpty) return cleaned.trim();

    // Not a conventional commit, but still apply the configured prefix.
    final existingPrefix = RegExp('^${RegExp.escape(ticket)}\\s*->\\s*');
    return cleaned
        .trim()
        .split('\n')
        .map((line) => line.trim())
        .map(
          (line) => line.isEmpty
              ? line
              : '$ticket -> ${line.replaceFirst(existingPrefix, '')}',
        )
        .join('\n');
  }

  /// Returns [line] as a normalised commit line, or null if it has none.
  static String? _normalizeCommitLine(String line, String ticket) {
    var match = _commitLinePattern.firstMatch(line);
    String? modelPrefix;
    if (match != null) {
      modelPrefix = match.namedGroup('prefix')?.trim();
    } else {
      match = _commitSubstringPattern.firstMatch(line);
      if (match == null) return null;
    }

    final type = match.namedGroup('type')!.toLowerCase();
    final scope = match.namedGroup('scope') ?? '';
    final breaking = match.namedGroup('breaking') ?? '';
    final description = match.namedGroup('description')!.trim();
    final header = '$type$scope$breaking: $description';

    if (ticket.isNotEmpty) return '$ticket -> $header';
    // Without a configured prefix, keep a ticket-like token the model wrote
    // (e.g. "PAY-123 ->") but not prose that happened to precede an arrow.
    if (modelPrefix != null &&
        modelPrefix.isNotEmpty &&
        !modelPrefix.contains(RegExp(r'\s'))) {
      return '$modelPrefix -> $header';
    }
    return header;
  }

  /// Estimates the size of a diff in characters for API limitations
  static int estimateDiffSize(String diff) {
    return diff.length;
  }

  /// Checks if a diff is too large for AI processing
  static bool isDiffTooLarge(String diff, {int maxSize = 50000}) {
    return estimateDiffSize(diff) > maxSize;
  }

  /// Splits a diff into individual hunks for per-hunk processing
  static List<DiffHunk> splitDiffIntoHunks(String diff) {
    if (diff.isEmpty) return [];

    final hunks = <DiffHunk>[];
    final lines = diff.split('\n');

    DiffHunk? currentHunk;
    final currentFile = <String>[];
    String? currentFileName;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // New file header
      if (line.startsWith('diff --git')) {
        // Save previous hunk if exists
        if (currentHunk != null) {
          hunks.add(currentHunk);
        }

        // Extract filename from "diff --git a/file b/file"
        final match = RegExp(r'diff --git a/(.*?) b/(.*)').firstMatch(line);
        currentFileName = match?.group(2) ?? 'unknown';
        currentFile.clear();
        currentFile.add(line);
        currentHunk = null;
      }
      // File metadata (index, ---, +++)
      else if (line.startsWith('index ') ||
          line.startsWith('---') ||
          line.startsWith('+++') ||
          line.startsWith('new file mode') ||
          line.startsWith('deleted file mode')) {
        currentFile.add(line);
      }
      // Hunk header (@@)
      else if (line.startsWith('@@')) {
        // Save previous hunk if exists
        if (currentHunk != null) {
          hunks.add(currentHunk);
        }

        // Start new hunk
        currentHunk = DiffHunk(
          fileName: currentFileName ?? 'unknown',
          header: List<String>.from(currentFile)..add(line),
          lines: [],
        );
      }
      // Hunk content lines
      else if (currentHunk != null &&
          (line.startsWith(' ') ||
              line.startsWith('+') ||
              line.startsWith('-'))) {
        currentHunk.lines.add(line);
      }
      // Handle empty lines or other content
      else if (currentHunk != null) {
        currentHunk.lines.add(line);
      } else {
        currentFile.add(line);
      }
    }

    // Add the last hunk
    if (currentHunk != null) {
      hunks.add(currentHunk);
    }

    return hunks;
  }

  /// Returns staged files that exceed the size threshold
  /// Returns a list of tuples (filePath, sizeInBytes)
  static Future<List<(String, int)>> getLargeFiles(
    int thresholdBytes, {
    String? folderPath,
  }) async {
    // Staged paths are relative to the repository root, not to folderPath,
    // and -z keeps git from quoting non-ASCII names.
    final root = await _workTreeRoot(folderPath);
    final result = await Process.run(
      'git',
      ['diff', '--cached', '--name-only', '-z'],
      workingDirectory: root,
    );

    if (result.exitCode != 0) {
      return [];
    }

    final files = (result.stdout as String)
        .split('\x00')
        .where((f) => f.isNotEmpty)
        .toList();

    final largeFiles = <(String, int)>[];

    for (final filePath in files) {
      final fullPath = path.join(root, filePath);
      final file = File(fullPath);

      if (await file.exists()) {
        final stat = await file.stat();
        if (stat.size > thresholdBytes) {
          largeFiles.add((filePath, stat.size));
        }
      }
    }

    return largeFiles;
  }

  /// Checks if a file exists in the remote repository history
  /// Returns true if the file has been pushed before
  ///
  /// [filePath] is relative to the repository root, as [getLargeFiles]
  /// returns it.
  static Future<bool> isFileInRemoteHistory(
    String filePath, {
    String? folderPath,
  }) async {
    // Check if file exists in any remote tracking branch
    final result = await Process.run(
      'git',
      ['--literal-pathspecs', 'log', '--oneline', '--remotes', '--', filePath],
      workingDirectory: await _workTreeRoot(folderPath),
    );

    if (result.exitCode != 0) {
      return false;
    }

    // If there are any commits with this file in remote history, it exists
    return (result.stdout as String).trim().isNotEmpty;
  }

  /// Appends a path to the repository's top-level .gitignore
  ///
  /// [filePath] is relative to the repository root, so it is written to the
  /// root .gitignore even when [folderPath] is a subdirectory.
  static Future<void> addToGitignore(
    String filePath, {
    String? folderPath,
  }) async {
    final root = await _workTreeRoot(folderPath);
    final gitignorePath = path.join(root, '.gitignore');
    final gitignoreFile = File(gitignorePath);

    String content = '';
    if (await gitignoreFile.exists()) {
      content = await gitignoreFile.readAsString();
    }

    // Check if already in gitignore
    final lines = content.split('\n');
    if (lines.contains(filePath)) {
      return; // Already present
    }

    // Append to gitignore
    final newContent = content.isEmpty
        ? '$filePath\n'
        : content.endsWith('\n')
            ? '$content$filePath\n'
            : '$content\n$filePath\n';

    await gitignoreFile.writeAsString(newContent);
  }

  /// Unstages a specific file, given relative to the repository root
  ///
  /// `git reset HEAD <file>` fails on a branch with no commits yet, so it is
  /// only used when HEAD has the file, to restore its committed version in
  /// the index. Otherwise the file is dropped from the index with
  /// `git rm --cached`, which keeps the working-tree copy. `-f` lets that
  /// drop a file whose working copy changed after staging, as reset would.
  static Future<void> unstageFile(String filePath, {String? folderPath}) async {
    final root = await _workTreeRoot(folderPath);
    final inHead = await Process.run(
      'git',
      ['cat-file', '-e', 'HEAD:$filePath'],
      workingDirectory: root,
    );
    final args = inHead.exitCode == 0
        ? ['--literal-pathspecs', 'reset', '-q', 'HEAD', '--', filePath]
        : ['--literal-pathspecs', 'rm', '--cached', '-f', '-q', '--', filePath];
    final result = await Process.run('git', args, workingDirectory: root);

    if (result.exitCode != 0) {
      throw GitException(
        'Failed to unstage $filePath: ${_errorText(result)}',
      );
    }
  }

  /// Groups hunks by their file name
  static Map<String, List<DiffHunk>> groupHunksByFile(List<DiffHunk> hunks) {
    final grouped = <String, List<DiffHunk>>{};
    for (final hunk in hunks) {
      grouped.putIfAbsent(hunk.fileName, () => []).add(hunk);
    }
    return grouped;
  }

  /// Reconstructs the diff content for a group of hunks from the same file
  static String reconstructFileDiff(List<DiffHunk> hunks) {
    return hunks.map((h) => [...h.header, ...h.lines].join('\n')).join('\n\n');
  }
}

/// Represents a single hunk in a git diff
class DiffHunk {
  final String fileName;
  final List<String> header; // File info + hunk header
  final List<String> lines; // The actual diff lines

  DiffHunk({
    required this.fileName,
    required this.header,
    required this.lines,
  });
}

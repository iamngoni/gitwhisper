//
//  gitwhisper
//  git_utils.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:io';

import 'package:path/path.dart' as path;

import 'constants.dart';

/// Utility class for Git operations
class GitUtils {
  // Get the full path of the current working directory
  String getCurrentDirectoryPath() {
    return Directory.current.path;
  }

  /// Returns a list of subdirectories (1 level down) that are git repositories.
  /// If current directory is a git repo, returns an empty list.
  static Future<List<String>> findGitReposInSubfolders() async {
    final dir = Directory.current;
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

  /// Get the diff of staged changes
  static Future<String> getStagedDiff({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['diff', '--cached'],
      workingDirectory: folderPath,
    );
    return result.exitCode == 0 ? (result.stdout as String) : '';
  }

  /// Get the diff of unstagged changes
  static Future<String> getUnstagedDiff({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['diff'],
      workingDirectory: folderPath,
    );
    return result.exitCode == 0 ? (result.stdout as String) : '';
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

  /// Check if the current directory is a Git repository
  static Future<bool> isGitRepository() async {
    final result =
        await Process.run('git', ['rev-parse', '--is-inside-work-tree']);
    return result.exitCode == 0 && (result.stdout as String).trim() == 'true';
  }

  /// Run git commit
  static Future<void> runGitCommit({
    required String message,
    bool autoPush = false,
    String? folderPath,
    String? tag,
  }) async {
    final args = ['commit', '-m', message];
    final result = await Process.run(
      'git',
      args,
      workingDirectory: folderPath,
    );
    if (result.exitCode != 0) {
      throw Exception('Error during git commit: ${result.stderr}');
    } else {
      // Create tag if provided
      if (tag != null && tag.isNotEmpty) {
        final tagResult = await Process.run(
          'git',
          ['tag', tag],
          workingDirectory: folderPath,
        );
        if (tagResult.exitCode != 0) {
          throw Exception('Error creating tag: ${tagResult.stderr}');
        }
        if (folderPath != null) {
          final folderName = path.basename(folderPath);
          $logger.success('[$folderName] Tag $tag created successfully!');
        } else {
          $logger.success('Tag $tag created successfully!');
        }
      }

      if (!autoPush) {
        if (folderPath != null) {
          final folderName = path.basename(folderPath);
          $logger.success('[$folderName] Commit successful! 🎉');
        } else {
          $logger.success('Commit successful! 🎉');
        }
      } else {
        /// Push the commit if autoPush is true
        $logger.info('Commit successful! Syncing with remote branch.');

        final branchName = await Process.run(
          'git',
          ['rev-parse', '--abbrev-ref', 'HEAD'],
          workingDirectory: folderPath,
        );
        final remoteNameNoneUrl = await Process.run('git', ['remote']);

        if (branchName.exitCode != 0 || remoteNameNoneUrl.exitCode != 0) {
          throw Exception(
            'Error getting branch or remote name: ${branchName.stderr}',
          );
        }

        final branch = (branchName.stdout as String).trim();
        final remoteNoneUrl = (remoteNameNoneUrl.stdout as String).trim();

        /// Run the git push command
        final pushResult = await Process.run(
          'git',
          ['push', remoteNoneUrl, branch],
          workingDirectory: folderPath,
        );
        if (pushResult.exitCode != 0) {
          throw Exception('Error during git push: ${pushResult.stderr}');
        } else {
          if (folderPath != null) {
            final folderName = path.basename(folderPath);
            $logger.success(
                '[$folderName] Pushed to $remoteNoneUrl/$branch successfully! 🎉');
          } else {
            $logger
                .success('Pushed to $remoteNoneUrl/$branch successfully! 🎉');
          }
        }

        // Push tag if it was created
        if (tag != null && tag.isNotEmpty) {
          final pushTagResult = await Process.run(
            'git',
            ['push', remoteNoneUrl, tag],
            workingDirectory: folderPath,
          );
          if (pushTagResult.exitCode != 0) {
            throw Exception('Error pushing tag: ${pushTagResult.stderr}');
          } else {
            if (folderPath != null) {
              final folderName = path.basename(folderPath);
              $logger.success('[$folderName] Tag $tag pushed successfully!');
            } else {
              $logger.success('Tag $tag pushed successfully!');
            }
          }
        }
      }
    }
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

    // Stage all changes (including new files)
    final addResult = await Process.run(
      'git',
      ['add', '.'],
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
  /// Returns the edited message, or null if the user left it empty or the editor failed.
  static Future<String?> openGitEditor(String initialMessage) async {
    // Get the configured Git editor
    final editorResult = await Process.run('git', ['var', 'GIT_EDITOR']);
    String editor;

    if (editorResult.exitCode == 0 &&
        (editorResult.stdout as String).trim().isNotEmpty) {
      editor = (editorResult.stdout as String).trim();
    } else {
      // Fall back to EDITOR environment variable or vi
      editor = Platform.environment['EDITOR'] ?? 'vi';
    }

    // Create a temporary file for the commit message
    final tempDir = Directory.systemTemp;
    final tempFile = File(
        '${tempDir.path}/GITWHISPER_EDITMSG_${DateTime.now().millisecondsSinceEpoch}');

    try {
      // Write the initial message to the temp file
      await tempFile.writeAsString(initialMessage);

      // Open the editor (use Process.start to allow interactive editing)
      final process = await Process.start(
        '/bin/sh',
        ['-c', '$editor "${tempFile.path}"'],
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

  /// Stages only specific hunks interactively
  static Future<void> stageHunk(DiffHunk hunk, {String? folderPath}) async {
    // Create a patch file from the hunk
    final patchContent = (hunk.header + hunk.lines).join('\n');
    final patchFile =
        File('${Directory.systemTemp.path}/gitwhisper_hunk.patch');

    try {
      await patchFile.writeAsString(patchContent);

      // Apply the patch to staging area
      final result = await Process.run(
        'git',
        ['apply', '--cached', patchFile.path],
        workingDirectory: folderPath,
      );

      if (result.exitCode != 0) {
        throw Exception('Failed to stage hunk: ${result.stderr}');
      }
    } finally {
      if (await patchFile.exists()) {
        await patchFile.delete();
      }
    }
  }

  /// Unstages all currently staged changes
  static Future<void> unstageAll({String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['reset', 'HEAD'],
      workingDirectory: folderPath,
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to unstage changes: ${result.stderr}');
    }
  }

  /// Returns staged files that exceed the size threshold
  /// Returns a list of tuples (filePath, sizeInBytes)
  static Future<List<(String, int)>> getLargeFiles(
    int thresholdBytes, {
    String? folderPath,
  }) async {
    // Get list of staged files
    final result = await Process.run(
      'git',
      ['diff', '--cached', '--name-only'],
      workingDirectory: folderPath,
    );

    if (result.exitCode != 0) {
      return [];
    }

    final files = (result.stdout as String)
        .trim()
        .split('\n')
        .where((f) => f.isNotEmpty)
        .toList();

    final largeFiles = <(String, int)>[];
    final workDir = folderPath ?? Directory.current.path;

    for (final filePath in files) {
      final fullPath = path.join(workDir, filePath);
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
  static Future<bool> isFileInRemoteHistory(
    String filePath, {
    String? folderPath,
  }) async {
    // Check if file exists in any remote tracking branch
    final result = await Process.run(
      'git',
      ['log', '--oneline', '--remotes', '--', filePath],
      workingDirectory: folderPath,
    );

    if (result.exitCode != 0) {
      return false;
    }

    // If there are any commits with this file in remote history, it exists
    return (result.stdout as String).trim().isNotEmpty;
  }

  /// Appends a path to .gitignore
  static Future<void> addToGitignore(
    String filePath, {
    String? folderPath,
  }) async {
    final workDir = folderPath ?? Directory.current.path;
    final gitignorePath = path.join(workDir, '.gitignore');
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
        ? filePath
        : content.endsWith('\n')
            ? '$content$filePath\n'
            : '$content\n$filePath\n';

    await gitignoreFile.writeAsString(newContent);
  }

  /// Unstages a specific file
  static Future<void> unstageFile(String filePath, {String? folderPath}) async {
    final result = await Process.run(
      'git',
      ['reset', 'HEAD', filePath],
      workingDirectory: folderPath,
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to unstage file: ${result.stderr}');
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

  /// Gets a human-readable description of what this hunk changes
  String get description {
    final addedLines = lines.where((line) => line.startsWith('+')).length;
    final removedLines = lines.where((line) => line.startsWith('-')).length;

    final parts = <String>[];
    if (addedLines > 0) parts.add('$addedLines added');
    if (removedLines > 0) parts.add('$removedLines removed');

    return '$fileName (${parts.isEmpty ? 'no changes' : parts.join(', ')})';
  }

  /// Estimates the complexity/size of this hunk
  int get complexity {
    return lines.length;
  }
}

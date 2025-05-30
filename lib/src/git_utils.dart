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
}

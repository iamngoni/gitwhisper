//
//  gitwhisper
//  git_utils.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:io';

/// Utility class for Git operations
class GitUtils {
  /// Check if the current directory is a Git repository
  static Future<bool> isGitRepository() async {
    final result =
        await Process.run('git', ['rev-parse', '--is-inside-work-tree']);
    return result.exitCode == 0 && (result.stdout as String).trim() == 'true';
  }

  /// Check if there are staged changes
  static Future<bool> hasStagedChanges() async {
    final result =
        await Process.run('git', ['diff', '--cached', '--name-only']);
    return result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty;
  }

  /// Get the diff of staged changes
  static Future<String> getStagedDiff() async {
    final result = await Process.run('git', ['diff', '--cached']);
    return result.exitCode == 0 ? (result.stdout as String) : '';
  }

  /// Set the Git commit message
  static Future<void> setGitCommitMessage(String message) async {
    // Get the git commit message file path
    final result = await Process.run('git', ['rev-parse', '--git-dir']);
    if (result.exitCode != 0) {
      throw Exception('Error getting git directory: ${result.stderr}');
    }

    final gitDir = (result.stdout as String).trim();
    final commitMessagePath = '$gitDir/COMMIT_EDITMSG';

    // Write the message to the file
    final file = File(commitMessagePath);
    await file.writeAsString(message);
  }

  /// Run git commit
  static Future<void> runGitCommit() async {
    final result = await Process.run('git', ['commit']);
    if (result.exitCode != 0) {
      throw Exception('Error during git commit: ${result.stderr}');
    } else {
      print('Commit successful!');
    }
  }
}

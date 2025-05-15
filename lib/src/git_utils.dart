//
//  gitwhisper
//  git_utils.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:io';

import 'constants.dart';

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

  /// Get the diff of unstagged changes
  static Future<String> getUnstagedDiff() async {
    final result = await Process.run('git', ['diff']);
    return result.exitCode == 0 ? (result.stdout as String) : '';
  }

  /// Get the diff of staged changes
  static Future<String> getStagedDiff() async {
    final result = await Process.run('git', ['diff', '--cached']);
    return result.exitCode == 0 ? (result.stdout as String) : '';
  }

  /// Run git commit
  static Future<void> runGitCommit(
      {required String message, bool autoPush = false}) async {
    final args = ['commit', '-m', message];
    final result = await Process.run('git', args);
    if (result.exitCode != 0) {
      throw Exception('Error during git commit: ${result.stderr}');
    } else {
      $logger.success('Commit successful! 🎉');

      /// Push the commit if autoPush is true
      if (autoPush) {
        $logger
          ..info('')
          ..info('Pushing changes to remote repository...')
          ..info('')
          ..info('---------------------------------')
          ..info('')
          ..info('Current Directory: ${Directory.current.path}')
          ..info('')
          ..info('---------------------------------');

        /// Prompt user to confirm push on [branchName] on [remoteName]
        final branchName =
            await Process.run('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
        final remoteName =
            await Process.run('git', ['config', '--get', 'remote.origin.url']);
        if (branchName.exitCode != 0 || remoteName.exitCode != 0) {
          throw Exception(
              'Error getting branch or remote name: ${branchName.stderr}');
        }
        final branch = (branchName.stdout as String).trim();
        final remote = (remoteName.stdout as String).trim();
        $logger
          ..info('')
          ..info('Are you sure you want to push to $branch on $remote? (y/n)\n')


        final confirmation = stdin.readLineSync();


        if (confirmation == null || confirmation.toLowerCase() != 'y') {
          $logger.info('Push cancelled‼️.');
          return;
        }
        $logger
          ..info('Pushing changes to remote repository...')
          ..info('');

        /// Run the git push command
        final pushResult = await Process.run('git', ['push']);
        if (pushResult.exitCode != 0) {
          throw Exception('Error during git push: ${pushResult.stderr}');
        } else {
          $logger.success('Push successful! 🎉');
        }
      }
    }
  }

  // Get the full path of the current working directory
  String getCurrentDirectoryPath() {
    return Directory.current.path;
  }
}

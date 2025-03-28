//
//  gitwhisper
//  update_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pub_updater/pub_updater.dart';

import '../version.dart';

class UpdateCommand extends Command<int> {
  UpdateCommand({
    required Logger logger,
    required PubUpdater pubUpdater,
  })  : _logger = logger,
        _pubUpdater = pubUpdater;

  @override
  String get description => 'Update to the latest version';

  @override
  String get name => 'update';

  final Logger _logger;
  final PubUpdater _pubUpdater;

  @override
  Future<int> run() async {
    final updateCheckProgress = _logger.progress('Checking for updates');
    late final String latestVersion;

    try {
      latestVersion = await _pubUpdater.getLatestVersion('gitwhisper');
    } catch (e) {
      updateCheckProgress.fail('Failed to check for updates');
      return ExitCode.software.code;
    }

    updateCheckProgress.complete('Update check complete');

    if (latestVersion == packageVersion) {
      _logger.success('GitWhisper is already at the latest version.');
      return ExitCode.success.code;
    }

    final updateProgress = _logger.progress('Updating to $latestVersion');

    try {
      await _pubUpdater.update(packageName: 'gitwhisper');
      updateProgress.complete('Updated to $latestVersion');
      _logger
        ..info('')
        ..info(
          'See the release notes here: https://github.com/iamngoni/gitwhisper/releases/tag/$latestVersion',
        );

      return ExitCode.success.code;
    } catch (e) {
      updateProgress.fail('Failed to update GitWhisper');
      _logger.err('Error updating GitWhisper: $e');
      return ExitCode.software.code;
    }
  }
}

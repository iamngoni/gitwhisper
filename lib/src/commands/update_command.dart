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

import '../update/install_update_manager.dart';
import '../version.dart';

class UpdateCommand extends Command<int> {
  UpdateCommand({
    required Logger logger,
    required PubUpdater pubUpdater,
    InstallUpdateManager? installUpdateManager,
  })  : _logger = logger,
        _pubUpdater = pubUpdater,
        _installUpdateManager = installUpdateManager ?? InstallUpdateManager() {
    argParser.addFlag(
      'check',
      help: 'Show the detected install method without updating.',
      negatable: false,
    );
  }

  @override
  String get description => 'Update to the latest version';

  @override
  String get name => 'update';

  final Logger _logger;
  final PubUpdater _pubUpdater;
  final InstallUpdateManager _installUpdateManager;

  @override
  Future<int> run() async {
    final checkOnly = argResults?['check'] as bool? ?? false;
    final detection = await _installUpdateManager.detect();

    _logger.info(
      'Detected ${detection.label} install${_pathSuffix(detection)}.',
    );

    if (checkOnly) {
      _printUpdateCommands(detection);
      return detection.type == InstallType.unknown
          ? ExitCode.usage.code
          : ExitCode.success.code;
    }

    if (detection.type != InstallType.dartPub) {
      return _runDetectedInstallerUpdate(detection);
    }

    final updateCheckProgress = _logger.progress('Checking for updates');
    late final String latestVersion;

    try {
      latestVersion = await _pubUpdater.getLatestVersion('gitwhisper');
    } on Object {
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
      final url = link(
        message:
            'https://pub.dev/packages/gitwhisper/versions/$latestVersion/changelog',
        uri: Uri.parse(
          'https://pub.dev/packages/gitwhisper/versions/$latestVersion/changelog',
        ),
      );
      _logger
        ..info('')
        ..info(
          'See the release notes here: $url',
        );

      return ExitCode.success.code;
    } on Object catch (e) {
      updateProgress.fail('Failed to update GitWhisper');
      _logger.err('Error updating GitWhisper: $e');
      return ExitCode.software.code;
    }
  }

  Future<int> _runDetectedInstallerUpdate(InstallDetection detection) async {
    if (detection.type == InstallType.unknown) {
      _logger.err('Could not detect how GitWhisper was installed.');
      _printUpdateCommands(detection);
      return ExitCode.usage.code;
    }

    final updateProgress = _logger.progress('Updating via ${detection.label}');

    try {
      await _installUpdateManager.runUpdateCommands(detection);
      updateProgress.complete('GitWhisper update complete');
      return ExitCode.success.code;
    } on Object catch (e) {
      updateProgress.fail('Failed to update GitWhisper');
      _logger.err('Error updating GitWhisper: $e');
      _printUpdateCommands(detection);
      return ExitCode.software.code;
    }
  }

  void _printUpdateCommands(InstallDetection detection) {
    if (detection.updateCommands.isEmpty) {
      _logger
        ..info('Try one of these commands:')
        ..info('  dart pub global activate gitwhisper')
        ..info('  brew upgrade gitwhisper')
        ..info(
          '  curl -sSL https://raw.githubusercontent.com/iamngoni/gitwhisper/master/install.sh | bash',
        );
      return;
    }

    final plural = detection.updateCommands.length == 1 ? '' : 's';
    _logger.info('Update command$plural:');
    for (final command in detection.updateCommands) {
      _logger.info('  ${command.join(' ')}');
    }
  }

  String _pathSuffix(InstallDetection detection) {
    final path = detection.executablePath;
    return path == null || path.isEmpty ? '' : ' at $path';
  }
}

import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:pub_updater/pub_updater.dart';

import '../version.dart';
import 'install_update_manager.dart';

typedef LatestVersionProvider = Future<String> Function();

class UpdateNotifier {
  UpdateNotifier({
    required Logger logger,
    PubUpdater? pubUpdater,
    InstallUpdateManager? installUpdateManager,
    LatestVersionProvider? latestVersionProvider,
    String currentVersion = packageVersion,
  })  : _logger = logger,
        _pubUpdater = pubUpdater ?? PubUpdater(),
        _installUpdateManager = installUpdateManager ?? InstallUpdateManager(),
        _latestVersionProvider = latestVersionProvider,
        _currentVersion = currentVersion;

  static bool _checkedThisSession = false;
  static bool _skippedThisSession = false;

  final Logger _logger;
  final PubUpdater _pubUpdater;
  final InstallUpdateManager _installUpdateManager;
  final LatestVersionProvider? _latestVersionProvider;
  final String _currentVersion;

  Future<void> maybePrompt() async {
    if (_checkedThisSession || _skippedThisSession || !_canPrompt) return;
    _checkedThisSession = true;

    late final String latestVersion;
    try {
      latestVersion = await (_latestVersionProvider?.call() ??
              _pubUpdater.getLatestVersion('gitwhisper'))
          .timeout(const Duration(seconds: 2));
    } on Object {
      return;
    }

    if (!_isNewerVersion(latestVersion, _currentVersion)) return;

    _logger
      ..info('')
      ..info('A new version of GitWhisper is available.')
      ..info('Current: $_currentVersion  Latest: $latestVersion');

    final action = _logger.chooseOne(
      'Update now?',
      choices: ['update now', 'stay on current version'],
      defaultValue: 'stay on current version',
    );

    if (action != 'update now') {
      _skippedThisSession = true;
      _logger.info('Staying on $_currentVersion for this session.');
      return;
    }

    await _updateTo(latestVersion);
  }

  Future<void> _updateTo(String latestVersion) async {
    final detection = await _installUpdateManager.detect();

    if (detection.type == InstallType.unknown) {
      _logger
        ..warn('Could not detect how GitWhisper was installed.')
        ..info('Run `gitwhisper update` to see manual update options.');
      return;
    }

    final progress = _logger.progress('Updating GitWhisper to $latestVersion');
    try {
      if (detection.type == InstallType.dartPub) {
        await _pubUpdater.update(packageName: 'gitwhisper');
      } else {
        await _installUpdateManager.runUpdateCommands(detection);
      }
      progress.complete('Updated GitWhisper to $latestVersion');
    } on Object catch (error) {
      progress.fail('Failed to update GitWhisper');
      _logger
        ..err(error.toString())
        ..info('Run `gitwhisper update` to retry.');
    }
  }

  bool get _canPrompt {
    if (Platform.environment['GITWHISPER_NO_UPDATE_CHECK'] == '1') {
      return false;
    }

    try {
      return stdin.hasTerminal && stdout.hasTerminal;
    } on Object {
      return false;
    }
  }

  bool _isNewerVersion(String latest, String current) {
    final latestParts = _versionParts(latest);
    final currentParts = _versionParts(current);

    for (var i = 0; i < latestParts.length; i++) {
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }

    return false;
  }

  List<int> _versionParts(String value) {
    final core = value.split('-').first;
    final parts = core.split('.');
    return List<int>.generate(3, (index) {
      if (index >= parts.length) return 0;
      return int.tryParse(parts[index]) ?? 0;
    });
  }
}

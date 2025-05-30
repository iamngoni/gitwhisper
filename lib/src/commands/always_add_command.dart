//
//  gitwhisper
//  always_add_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/05/30.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';

class AlwaysAddCommand extends Command<int> {
  AlwaysAddCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser.addOption(
      'always-add',
      help: 'Always stage changes',
      allowed: ['true', 'false'],
    );
  }

  final Logger _logger;

  @override
  String get description => 'Always stage changes before committing';

  @override
  String get name => 'always-add';

  @override
  Future<int> run() async {
    final arg = argResults?['always-add'] as String;
    final alwaysAdd = arg == 'true';

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Save the always add config
    configManager.setAlwaysAdd(value: alwaysAdd);
    await configManager.save();

    if (alwaysAdd) {
      _logger.success(
        'If there are no staged changes GitWhisper will now try to stage '
        'first before making a commit!',
      );
    } else {
      _logger.success(
        'If there are not staged changes GitWhisper will abort mission!',
      );
    }
    return ExitCode.success.code;
  }
}

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
  }) : _logger = logger;

  final Logger _logger;

  @override
  String get description => 'Always stage changes before committing';

  @override
  String get name => 'always-add';

  @override
  String get invocation => 'gw always-add <true|false>';

  @override
  Future<int> run() async {
    // Positional arguments are accessed via argResults.rest
    if (argResults == null || argResults!.rest.isEmpty) {
      _logger.err('You must specify "true" or "false".');
      return ExitCode.usage.code;
    }

    final arg = argResults!.rest.first;
    if (arg != 'true' && arg != 'false') {
      _logger.err('Value must be "true" or "false".');
      return ExitCode.usage.code;
    }
    final alwaysAdd = arg == 'true';

    final configManager = ConfigManager();
    await configManager.load();

    configManager.setAlwaysAdd(value: alwaysAdd);
    await configManager.save();

    if (alwaysAdd) {
      _logger.success(
        'If there are no staged changes GitWhisper will now try to stage '
        'first before making a commit!',
      );
    } else {
      _logger.success(
        'If there are no staged changes GitWhisper will abort mission!',
      );
    }
    return ExitCode.success.code;
  }
}

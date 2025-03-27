//
//  gitwhisper
//  clear_defaults_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/04.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';

class ClearDefaultsCommand extends Command<int> {
  ClearDefaultsCommand({
    required Logger logger,
  }) : _logger = logger;

  @override
  String get description => 'Clears all defaults';

  @override
  String get name => 'clear-defaults';

  final Logger _logger;

  @override
  Future<int> run() async {
    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Clear the defaults
    configManager.clearDefaults();
    await configManager.saveConfig();

    _logger.success('All set defaults have been cleared 🍻');
    return ExitCode.success.code;
  }
}

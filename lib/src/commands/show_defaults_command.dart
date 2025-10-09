//
//  gitwhisper
//  show_defaults_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/04.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';

class ShowDefaultsCommand extends Command<int> {
  ShowDefaultsCommand({
    required Logger logger,
  }) : _logger = logger;

  @override
  String get description => 'Shows current default settings';

  @override
  String get name => 'show-defaults';

  final Logger _logger;

  @override
  Future<int> run() async {
    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Get the current defaults
    final defaults = configManager.getDefaultModelAndVariant();
    final ollamaBaseUrl = configManager.getOllamaBaseURL();
    final confirmCommits = configManager.shouldConfirmCommits();
    final allowEmojis = configManager.shouldAllowEmojis();
    final alwaysAdd = configManager.shouldAlwaysAdd();

    if (defaults == null) {
      _logger
        ..info('No defaults are currently set.')
        ..info(
          'Use ${lightCyan.wrap('gitwhisper set-defaults')} to set defaults.',
        );
      return ExitCode.success.code;
    }

    final (model, variant) = defaults;

    _logger
      ..info('Current defaults:')
      ..info('  ${lightCyan.wrap('Model')}: $model')
      ..info('  ${lightCyan.wrap('Variant')}: $variant');

    if (model == 'ollama' && ollamaBaseUrl != null) {
      _logger.info('  ${lightCyan.wrap('Base URL')}: $ollamaBaseUrl');
    }

    _logger
      ..info(
          '  ${lightCyan.wrap('Confirm commits')}: ${confirmCommits ? 'enabled' : 'disabled'}')
      ..info(
          '  ${lightCyan.wrap('Allow emojis')}: ${allowEmojis ? 'enabled' : 'disabled'}')
      ..info(
          '  ${lightCyan.wrap('Always add')}: ${alwaysAdd ? 'enabled' : 'disabled'}');

    return ExitCode.success.code;
  }
}

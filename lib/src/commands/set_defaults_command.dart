//
//  gitwhisper
//  set_defaults_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/04.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';

class SetDefaultsCommand extends Command<int> {
  SetDefaultsCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser
      ..addOption(
        'model',
        abbr: 'm',
        help: 'AI model to save the key for',
        defaultsTo: 'openai',
        allowed: ['claude', 'openai', 'gemini', 'grok', 'llama'],
        mandatory: true,
      )
      ..addOption(
        'model-variant',
        abbr: 'v',
        help: 'Specific variant of the AI model to use',
        defaultsTo: 'gpt-4o',
        valueHelp: 'gpt-4o, claude-3-opus, gemini-pro, etc.',
        mandatory: true,
      );
  }

  @override
  String get description => 'Set defaults for future use';

  @override
  String get name => 'set-defaults';

  final Logger _logger;

  @override
  Future<int> run() async {
    final modelName = argResults?['model'] as String;
    final modelVariant = argResults?['model-variant'] as String;

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Save the API key
    configManager.setDefaults(modelName, modelVariant);
    await configManager.save();

    _logger.success(
      '$modelName -> $modelVariant has been set as the default model for'
      ' commits 🥳',
    );
    return ExitCode.success.code;
  }
}

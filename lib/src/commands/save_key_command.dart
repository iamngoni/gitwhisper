//
//  gitwhisper
//  save_key_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';

class SaveKeyCommand extends Command<int> {
  SaveKeyCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser
      ..addOption(
        'model',
        abbr: 'm',
        help: 'AI model to save the key for',
        defaultsTo: 'openai',
        allowed: [
          'claude',
          'openai',
          'gemini',
          'grok',
          'llama',
          'deepseek',
          'github',
        ],
      )
      ..addOption(
        'key',
        abbr: 'k',
        help: 'API key to save',
        mandatory: true,
      );
  }

  @override
  String get description => 'Save an API key for future use';

  @override
  String get name => 'save-key';

  final Logger _logger;

  @override
  Future<int> run() async {
    final modelName = argResults?['model'] as String;
    final apiKey = argResults?['key'] as String;

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Save the API key
    configManager.setApiKey(modelName, apiKey);
    await configManager.save();

    _logger.success('API key for $modelName saved successfully.');
    return ExitCode.success.code;
  }
}

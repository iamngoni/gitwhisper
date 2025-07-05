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
        allowed: [
          'claude',
          'openai',
          'gemini',
          'grok',
          'llama',
          'deepseek',
          'github',
          'ollama',
        ],
        mandatory: true,
      )
      ..addOption(
        'model-variant',
        abbr: 'v',
        help: 'Specific variant of the AI model to use',
        valueHelp: 'gpt-4o, claude-3-opus, gemini-pro, etc.',
      )
      ..addOption(
        'base-url',
        abbr: 'u',
        help: 'Base URL to use for ollama, defaults to http://localhost:11434',
        valueHelp: 'http://localhost:11434',
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
    final modelVariant = argResults?['model-variant'] as String?;
    final baseUrl = argResults?['base-url'] as String?;

    if (baseUrl != null && modelName != 'ollama') {
      throw ArgumentError('Base URL can only be set for Ollama');
    }

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    if (modelName != 'ollama') {
      if (modelVariant != null) {
        // Save the API key
        configManager.setDefaults(modelName, modelVariant);
        await configManager.save();
      }
    } else {
      // Save the API key
      if (modelVariant != null) {
        configManager.setDefaults(modelName, modelVariant);
        await configManager.save();
      }

      if (baseUrl != null) {
        configManager.setOllamaBaseURL(baseUrl);
        await configManager.save();
      }
    }

    if (modelVariant != null) {
      _logger.success(
        '$modelName -> $modelVariant has been set as the default model for'
        ' commits.',
      );
    }

    if (baseUrl != null) {
      _logger.success(
        '$modelName baseUrl has been set to $baseUrl.',
      );
    }
    return ExitCode.success.code;
  }
}

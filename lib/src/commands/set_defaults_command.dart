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
        allowedHelp: {
          'claude': 'Anthropic Claude',
          'openai': 'OpenAI GPT models',
          'gemini': 'Google Gemini',
          'grok': 'xAI Grok',
          'llama': 'Meta Llama',
          'deepseek': 'DeepSeek, Inc.',
          'github': 'Github',
          'ollama': 'Ollama',
        },
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
    // Get model name from args or prompt user to choose
    String? modelName = argResults?['model'] as String?;
    modelName ??= _logger.chooseOne(
      'Select the AI model to set as default:',
      choices: [
        'claude',
        'openai',
        'gemini',
        'grok',
        'llama',
        'deepseek',
        'github',
        'ollama',
      ],
      defaultValue: 'openai',
    );

    String? modelVariant = argResults?['model-variant'] as String?;
    String? baseUrl = argResults?['base-url'] as String?;

    // For Ollama, ask about base URL if not provided
    if (modelName == 'ollama' && baseUrl == null) {
      final bool customBaseUrl = _logger.confirm(
        'Do you want to set a custom base URL for Ollama?',
      );
      if (customBaseUrl) {
        baseUrl = _logger.prompt(
          'Enter the base URL for Ollama:',
          defaultValue: 'http://localhost:11434',
        );
      }
    }

    if (baseUrl != null && modelName != 'ollama') {
      _logger.err('Base URL can only be set for Ollama');
      return ExitCode.usage.code;
    }

    // Prompt for model variant if not provided
    if (modelVariant == null) {
      final bool setVariant = _logger.confirm(
        'Do you want to set a specific model variant for $modelName?',
      );
      if (setVariant) {
        modelVariant = _logger.prompt(
          'Enter the model variant (e.g., gpt-4o, claude-3-opus, gemini-pro):',
        );
        if (modelVariant.trim().isEmpty) {
          _logger.warn('No variant specified, skipping variant setting.');
          modelVariant = null;
        }
      }
    }

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    if (modelName != 'ollama') {
      if (modelVariant != null) {
        configManager.setDefaults(modelName!, modelVariant);
        await configManager.save();
      }
    } else {
      if (modelVariant != null) {
        configManager.setDefaults(modelName!, modelVariant);
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

    if (modelVariant == null && baseUrl == null) {
      _logger.info(
        'Default model set to $modelName (no specific variant or base URL configured).',
      );
    }

    return ExitCode.success.code;
  }
}

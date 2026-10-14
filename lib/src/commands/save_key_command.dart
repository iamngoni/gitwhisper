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
    ConfigManager? configManager,
  })  : _logger = logger,
        _configManager = configManager {
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
        'key',
        abbr: 'k',
        help: 'API key to save. Prefer omitting this to enter the key at a '
            'hidden prompt, which keeps it out of shell history and process '
            'listings.',
      );
  }

  @override
  String get description => 'Save an API key for future use';

  @override
  String get name => 'save-key';

  final Logger _logger;
  final ConfigManager? _configManager;

  @override
  Future<int> run() async {
    // Get model name from args or prompt user to choose
    String? modelName = argResults?['model'] as String?;
    modelName ??= _logger.chooseOne(
      'Select the AI model to save the key for:',
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

    // Get API key from args or prompt user to enter
    String? apiKey = argResults?['key'] as String?;
    if (apiKey != null) {
      _logger.warn(
        'Passing an API key with --key can leave it in your shell history '
        'and visible to other processes. Run `gw save-key` without --key to '
        'enter it at a hidden prompt instead.',
      );
      if (apiKey.trim().isEmpty) {
        _logger.err('API key cannot be empty.');
        return ExitCode.usage.code;
      }
    } else {
      if (modelName == 'ollama') {
        final bool needsKey = _logger.confirm(
          'Ollama typically runs locally and doesn\'t require an API key. Do you still want to set one?',
          defaultValue: false,
        );
        if (!needsKey) {
          _logger.info('No API key needed for Ollama. Configuration complete.');
          return ExitCode.success.code;
        }
      }

      apiKey = _logger.prompt(
        'Enter the API key for $modelName:',
        hidden: true,
      );

      if (apiKey.trim().isEmpty) {
        _logger.err('API key cannot be empty.');
        return ExitCode.usage.code;
      }
    }

    // Initialize config manager
    final configManager = _configManager ?? ConfigManager();
    await configManager.load();

    // Save the API key
    configManager.setApiKey(modelName!, apiKey);
    await configManager.save();

    _logger.success('API key for $modelName saved successfully.');
    return ExitCode.success.code;
  }
}

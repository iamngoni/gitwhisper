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
import '../template_manager.dart';

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
        ],
        mandatory: true,
      )
      ..addOption(
        'model-variant',
        abbr: 'v',
        help: 'Specific variant of the AI model to use',
        valueHelp: 'gpt-4o, claude-3-opus, gemini-pro, etc.',
        mandatory: true,
      )
      ..addOption(
        'template',
        abbr: 't',
        help: 'Default template to use',
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
    final templateName = argResults?['template'] as String?;

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Save the API key
    configManager.setDefaults(modelName, modelVariant);
    await configManager.saveConfig();
    _logger.success(
      '$modelName -> $modelVariant has been set as the default model for'
      ' commits 🥳',
    );

    if (templateName != null) {
      final templateManager = TemplateManager();

      // Verify template exists
      if (templateManager.getAllTemplates().containsKey(templateName)) {
        await configManager.setDefaultTemplate(templateName);
        _logger.info('Default template set to: $templateName');
      } else {
        _logger.err('Template "$templateName" not found');
        return ExitCode.usage.code;
      }
    }

    return ExitCode.success.code;
  }
}

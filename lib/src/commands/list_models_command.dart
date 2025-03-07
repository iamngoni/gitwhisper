//
//  gitwhisper
//  list_models_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

class ListModelsCommand extends Command<int> {
  ListModelsCommand({
    required Logger logger,
  }) : _logger = logger;

  @override
  String get description => 'List available AI models';

  @override
  String get name => 'list-models';

  final Logger _logger;

  @override
  Future<int> run() async {
    _logger
      ..info('Available models:')
      ..info('  - claude (Anthropic Claude)')
      ..info('  - openai (OpenAI GPT models)')
      ..info('  - gemini (Google Gemini)')
      ..info('  - grok (xAI Grok)')
      ..info('  - llama (Meta Llama)')
      ..info('  - deepseek (DeepSeek, Inc.)')
      ..info('  - github (GitHub)');
    return ExitCode.success.code;
  }
}

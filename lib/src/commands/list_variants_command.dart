//
//  gitwhisper
//  list_variants_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/02.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

class ListVariantsCommand extends Command<int> {
  ListVariantsCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser.addOption(
      'model',
      abbr: 'm',
      help: 'Model to list variants for',
      allowed: [
        'claude',
        'openai',
        'gemini',
        'grok',
        'llama',
        'deekseek',
        'github',
      ],
    );
  }

  @override
  String get description => 'List available variants for AI models';

  @override
  String get name => 'list-variants';

  final Logger _logger;

  @override
  Future<int> run() async {
    final model = argResults?['model'] as String?;

    if (model != null) {
      _listVariantsForModel(model);
    } else {
      _listAllVariants();
    }

    return ExitCode.success.code;
  }

  void _listVariantsForModel(String model) {
    _logger.info('Available variants for $model:');

    switch (model) {
      case 'openai':
        _logger.info('  - gpt-4 (default)');
        _logger.info('  - gpt-4-turbo-2024-04-09');
        _logger.info('  - gpt-4o');
        _logger.info('  - gpt-4o-mini');
        _logger.info('  - gpt-4.5-preview');
        _logger.info('  - gpt-3.5-turbo-0125');
        _logger.info('  - gpt-3.5-turbo-instruct');
        _logger.info('  - o1-preview');
        _logger.info('  - o1-mini');
        _logger.info('  - o3-mini');
      case 'claude':
        _logger.info('  - claude-sonnet-4-20250514 (default)');
        _logger.info('  - claude-opus-4-20250514');
        _logger.info('  - claude-3-7-sonnet-20250219');
        _logger.info('  - claude-3-7-sonnet-latest');
        _logger.info('  - claude-3-5-sonnet-latest');
        _logger.info('  - claude-3-opus-20240307');
        _logger.info('  - claude-3-sonnet-20240307');
        _logger.info('  - claude-3-haiku-20240307');
        _logger.info('  - claude-3-5-sonnet-20240620');
        _logger.info('  - claude-3-5-sonnet-20241022');
        _logger.info('  - claude-3-7-sonnet-20250219');
      case 'gemini':
        _logger.info('  - gemini-2.5-pro-preview-05-06 (advanced reasoning)');
        _logger.info('  - gemini-2.5-flash-preview-04-17 (adaptive thinking)');
        _logger.info('  - gemini-2.0-flash (default)');
        _logger.info('  - gemini-2.0-flash-lite (low latency)');
        _logger.info('  - gemini-1.5-pro-002 (2M tokens)');
        _logger.info('  - gemini-1.5-flash-002 (1M tokens)');
        _logger.info('  - gemini-1.5-flash-8b (cost effective)');
      case 'grok':
        _logger.info('  - grok-1 (default)');
        _logger.info('  - grok-2');
        _logger.info('  - grok-3');
        _logger.info('  - grok-2-mini');
      case 'llama':
        _logger.info('  - llama-3-70b-instruct (default)');
        _logger.info('  - llama-3-8b-instruct');
        _logger.info('  - llama-3.1-8b-instruct');
        _logger.info('  - llama-3.1-70b-instruct');
        _logger.info('  - llama-3.1-405b-instruct');
        _logger.info('  - llama-3.2-1b-instruct');
        _logger.info('  - llama-3.2-3b-instruct');
        _logger.info('  - llama-3.3-70b-instruct');
      case 'deepseek':
        _logger.info('  - deepseek-chat (default)');
        _logger.info('  - deepseek-reasoner');
      case 'github':
        _logger.info('  - gpt-4o (default)');
        _logger.info('  - DeepSeek-R1');
        _logger.info('  - Llama-3.3-70B-Instruct');
        _logger.info('  - Deepseek-V3');
        _logger.info('  - Phi-4-mini-instruct');
        _logger.info('  - Codestral 25.01');
        _logger.info('  - Mistral Large 24.11');
        _logger.info(
          '  - etc. Check more on https://github.com/marketplace?type=models',
        );
    }
  }

  void _listAllVariants() {
    _listVariantsForModel('openai');
    _logger.info('');
    _listVariantsForModel('claude');
    _logger.info('');
    _listVariantsForModel('gemini');
    _logger.info('');
    _listVariantsForModel('grok');
    _logger.info('');
    _listVariantsForModel('llama');
    _logger.info('');
    _listVariantsForModel('deepseek');
    _logger.info('');
    _listVariantsForModel('github');
  }
}

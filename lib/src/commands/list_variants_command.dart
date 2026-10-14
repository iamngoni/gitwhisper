//
//  gitwhisper
//  list_variants_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/02.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../models/model_variants.dart';

class ListVariantsCommand extends Command<int> {
  ListVariantsCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser.addOption(
      'model',
      abbr: 'm',
      help: 'Model to list variants for',
      allowed: models,
    );
  }

  /// Models this command lists, in display order.
  static const List<String> models = <String>[
    'claude',
    'claude-code',
    'codex',
    'openai',
    'gemini',
    'grok',
    'llama',
    'deepseek',
    'github',
    'ollama',
  ];

  /// Known variants other than the default, each with an optional note.
  ///
  /// Only models the provider documents as available are listed. The
  /// default comes from [ModelVariants] so the label can't drift.
  static const Map<String, List<(String, String?)>> _variants =
      <String, List<(String, String?)>>{
    'openai': <(String, String?)>[
      ('gpt-5.6-sol', null),
      ('gpt-5.6-luna', null),
      ('gpt-5.5', null),
      ('gpt-6-astra', null),
      ('gpt-6.1-sol', 'no agent mode: no tool calls on Chat Completions'),
      ('gpt-6-luna', 'no agent mode: tool calls need reasoning effort none'),
    ],
    'claude': <(String, String?)>[
      ('claude-opus-5-5', null),
      ('claude-fable-5-1', 'demanding reasoning'),
      ('claude-haiku-5-5', 'fastest'),
      ('claude-opus-4-8', null),
      ('claude-sonnet-4-6', null),
    ],
    'gemini': <(String, String?)>[
      ('gemini-3.8-flash', null),
      ('gemini-4-argon', 'most capable'),
      ('gemini-3.5-flash-lite', null),
      ('gemini-3.1-flash-lite', null),
      ('gemini-2.5-pro', 'only for accounts that already used it'),
      ('gemini-2.5-flash', 'only for accounts that already used it'),
    ],
    'grok': <(String, String?)>[
      ('grok-4.7', 'most capable'),
      ('grok-4.6', null),
      ('grok-4.5', null),
      ('grok-4.20-0309-reasoning', null),
      ('grok-4.20-0309-non-reasoning', null),
      ('grok-build-0.1', 'agentic coding'),
    ],
    'llama': <(String, String?)>[
      ('muse-spark-1.2', null),
      ('muse-spark-1.1', null),
    ],
    'deepseek': <(String, String?)>[
      ('deepseek-v4-pro', null),
    ],
  };

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

  /// The lines printed for [model], starting with its heading.
  static List<String> variantLines(String model) {
    final lines = <String>['Available variants for $model:'];

    if (model == 'github') {
      return lines
        ..add('  GitHub Models was retired on July 30, 2026. '
            'Use another provider.');
    }

    final defaultVariant = ModelVariants.getDefault(model);
    lines.add('  - $defaultVariant (default)');
    for (final (variant, note) in _variants[model] ?? <(String, String?)>[]) {
      if (variant == defaultVariant) continue;
      lines.add(note == null ? '  - $variant' : '  - $variant ($note)');
    }

    switch (model) {
      case 'claude-code':
        lines.add(
          '  Reads Claude Code local credentials; override with --model-variant.',
        );
      case 'codex':
        lines.add('  Reads Codex config/auth; override with --model-variant.');
      case 'ollama':
        final url = link(
          message: 'here.',
          uri: Uri.parse('https://ollama.com/search'),
        );
        lines.add('  Check Ollama models $url');
    }

    return lines;
  }

  void _listVariantsForModel(String model) {
    variantLines(model).forEach(_logger.info);
  }

  void _listAllVariants() {
    for (final (index, model) in models.indexed) {
      if (index > 0) _logger.info('');
      _listVariantsForModel(model);
    }
  }
}

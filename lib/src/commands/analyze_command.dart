//
//  gitwhisper
//  analyze_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/05/08.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';
import '../git_utils.dart';
import '../models/commit_generator_factory.dart';

class AnalyzeCommand extends Command<int> {
  AnalyzeCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser
      ..addOption(
        'model',
        abbr: 'm',
        help: 'AI model to use',
        allowed: [
          'claude',
          'openai',
          'gemini',
          'grok',
          'llama',
          'deepseek',
          'github',
        ],
        allowedHelp: {
          'claude': 'Anthropic Claude',
          'openai': 'OpenAI GPT models',
          'gemini': 'Google Gemini',
          'grok': 'xAI Grok',
          'llama': 'Meta Llama',
          'deepseek': 'DeepSeek, Inc.',
          'github': 'Github',
        },
      )
      ..addOption(
        'key',
        abbr: 'k',
        help: 'API key for the selected model',
      )
      ..addOption(
        'model-variant',
        abbr: 'v',
        help: 'Specific variant of the AI model to use',
        valueHelp: 'gpt-4o, claude-3-opus, gemini-pro, etc.',
      );
  }

  @override
  String get description => 'Generate an analysis based on file changes';

  @override
  String get name => 'analyze';

  final Logger _logger;

  @override
  Future<int> run() async {
    // Check if we're in a git repository
    if (!await GitUtils.isGitRepository()) {
      _logger.err('Not a git repository. Please run from a git repository.');
      return ExitCode.usage.code;
    }

    // Get the model name from args
    String? modelName = argResults?['model'] as String?;
    String? modelVariant = argResults?['model-variant'] as String?;

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // If modelName is not provided if a default model was set else default
    // to openai
    if (modelName == null) {
      final (String, String)? defaults =
          configManager.getDefaultModelAndVariant();
      if (defaults != null) {
        modelName = defaults.$1;
        modelVariant = defaults.$2;
      } else {
        modelName = 'openai';
      }
    }

    // Get API key (from args, config, or environment)
    var apiKey = argResults?['key'] as String?;
    apiKey ??=
        configManager.getApiKey(modelName) ?? _getEnvironmentApiKey(modelName);

    if (apiKey == null || apiKey.isEmpty) {
      _logger.err(
        'No API key provided for $modelName. Please provide an API key using'
        ' --key.',
      );
      return ExitCode.usage.code;
    }

    final hasStagedChanges = await GitUtils.hasStagedChanges();
    // Get the diff of staged changes
    late final String diff;

    if (hasStagedChanges) {
      _logger.info('Checking staged files for changes.');
      diff = await GitUtils.getStagedDiff();
    } else {
      _logger.info('Checking for changes in all unstaged files');
      diff = await GitUtils.getUnstagedDiff();
    }

    if (diff.isEmpty) {
      _logger.err('No changes detected in staged files.');
      return ExitCode.usage.code;
    }

    try {
      // Create the appropriate AI generator based on model name
      final generator = CommitGeneratorFactory.create(
        modelName,
        apiKey,
        variant: modelVariant,
      );

      _logger.info('Analyzing changes using $modelName'
          ' ${(modelVariant != null && modelVariant.isNotEmpty) ? ''
              '($modelVariant)' : ''}...');

      // Generate analysis with AI
      final analysis = await generator.analyzeChanges(diff);

      if (analysis.trim().isEmpty) {
        _logger.err('Error: Failed to generate analysis');
        return ExitCode.software.code;
      }

      _logger
        ..info('')
        ..success(analysis);

      return ExitCode.success.code;
    } catch (e) {
      _logger.err('Error analysing the changes: $e');
      return ExitCode.software.code;
    }
  }

  String? _getEnvironmentApiKey(String modelName) {
    return switch (modelName.toLowerCase()) {
      'claude' => Platform.environment['ANTHROPIC_API_KEY'],
      'openai' => Platform.environment['OPENAI_API_KEY'],
      'gemini' => Platform.environment['GEMINI_API_KEY'],
      'grok' => Platform.environment['GROK_API_KEY'],
      'llama' => Platform.environment['LLAMA_API_KEY'],
      'deepseek' => Platform.environment['DEEPSEEK_API_KEY'],
      _ => null,
    };
  }
}

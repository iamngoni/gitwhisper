//
//  gitwhisper
//  commit_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';
import '../git_utils.dart';
import '../models/commit_generator_factory.dart';

class CommitCommand extends Command<int> {
  CommitCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser
      ..addOption(
        'model',
        abbr: 'm',
        help: 'AI model to use',
        defaultsTo: 'openai',
        allowed: ['claude', 'openai', 'gemini', 'grok', 'llama'],
        allowedHelp: {
          'claude': 'Anthropic Claude',
          'openai': 'OpenAI GPT models',
          'gemini': 'Google Gemini',
          'grok': 'xAI Grok',
          'llama': 'Meta Llama',
        },
      )
      ..addOption(
        'key',
        abbr: 'k',
        help: 'API key for the selected model',
      )
      ..addOption(
        'prefix',
        abbr: 'p',
        help: 'Prefix to add to commit message (e.g., JIRA ticket number)',
        valueHelp: 'PREFIX-123',
      );
  }

  @override
  String get description => 'Generate a commit message based on staged changes';

  @override
  String get name => 'commit';

  final Logger _logger;

  @override
  Future<int> run() async {
    // Check if we're in a git repository
    if (!await GitUtils.isGitRepository()) {
      _logger.err('Not a git repository. Please run from a git repository.');
      return ExitCode.usage.code;
    }

    // Check if there are staged changes
    if (!await GitUtils.hasStagedChanges()) {
      _logger.err(
        'No staged changes found. Please stage your changes using `git add`'
        ' first.',
      );
      return ExitCode.usage.code;
    }

    // Get the model name from args
    final modelName = argResults?['model'] as String;
    final modelVariant = argResults?['model-variant'] as String?;

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

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

    // Get prefix if available for things like ticket numbers
    final prefix = argResults?['prefix'] as String?;

    // Get the diff of staged changes
    final diff = await GitUtils.getStagedDiff();
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

      _logger.info('Analyzing staged changes using $modelName'
          ' ${(modelVariant != null && modelVariant.isNotEmpty) ? ''
              '($modelVariant)' : ''}...');

      // Generate commit message with AI
      final rawCommitMessage = await generator.generateCommitMessage(diff);

      // Apply prefix if available
      final commitMessage =
          formatCommitMessageWithPrefix(rawCommitMessage, prefix);

      if (commitMessage.trim().isEmpty) {
        _logger.err('Error: Generated commit message is empty');
        return ExitCode.software.code;
      }

      _logger
        ..info('')
        ..info('---------------------------------')
        ..info('')
        ..info(commitMessage)
        ..info('')
        ..info('---------------------------------')
        ..info('');

      try {
        await GitUtils.runGitCommit(commitMessage);
        _logger.success('Commit successful! 🎉');
      } catch (e) {
        _logger.err('Error setting commit message: $e');
        return ExitCode.software.code;
      }

      return ExitCode.success.code;
    } catch (e) {
      _logger.err('Error generating commit message: $e');
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
      _ => null,
    };
  }

  /// Formats a commit message with an optional prefix
  ///
  /// If prefix is provided, inserts it after the type/scope section
  /// Example: "feat(ui): add button" becomes "feat(ui): PREFIX-123 -> add button"
  String formatCommitMessageWithPrefix(String message, String? prefix) {
    if (prefix == null || prefix.isEmpty) {
      return message;
    }

    // Check if the message follows conventional commit format
    final conventionalCommitRegex = RegExp(r'^(\w+)(\([^)]+\))?: (.+)$');
    final match = conventionalCommitRegex.firstMatch(message);

    if (match != null) {
      // Extract parts of the conventional commit
      final type = match.group(1);
      final scope = match.group(2) ?? '';
      final description = match.group(3) ?? '';

      // Format with prefix
      return '$type$scope: $prefix -> $description';
    } else {
      // If not conventional format, just prepend the prefix
      return '$prefix -> $message';
    }
  }
}

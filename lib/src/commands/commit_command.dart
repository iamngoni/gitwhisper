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
import '../template_manager.dart';

class CommitCommand extends Command<int> {
  CommitCommand({
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
        'prefix',
        abbr: 'p',
        help: 'Prefix to add to commit message (e.g., JIRA ticket number)',
        valueHelp: 'PREFIX-123',
      )
      ..addOption(
        'model-variant',
        abbr: 'v',
        help: 'Specific variant of the AI model to use',
        valueHelp: 'gpt-4o, claude-3-opus, gemini-pro, etc.',
      )
      ..addOption(
        'template',
        abbr: 't',
        help: 'Template to use for commit message formatting',
        defaultsTo: 'default',
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
    String? modelName = argResults?['model'] as String?;
    String? modelVariant = argResults?['model-variant'] as String?;

    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Get template to use
    final String templateName = argResults?['template'] as String? ??
        configManager.getDefaultTemplate() ??
        'default';

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

      final progress =
          _logger.progress('Analyzing staged changes using $modelName'
              ' ${(modelVariant != null && modelVariant.isNotEmpty) ? ''
                  '($modelVariant)' : ''}...');

      // Generate commit message with AI
      final rawCommitMessage = await generator.generateCommitMessage(diff);

      // Parse the raw commit message to extract components
      final components = parseCommitMessage(rawCommitMessage);

      progress.update('Applying template...');

      // Apply template
      final templateManager = TemplateManager();
      final template = templateManager.getTemplate(templateName);
      final formattedMessage = applyTemplate(
        template,
        components,
        prefix: prefix,
      );
      progress
        ..update('Template applied!')
        ..complete();

      if (formattedMessage.trim().isEmpty) {
        _logger.err('Error: Generated commit message is empty');
        return ExitCode.software.code;
      }

      _logger
        ..info('')
        ..info('---------------------------------')
        ..info('')
        ..info(formattedMessage)
        ..info('')
        ..info('---------------------------------')
        ..info('');

      try {
        await GitUtils.runGitCommit(formattedMessage);
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

  /// Parse commit message to extract components
  Map<String, String> parseCommitMessage(String message) {
    final result = <String, String>{};

    // Enhanced conventional commit regex to capture type, scope, emoji and description
    // format: type(scope): emoji description
    final regex = RegExp(r'^(\w+)(?:\(([^)]+)\))?: (?:([^\s]+) )?(.+)$');
    final match = regex.firstMatch(message);

    if (match != null) {
      result['type'] = match.group(1) ?? '';
      // Capture scope if present
      result['scope'] = match.group(2) ?? '';

      // Check if there's an emoji
      final possibleEmoji = match.group(3) ?? '';
      final description = match.group(4) ?? '';

      // Simple emoji detection
      if (RegExp(r'[\p{Emoji}]', unicode: true).hasMatch(possibleEmoji)) {
        result['emoji'] = possibleEmoji;
        result['description'] = description;
      } else {
        result['emoji'] = '';
        result['description'] = '$possibleEmoji $description'.trim();
      }
    } else {
      // Fallback for non-conventional formats
      result['type'] = '';
      result['scope'] = '';
      result['emoji'] = '';
      result['description'] = message;
    }

    return result;
  }

  /// Apply template to commit components
  String applyTemplate(
    String template,
    Map<String, String> components, {
    String? prefix,
  }) {
    var result = template;

    // Replace placeholders with actual values
    for (final entry in components.entries) {
      result = result.replaceAll('{{${entry.key}}}', entry.value);
    }

    // Handle prefix if provided
    if (prefix != null && prefix.isNotEmpty) {
      result = result.replaceAll('{{prefix}}', prefix);
    } else {
      // Remove optional prefix pattern if no prefix
      result = result.replaceAll(RegExp(r'\{\{prefix\}\} ?'), '');
    }

    // Remove any remaining placeholders
    result = result.replaceAll(RegExp(r'\{\{[^}]+\}\}'), '');

    // Clean up empty structures
    // Remove empty brackets: []
    result = result.replaceAll(RegExp(r'\[\s*\]'), '');

    // Remove empty parentheses: ()
    result = result.replaceAll(RegExp(r'\(\s*\)'), '');

    // Remove double spaces
    result = result.replaceAll(RegExp(r' +'), ' ');

    // Cleanup any leftover structural patterns
    // Fix patterns like "type: -> description" (when prefix is missing but format expects it)
    result = result.replaceAll(RegExp(r': +-> +'), ': ');

    // Fix patterns like "type: : description" (duplicate colons)
    result = result.replaceAll(RegExp(r': *:'), ':');

    // Trim whitespace
    result = result.trim();

    return result;
  }
}

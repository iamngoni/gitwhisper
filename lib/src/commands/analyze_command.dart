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
import 'package:path/path.dart' as path;

import '../config_manager.dart';
import '../exceptions/exceptions.dart';
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
          'ollama',
          'free',
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
          'free': 'Free (LLM7.io) - No API key required',
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

  final Logger _logger;

  @override
  String get description => 'Generate an analysis based on file changes';

  @override
  String get name => 'analyze';

  @override
  Future<int> run() async {
    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    // Get the language to use for analysis
    final language = configManager.getWhisperLanguage();

    List<String>? subGitRepos;

    // Check if we're in a git repository; if not, check subfolders
    if (!await GitUtils.isGitRepository()) {
      _logger
          .warn('Not a git repository. Checking subfolders for git repos...');
      subGitRepos = await GitUtils.findGitReposInSubfolders();
      if (subGitRepos.isEmpty) {
        _logger.err(
            'No git repository found in subfolders. Please run from a git repository.');
        return ExitCode.usage.code;
      }
    }

    final bool hasSubGitRepos = subGitRepos != null;

    if (hasSubGitRepos) {
      final String response = _logger.chooseOne(
        'GitWhisper has discovered git repositories in subfolders but not in this'
        ' current folder, would you like to continue?',
        choices: ['continue', 'abort'],
        defaultValue: 'continue',
      );

      if (response == 'abort') {
        return ExitCode.usage.code;
      }
    }

    // Get the model name and variant from args, config, or defaults
    String? modelName = argResults?['model'] as String?;
    String? modelVariant = argResults?['model-variant'] as String? ?? '';

    // If modelName is not provided, use config or prompt user
    if (modelName == null) {
      final (String, String)? defaults =
          configManager.getDefaultModelAndVariant();
      if (defaults != null) {
        modelName = defaults.$1;
        modelVariant = defaults.$2;
      } else {
        // Prompt user to select model
        modelName = _logger.chooseOne(
          'Select the AI model for analysis:',
          choices: [
            'claude',
            'openai',
            'gemini',
            'grok',
            'llama',
            'deepseek',
            'github',
            'ollama',
            'free',
          ],
          defaultValue: 'openai',
        );
      }
    }

    // Get API key (from args, config, or environment)
    var apiKey = argResults?['key'] as String?;
    apiKey ??=
        configManager.getApiKey(modelName!) ?? _getEnvironmentApiKey(modelName);

    if ((apiKey == null || apiKey.isEmpty) &&
        modelName != 'ollama' &&
        modelName != 'free') {
      _logger.err(
        'No API key provided for $modelName. Please provide an API key using --key or save one using "gw save-key".',
      );
      return ExitCode.usage.code;
    }

    // Show disclaimer for free model on first use
    if (modelName == 'free' && !configManager.hasAcceptedFreeDisclaimer()) {
      _logger
        ..info('')
        ..info(
            '┌─────────────────────────────────────────────────────────────┐')
        ..info(
            '│                    FREE MODEL DISCLAIMER                    │')
        ..info(
            '├─────────────────────────────────────────────────────────────┤')
        ..info(
            '│ This free model is powered by LLM7.io - a third-party       │')
        ..info(
            '│ service providing free, anonymous access to AI models.      │')
        ..info(
            '│                                                             │')
        ..info(
            '│ Anonymous tier limits:                                      │')
        ..info(
            '│ • 8k chars per request                                      │')
        ..info(
            '│ • 60 requests/hour, 10 requests/min, 1 request/sec          │')
        ..info(
            '│                                                             │')
        ..info(
            '│ Please note:                                                │')
        ..info(
            '│ • Your code diffs will be sent to LLM7.io servers           │')
        ..info(
            '│ • Service availability is not guaranteed                    │')
        ..info(
            '│ • For production use, consider a paid API provider          │')
        ..info(
            '│                                                             │')
        ..info(
            '│ Learn more: https://llm7.io                                 │')
        ..info(
            '└─────────────────────────────────────────────────────────────┘')
        ..info('');

      final response = _logger.chooseOne(
        'Do you accept these terms and wish to continue?',
        choices: ['yes', 'no'],
        defaultValue: 'yes',
      );

      if (response == 'no') {
        _logger.info('Free model usage cancelled.');
        return ExitCode.usage.code;
      }

      // Save acceptance so we don't show again
      configManager.setFreeDisclaimerAccepted();
      await configManager.save();
      _logger.success('Disclaimer accepted. You won\'t see this again.');
    }

    // Create the appropriate AI generator based on model name
    final generator = CommitGeneratorFactory.create(
      modelName!,
      apiKey,
      variant: modelVariant,
    );

    if (!hasSubGitRepos) {
      // --- Single repo flow ---
      final hasStagedChanges = await GitUtils.hasStagedChanges();
      late final String diff;

      if (hasStagedChanges) {
        _logger.info('Checking staged files for changes.');
        diff = await GitUtils.getStagedDiff();
      } else {
        _logger.info('Checking for changes in all unstaged files.');
        diff = await GitUtils.getUnstagedDiff();
      }

      if (diff.isEmpty) {
        _logger.err('No changes detected in staged or unstaged files.');
        return ExitCode.usage.code;
      }

      try {
        _logger.info('Analyzing changes using $modelName'
            '${modelVariant.isNotEmpty ? ' ($modelVariant)' : ''}...');

        // Generate analysis with AI
        final analysis = await generator.analyzeChanges(diff, language);

        if (analysis.trim().isEmpty) {
          _logger.err('Error: Failed to generate analysis');
          return ExitCode.software.code;
        }

        _logger
          ..info('')
          ..success(analysis);

        return ExitCode.success.code;
      } on ApiException catch (e) {
        ErrorHandler.handleErrorWithRetry(
          e,
          context: 'analyzing changes',
        );

        if (ErrorHandler.shouldSuggestModelSwitch(e)) {
          final suggestions = ErrorHandler.getModelSwitchSuggestions(e);
          ErrorHandler.handleErrorWithFallback(
            e,
            fallbackOptions: suggestions,
          );
        }

        return ExitCode.software.code;
      } catch (e) {
        ErrorHandler.handleGeneralError(
          e as Exception,
          context: 'analyzing changes',
        );
        return ExitCode.software.code;
      }
    } else {
      // --- Multi-repo flow ---
      int successCount = 0;
      final List<String> failedRepos = [];
      final foldersWithChanges = <String>[];

      // Only process repos with staged or unstaged changes
      for (final repo in subGitRepos) {
        final hasStaged = await GitUtils.hasStagedChanges(folderPath: repo);
        final hasUnstaged = await GitUtils.hasUnstagedChanges(folderPath: repo);

        if (hasStaged || hasUnstaged) {
          foldersWithChanges.add(repo);
        }
      }

      if (foldersWithChanges.isEmpty) {
        _logger.err('No changes detected in any subfolder repositories.');
        return ExitCode.usage.code;
      }

      for (final repo in foldersWithChanges) {
        final repoName = path.basename(repo);
        String diff = '';
        bool usedStaged = false;

        if (await GitUtils.hasStagedChanges(folderPath: repo)) {
          diff = await GitUtils.getStagedDiff(folderPath: repo);
          usedStaged = true;
        } else if (await GitUtils.hasUnstagedChanges(folderPath: repo)) {
          diff = await GitUtils.getUnstagedDiff(folderPath: repo);
        }

        if (diff.isEmpty) {
          _logger.warn('[$repoName] No changes detected, skipping.');
          continue;
        }

        try {
          _logger.info(
              '[$repoName] Analyzing ${usedStaged ? 'staged' : 'unstaged'} changes using $modelName'
              '${modelVariant.isNotEmpty ? ' ($modelVariant)' : ''}...');

          final analysis = await generator.analyzeChanges(diff, language);

          if (analysis.trim().isEmpty) {
            _logger.err('[$repoName] Error: Failed to generate analysis');
            failedRepos.add(repoName);
            continue;
          }

          _logger
            ..info('\n----------- $repoName -----------\n')
            ..success(analysis)
            ..info('\n----------------------------------\n');

          successCount++;
        } on ApiException catch (e) {
          _logger.err('[$repoName] ${ErrorHandler.getErrorSummary(e)}');
          failedRepos.add(repoName);
          continue;
        } catch (e) {
          _logger.err('[$repoName] Error analyzing the changes: $e');
          failedRepos.add(repoName);
          continue;
        }
      }

      if (failedRepos.isNotEmpty) {
        _logger.err('Analysis failed in: ${failedRepos.join(', ')}');
      }
      _logger.success('Analysis complete for $successCount git repos.');
      return failedRepos.isEmpty
          ? ExitCode.success.code
          : ExitCode.software.code;
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

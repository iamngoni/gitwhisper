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
import 'package:path/path.dart' as path;

import '../config_manager.dart';
import '../exceptions/exceptions.dart';
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
      ..addFlag(
        'auto-push',
        abbr: 'a',
        help: 'Automatically push the commit to the remote repository',
      );
  }

  @override
  String get description => 'Generate a commit message based on staged changes';

  @override
  String get name => 'commit';

  final Logger _logger;

  /// Runs the commit process, handling both single and multi-repo scenarios.
  /// Returns an appropriate exit code.
  @override
  Future<int> run() async {
    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    List<String>? subGitRepos;

    // Check if we're in a git repository
    if (!await GitUtils.isGitRepository()) {
      _logger.warn('Not a git repository. Checking subfolders...');

      subGitRepos = await GitUtils.findGitReposInSubfolders();
      if (subGitRepos.isEmpty) {
        _logger.err(
          'No git repository found in subfolders. Please run in a git repository, '
          'or initialize one with `git init`.',
        );
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

    final bool hasStagedChanges = !hasSubGitRepos
        ? await GitUtils.hasStagedChanges()
        : (await GitUtils.foldersWithStagedChanges(subGitRepos)).isNotEmpty;

    // Check if there are staged changes
    if (!hasStagedChanges) {
      // Check if we should always add unstaged files
      if (configManager.shouldAlwaysAdd()) {
        // Check for unstaged changes
        final hasUnstagedChanges = !hasSubGitRepos
            ? await GitUtils.hasUnstagedChanges()
            : (await GitUtils.foldersWithUnstagedChanges(subGitRepos))
                .isNotEmpty;

        if (hasUnstagedChanges) {
          _logger.info(
              'Unstaged changes found. Staging all changes and new files...');
          if (!hasSubGitRepos) {
            final int stagedFiles =
                await GitUtils.stageAllUnstagedFilesAndCount();
            _logger.success('$stagedFiles files have been staged.');
          } else {
            final List<String> foldersWithUnstagedChanges =
                await GitUtils.foldersWithUnstagedChanges(subGitRepos);
            for (final f in foldersWithUnstagedChanges) {
              final int stagedFiles =
                  await GitUtils.stageAllUnstagedFilesAndCount(folderPath: f);
              final folderName = path.basename(f);
              _logger.success(
                  '[$folderName] $stagedFiles files have been staged.');
            }
          }
        } else {
          _logger.err('No staged or unstaged changes found!');
          return ExitCode.usage.code;
        }
      } else {
        _logger.err(
          'No staged changes found. Please stage your changes using `git add` first.',
        );
        return ExitCode.usage.code;
      }
    }

    // Get the model name and variant from args, config, or defaults
    String? modelName = argResults?['model'] as String?;
    String? modelVariant = argResults?['model-variant'] as String? ?? '';

    // If modelName is not provided, use config or fallback to openai
    if (modelName == null) {
      final (String, String)? defaults =
          configManager.getDefaultModelAndVariant();
      if (defaults != null) {
        modelName = defaults.$1;
        modelVariant = defaults.$2;
      } else {
        modelName = 'openai';
        modelVariant = '';
      }
    }

    // Get API key (from args, config, or environment)
    var apiKey = argResults?['key'] as String?;
    apiKey ??=
        configManager.getApiKey(modelName) ?? _getEnvironmentApiKey(modelName);

    if ((apiKey == null || apiKey.isEmpty) && modelName != 'ollama') {
      _logger.err(
        'No API key provided for $modelName. Please provide an API key using --key.',
      );
      return ExitCode.usage.code;
    }

    // Get prefix if available for things like ticket numbers
    final prefix = argResults?['prefix'] as String?;

    // Handle --auto-push, fallback to false if not provided
    final autoPush = (argResults?['auto-push'] as bool?) ?? false;

    // Get ollamaBaseUrl from configs
    final String? ollamaBaseUrl = configManager.getOllamaBaseURL();

    // Create the appropriate AI generator based on model name
    final generator = CommitGeneratorFactory.create(
      modelName,
      apiKey,
      variant: modelVariant,
      baseUrl: ollamaBaseUrl ?? 'http://localhost:11434',
    );

    // --- Single repo flow ---
    if (!hasSubGitRepos) {
      final diff = await GitUtils.getStagedDiff();
      if (diff.isEmpty) {
        _logger.err('No changes detected in staged files.');
        return ExitCode.usage.code;
      }

      try {
        _logger.info('Analyzing staged changes using $modelName'
            '${modelVariant.isNotEmpty ? ' ($modelVariant)' : ''}'
            '${prefix != null ? ' for ticket $prefix' : ''}...');

        // Generate commit message with AI
        String commitMessage = await generator.generateCommitMessage(
          diff,
          prefix: prefix,
        );

        try {
          commitMessage = GitUtils.stripMarkdownCodeBlocks(commitMessage);
        } catch (_) {
          // Silent prayer that it works
        }

        if (commitMessage.trim().isEmpty) {
          _logger.err('Error: Generated commit message is empty');
          return ExitCode.software.code;
        }

        _logger
          ..info('\n---------------------------------\n')
          ..info(commitMessage)
          ..info('\n---------------------------------\n');

        try {
          await GitUtils.runGitCommit(
            message: commitMessage,
            autoPush: autoPush,
          );
        } catch (e) {
          _logger.err('Error setting commit message: $e');
          return ExitCode.software.code;
        }

        return ExitCode.success.code;
      } on ApiException catch (e) {
        ErrorHandler.handleErrorWithRetry(
          e,
          context: 'generating commit message',
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
          context: 'generating commit message',
        );
        return ExitCode.software.code;
      }
    } else {
      // --- Multi-repo flow ---
      final foldersWithStagedChanges =
          await GitUtils.foldersWithStagedChanges(subGitRepos);
      _logger.info('Working in ${foldersWithStagedChanges.length} git repos');

      int successCount = 0;
      final List<String> failedRepos = [];

      for (final f in foldersWithStagedChanges) {
        final folderName = path.basename(f);
        final diff = await GitUtils.getStagedDiff(folderPath: f);
        if (diff.isEmpty) {
          _logger.warn(
              '[$folderName] No changes detected in staged files, skipping.');
          continue;
        }

        try {
          _logger.info('[$folderName] Analyzing staged changes using $modelName'
              '${modelVariant.isNotEmpty ? ' ($modelVariant)' : ''}'
              '${prefix != null ? ' for ticket $prefix' : ''}...');

          // Generate commit message with AI
          String commitMessage = await generator.generateCommitMessage(
            diff,
            prefix: prefix,
          );

          try {
            commitMessage = GitUtils.stripMarkdownCodeBlocks(commitMessage);
          } catch (_) {
            // Silent prayer that it works
          }

          if (commitMessage.trim().isEmpty) {
            _logger
                .err('[$folderName] Error: Generated commit message is empty');
            failedRepos.add(folderName);
            continue;
          }

          _logger
            ..info('\n----------- $folderName -----------\n')
            ..info(commitMessage)
            ..info('\n-----------------------------------\n');

          try {
            await GitUtils.runGitCommit(
              message: commitMessage,
              autoPush: autoPush,
              folderPath: f,
            );
            successCount++;
          } catch (e) {
            _logger.err('[$folderName] Error setting commit message: $e');
            failedRepos.add(folderName);
            continue;
          }
        } on ApiException catch (e) {
          _logger.err('[$folderName] ${ErrorHandler.getErrorSummary(e)}');
          failedRepos.add(folderName);
          continue;
        } catch (e) {
          _logger.err('[$folderName] Error generating commit message: $e');
          failedRepos.add(folderName);
          continue;
        }
      }

      if (failedRepos.isNotEmpty) {
        _logger.err('Failed in: ${failedRepos.join(', ')}');
      }

      if (successCount == 1) {
        _logger.success('Processed 1 git repository.');
      } else {
        _logger.success('Processed $successCount git repositories.');
      }

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

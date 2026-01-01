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
import '../models/commit_generator.dart';
import '../models/commit_generator_factory.dart';
import '../models/language.dart';

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
      )
      ..addFlag(
        'confirm',
        abbr: 'c',
        help: 'Confirm commit message before applying',
      )
      ..addOption(
        'tag',
        abbr: 't',
        help: 'Create a git tag for this commit',
        valueHelp: 'v1.0.0',
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
            'Unstaged changes found. Staging all changes and new files...',
          );
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
                '[$folderName] $stagedFiles files have been staged.',
              );
            }
          }
        } else {
          _logger.err('No staged or unstaged changes found!');
          return ExitCode.usage.code;
        }
      } else {
        // Check for unstaged or untracked changes
        final hasUnstagedChanges = !hasSubGitRepos
            ? await GitUtils.hasUnstagedChanges()
            : (await GitUtils.foldersWithUnstagedChanges(subGitRepos))
                .isNotEmpty;

        final hasUntrackedFiles = !hasSubGitRepos
            ? await GitUtils.hasUntrackedFiles()
            : (await GitUtils.foldersWithUntrackedFiles(subGitRepos))
                .isNotEmpty;

        if (hasUnstagedChanges || hasUntrackedFiles) {
          final String response = _logger.chooseOne(
            'No staged changes found, but there are ${hasUnstagedChanges ? 'unstaged changes' : ''}${hasUnstagedChanges && hasUntrackedFiles ? ' and ' : ''}${hasUntrackedFiles ? 'untracked files' : ''}. Would you like to stage them and continue?',
            choices: ['yes', 'no'],
            defaultValue: 'yes',
          );

          if (response == 'yes') {
            _logger.info('Staging all changes and new files...');
            if (!hasSubGitRepos) {
              final int stagedFiles =
                  await GitUtils.stageAllUnstagedFilesAndCount();
              _logger.success('$stagedFiles files have been staged.');
            } else {
              final List<String> foldersWithChanges = <String>[];
              if (hasUnstagedChanges) {
                foldersWithChanges.addAll(
                  await GitUtils.foldersWithUnstagedChanges(subGitRepos),
                );
              }
              if (hasUntrackedFiles) {
                foldersWithChanges.addAll(
                  await GitUtils.foldersWithUntrackedFiles(subGitRepos),
                );
              }
              // Remove duplicates
              final uniqueFolders = foldersWithChanges.toSet().toList();

              for (final f in uniqueFolders) {
                final int stagedFiles =
                    await GitUtils.stageAllUnstagedFilesAndCount(folderPath: f);
                final folderName = path.basename(f);
                _logger.success(
                  '[$folderName] $stagedFiles files have been staged.',
                );
              }
            }
          } else {
            return ExitCode.usage.code;
          }
        } else {
          _logger.err('No staged, unstaged, or untracked changes found!');
          return ExitCode.usage.code;
        }
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

    if ((apiKey == null || apiKey.isEmpty) &&
        modelName != 'ollama' &&
        modelName != 'free') {
      _logger.err(
        'No API key provided for $modelName. Please provide an API key using --key.',
      );
      return ExitCode.usage.code;
    }

    // Show disclaimer for free model on first use
    if (modelName == 'free' && !configManager.hasAcceptedFreeDisclaimer()) {
      _logger
        ..info('')
        ..info(
          '┌─────────────────────────────────────────────────────────────┐',
        )
        ..info(
          '│                    FREE MODEL DISCLAIMER                    │',
        )
        ..info(
          '├─────────────────────────────────────────────────────────────┤',
        )
        ..info(
          '│ This free model is powered by LLM7.io - a third-party       │',
        )
        ..info(
          '│ service providing free, anonymous access to AI models.      │',
        )
        ..info(
          '│                                                             │',
        )
        ..info(
          '│ Anonymous tier limits:                                      │',
        )
        ..info(
          '│ • 8k chars per request                                      │',
        )
        ..info(
          '│ • 60 requests/hour, 10 requests/min, 1 request/sec          │',
        )
        ..info(
          '│                                                             │',
        )
        ..info(
          '│ Please note:                                                │',
        )
        ..info(
          '│ • Your code diffs will be sent to LLM7.io servers           │',
        )
        ..info(
          '│ • Service availability is not guaranteed                    │',
        )
        ..info(
          '│ • For production use, consider a paid API provider          │',
        )
        ..info(
          '│                                                             │',
        )
        ..info(
          '│ Learn more: https://llm7.io                                 │',
        )
        ..info(
          '└─────────────────────────────────────────────────────────────┘',
        )
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
      _logger.success("Disclaimer accepted. You won't see this again.");
    }

    // Get prefix if available for things like ticket numbers
    final prefix = argResults?['prefix'] as String?;

    // Get tag if provided
    final tag = argResults?['tag'] as String?;

    // Handle --auto-push, fallback to false if not provided
    final autoPush = (argResults?['auto-push'] as bool?) ?? false;

    // Handle --confirm, fallback to global config, then false
    // Check if --confirm or --no-confirm was explicitly provided
    final confirm = argResults?.wasParsed('confirm') ?? false
        ? (argResults?['confirm'] as bool)
        : configManager.shouldConfirmCommits();

    // Get ollamaBaseUrl from configs
    final String? ollamaBaseUrl = configManager.getOllamaBaseURL();

    // Create the appropriate AI generator based on model name
    final generator = CommitGeneratorFactory.create(
      modelName,
      apiKey,
      variant: modelVariant,
      baseUrl: ollamaBaseUrl ?? 'http://localhost:11434',
    );

    // Get the language to use for commit messages
    final language = configManager.getWhisperLanguage();

    // Get emoji setting
    final withEmoji = configManager.shouldAllowEmojis();

    // --- Single repo flow ---
    if (!hasSubGitRepos) {
      final diff = await GitUtils.getStagedDiff();
      if (diff.isEmpty) {
        _logger.err('No changes detected in staged files.');
        return ExitCode.usage.code;
      }

      // Check if diff is too large and suggest interactive staging
      if (GitUtils.isDiffTooLarge(diff,
          maxSize: configManager.getMaxDiffSize())) {
        _logger.warn(
            '\n⚠️  Large diff detected (${GitUtils.estimateDiffSize(diff)} characters)\n');

        final choice = _logger.chooseOne(
          '💡 Large diffs can result in poor commit message quality',
          choices: [
            'Use interactive staging for focused commits',
            'Commit all changes together anyway',
            'Cancel',
          ],
        );

        switch (choice) {
          case 'Use interactive staging for focused commits':
            return _handleInteractiveStaging(
              generator,
              language,
              prefix,
              withEmoji,
              autoPush,
              tag,
              !confirm,
            );
          case 'Commit all changes together anyway':
            // Continue with normal flow
            break;
          case 'Cancel':
            _logger.info('Commit cancelled.');
            return ExitCode.success.code;
        }
      }

      try {
        _logger.info('Analyzing staged changes using $modelName'
            '${modelVariant.isNotEmpty ? ' ($modelVariant)' : ''}'
            '${prefix != null ? ' for ticket $prefix' : ''}...');

        // Generate commit message with AI
        String commitMessage = await generator.generateCommitMessage(
          diff,
          language,
          prefix: prefix,
          withEmoji: withEmoji,
        );

        try {
          commitMessage = GitUtils.stripMarkdownCodeBlocks(commitMessage);
        } catch (_) {
          // Silent prayer that it works
        }

        if (commitMessage.trim().isEmpty) {
          _logger.err('Error: Generated commit message is empty!');
          return ExitCode.software.code;
        }

        // Handle confirmation workflow if enabled
        if (confirm) {
          final finalMessage = await _handleCommitConfirmation(
            commitMessage: commitMessage,
            generator: generator,
            diff: diff,
            language: language,
            prefix: prefix,
            modelName: modelName,
            modelVariant: modelVariant,
            ollamaBaseUrl: ollamaBaseUrl,
            configManager: configManager,
            withEmoji: withEmoji,
          );

          if (finalMessage == null) {
            // User cancelled
            return ExitCode.usage.code;
          }

          commitMessage = finalMessage;
        } else {
          // Show message without confirmation
          _logger
            ..info('\n---------------------------------\n')
            ..info(commitMessage)
            ..info('\n---------------------------------\n');
        }

        try {
          await GitUtils.runGitCommit(
            message: commitMessage,
            autoPush: autoPush,
            tag: tag,
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
            '[$folderName] No changes detected in staged files, skipping.',
          );
          continue;
        }

        try {
          _logger.info('[$folderName] Analyzing staged changes using $modelName'
              '${modelVariant.isNotEmpty ? ' ($modelVariant)' : ''}'
              '${prefix != null ? ' for ticket $prefix' : ''}...');

          // Generate commit message with AI
          String commitMessage = await generator.generateCommitMessage(
            diff,
            language,
            prefix: prefix,
            withEmoji: withEmoji,
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

          // Handle confirmation workflow if enabled
          if (confirm) {
            _logger.info('[$folderName] Review commit message:');
            final finalMessage = await _handleCommitConfirmation(
              commitMessage: commitMessage,
              generator: generator,
              diff: diff,
              language: language,
              prefix: prefix,
              modelName: modelName,
              modelVariant: modelVariant,
              ollamaBaseUrl: ollamaBaseUrl,
              configManager: configManager,
              withEmoji: withEmoji,
            );

            if (finalMessage == null) {
              // User cancelled this repo
              _logger.warn('[$folderName] Commit cancelled by user.');
              failedRepos.add(folderName);
              continue;
            }

            commitMessage = finalMessage;
          } else {
            // Show message without confirmation
            _logger
              ..info('\n----------- $folderName -----------\n')
              ..info(commitMessage)
              ..info('\n-----------------------------------\n');
          }

          try {
            await GitUtils.runGitCommit(
              message: commitMessage,
              autoPush: autoPush,
              folderPath: f,
              tag: tag,
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

  /// Handles the confirmation workflow for commit messages
  /// Returns the final commit message to use, or null if user cancelled
  Future<String?> _handleCommitConfirmation({
    required String commitMessage,
    required CommitGenerator generator,
    required String diff,
    required Language language,
    required String? prefix,
    required String modelName,
    required String modelVariant,
    required String? ollamaBaseUrl,
    required ConfigManager configManager,
    required bool withEmoji,
  }) async {
    String currentMessage = commitMessage;

    while (true) {
      _logger
        ..info('\n---------------------------------\n')
        ..info(currentMessage)
        ..info('\n---------------------------------\n');

      final action = _logger.chooseOne(
        'What would you like to do with this commit message?',
        choices: ['commit', 'edit', 'retry', 'discard'],
        defaultValue: 'commit',
      );

      switch (action) {
        case 'commit':
          return currentMessage;

        case 'edit':
          _logger.info('Opening editor...');
          final editedMessage = await GitUtils.openGitEditor(currentMessage);
          if (editedMessage != null && editedMessage.trim().isNotEmpty) {
            currentMessage = editedMessage;
            continue;
          } else {
            _logger.warn(
              'Empty commit message or editor cancelled, returning to options...',
            );
            continue;
          }

        case 'retry':
          final retryOption = _logger.chooseOne(
            'How would you like to retry?',
            choices: ['same model', 'different model', 'add context'],
            defaultValue: 'same model',
          );

          switch (retryOption) {
            case 'same model':
              _logger.info('Regenerating with $modelName...');
              try {
                currentMessage = await generator.generateCommitMessage(
                  diff,
                  language,
                  prefix: prefix,
                  withEmoji: withEmoji,
                );
                currentMessage =
                    GitUtils.stripMarkdownCodeBlocks(currentMessage);
              } catch (e) {
                _logger.err('Failed to regenerate commit message: $e');
                continue;
              }

            case 'different model':
              final newModelName = _logger.chooseOne(
                'Select a different model:',
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
                defaultValue: modelName == 'openai' ? 'claude' : 'openai',
              );

              // Get API key for new model
              final newApiKey = configManager.getApiKey(newModelName) ??
                  _getEnvironmentApiKey(newModelName);

              if ((newApiKey == null || newApiKey.isEmpty) &&
                  newModelName != 'ollama') {
                _logger.err(
                  'No API key found for $newModelName. Please save one using "gw save-key".',
                );
                continue;
              }

              // Create new generator
              final newGenerator = CommitGeneratorFactory.create(
                newModelName,
                newApiKey,
                baseUrl: ollamaBaseUrl ?? 'http://localhost:11434',
              );

              _logger.info('Regenerating with $newModelName...');
              try {
                currentMessage = await newGenerator.generateCommitMessage(
                  diff,
                  language,
                  prefix: prefix,
                  withEmoji: withEmoji,
                );
                currentMessage =
                    GitUtils.stripMarkdownCodeBlocks(currentMessage);
              } catch (e) {
                _logger.err(
                  'Failed to generate commit message with $newModelName: $e',
                );
                continue;
              }

            case 'add context':
              final context = _logger.prompt(
                'Add context or instructions for the AI (e.g., "make it more technical", "focus on performance"):',
              );

              if (context.trim().isEmpty) {
                _logger.warn('No context provided, using same model...');
              }

              _logger.info('Regenerating with additional context...');
              try {
                // For now, we'll just regenerate - in the future, we could modify the prompt
                currentMessage = await generator.generateCommitMessage(
                  diff,
                  language,
                  prefix: prefix,
                  withEmoji: withEmoji,
                );
                currentMessage =
                    GitUtils.stripMarkdownCodeBlocks(currentMessage);
              } catch (e) {
                _logger.err('Failed to regenerate commit message: $e');
                continue;
              }
          }
          continue;

        case 'discard':
          _logger.info('Commit cancelled.');
          return null;
      }
    }
  }

  /// Handles interactive staging workflow for large diffs
  Future<int> _handleInteractiveStaging(
    CommitGenerator generator,
    Language language,
    String? prefix,
    bool withEmoji,
    bool autoPush,
    String? tag,
    bool noConfirm,
  ) async {
    // First, unstage everything to start fresh
    await GitUtils.unstageAll();

    // Show overview of changes
    await _showChangesOverview();
    _logger.info(''); // Add spacing

    var commitCount = 0;

    while (true) {
      // Check if there are any unstaged changes left
      final hasUnstaged = await GitUtils.hasUnstagedChanges();
      if (!hasUnstaged) {
        if (commitCount > 0) {
          _logger.success('🎉 Created $commitCount focused commits!');
        } else {
          _logger.info('No changes to commit.');
        }
        break;
      }

      final choice = _logger.chooseOne(
        '\nCommit ${commitCount + 1}',
        choices: [
          'Stage specific files',
          'Stage hunks interactively',
          'Commit all remaining changes',
          'Finish',
        ],
      );

      switch (choice) {
        case 'Stage specific files':
          final staged = await _stageSpecificFiles(
            generator,
            language,
            prefix,
            withEmoji,
            noConfirm,
          );
          if (staged) {
            commitCount++;
          }
          break;

        case 'Stage hunks interactively':
          final staged = await _stageHunksWithGitAddPatch(
            generator,
            language,
            prefix,
            withEmoji,
            noConfirm,
          );
          if (staged) {
            commitCount++;
          }
          break;

        case 'Commit all remaining changes':
          await GitUtils.stageAllUnstagedFilesAndCount();
          await _generateAndCommitStaged(
            generator,
            language,
            prefix,
            withEmoji,
            noConfirm,
          );
          commitCount++;
          break;

        case 'Finish':
          if (commitCount > 0) {
            _logger.success('Created $commitCount commits.');
          }
          return ExitCode.success.code;
      }
    }

    // Push all commits if auto-push is enabled
    if (autoPush && commitCount > 0) {
      try {
        final branchResult =
            await Process.run('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
        final branch = (branchResult.stdout as String).trim();
        final remoteResult = await Process.run('git', ['remote']);
        final remote = (remoteResult.stdout as String).trim();

        if (remoteResult.exitCode == 0 && remote.isNotEmpty) {
          _logger.info('Pushing $commitCount commits...');
          await Process.run('git', ['push', remote, branch]);
          _logger.success('Pushed to $remote/$branch successfully! 🎉');
        }
      } catch (e) {
        _logger.err('Failed to push commits: $e');
      }
    }

    return ExitCode.success.code;
  }

  /// Helper to generate commit message and commit staged changes
  Future<void> _generateAndCommitStaged(
    CommitGenerator generator,
    Language language,
    String? prefix,
    bool withEmoji,
    bool noConfirm,
  ) async {
    final stagedDiff = await GitUtils.getStagedDiff();
    if (stagedDiff.isEmpty) {
      _logger.info('No staged changes to commit.');
      return;
    }

    _logger.info('Generating commit message for staged changes...');
    try {
      final commitMessage = await generator.generateCommitMessage(
        stagedDiff,
        language,
        prefix: prefix,
        withEmoji: withEmoji,
      );

      // Show the generated commit message
      _logger
        ..info('\n---------------------------------')
        ..info(commitMessage)
        ..info('---------------------------------\n');

      final finalMessage = noConfirm
          ? commitMessage
          : await _handleCommitConfirmation(
              commitMessage: commitMessage,
              generator: generator,
              diff: stagedDiff,
              language: language,
              prefix: prefix,
              modelName: generator.modelName,
              modelVariant: generator.actualVariant,
              ollamaBaseUrl: null,
              configManager: ConfigManager(),
              withEmoji: withEmoji,
            );

      if (finalMessage != null) {
        await GitUtils.runGitCommit(
          message: finalMessage,
        );
        _logger.success('✅ Commit created successfully!');
      } else {
        _logger.info('Commit cancelled. Changes remain staged.');
      }
    } catch (e) {
      _logger.err('Failed to generate commit message: $e');
    }
  }

  /// Shows an overview of changed files and stats
  Future<void> _showChangesOverview() async {
    try {
      // Get list of modified files with stats
      final result = await Process.run('git', ['diff', '--stat']);
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        _logger.info('📋 Changes Overview:');
        _logger.info(result.stdout.toString().trim());
      } else {
        _logger.info('No changes to show.');
      }
    } catch (e) {
      _logger.err('Failed to get changes overview: $e');
    }
  }

  /// Stage specific files by letting user select from changed files
  Future<bool> _stageSpecificFiles(
    CommitGenerator generator,
    Language language,
    String? prefix,
    bool withEmoji,
    bool noConfirm,
  ) async {
    try {
      // Get list of changed files
      final result = await Process.run('git', ['diff', '--name-only']);
      if (result.exitCode != 0 || result.stdout.toString().trim().isEmpty) {
        _logger.info('No changed files to stage.');
        return false;
      }

      final changedFiles = result.stdout.toString().trim().split('\n');

      // Let user select files to stage
      final selectedFiles = _logger.chooseAny(
        'Select files to stage',
        choices: changedFiles,
      );

      if (selectedFiles.isEmpty) {
        _logger.info('No files selected for staging.');
        return false;
      }

      // Stage selected files
      for (final file in selectedFiles) {
        final stageResult = await Process.run('git', ['add', file]);
        if (stageResult.exitCode != 0) {
          _logger.err('Failed to stage $file: ${stageResult.stderr}');
        } else {
          _logger.success('Staged $file');
        }
      }

      // Generate commit message for staged files
      await _generateAndCommitStaged(
        generator,
        language,
        prefix,
        withEmoji,
        noConfirm,
      );

      return true;
    } catch (e) {
      _logger.err('Error staging specific files: $e');
      return false;
    }
  }

  /// Stage hunks using native git add -p
  Future<bool> _stageHunksWithGitAddPatch(
    CommitGenerator generator,
    Language language,
    String? prefix,
    bool withEmoji,
    bool noConfirm,
  ) async {
    try {
      _logger.info('Running git add -p (interactive staging)...');
      _logger.info('💡 Use: y=yes, n=no, s=split, q=quit, ?=help\n');

      final result = await Process.start(
        'git',
        ['add', '-p'],
        mode: ProcessStartMode.inheritStdio,
      );
      final exitCode = await result.exitCode;

      if (exitCode != 0) {
        _logger.info('Interactive staging cancelled.');
        return false;
      }

      // Check if anything was staged
      final hasStaged = await GitUtils.hasStagedChanges();
      if (!hasStaged) {
        _logger.info('No changes staged.');
        return false;
      }

      // Generate commit message for staged changes
      await _generateAndCommitStaged(
        generator,
        language,
        prefix,
        withEmoji,
        noConfirm,
      );

      return true;
    } catch (e) {
      _logger.err('Error during interactive staging: $e');
      return false;
    }
  }

  /// Interactively stage hunks by showing diff content for each
  Future<bool> _stageHunksInteractively(
    CommitGenerator generator,
    Language language,
    String? prefix,
    bool withEmoji,
    bool noConfirm,
  ) async {
    try {
      // Get full diff and split into hunks
      final fullDiff = await GitUtils.getUnstagedDiff();
      if (fullDiff.isEmpty) {
        _logger.info('No unstaged changes to review.');
        return false;
      }

      final hunks = GitUtils.splitDiffIntoHunks(fullDiff);
      if (hunks.isEmpty) {
        _logger.info('No hunks found in diff.');
        return false;
      }

      _logger.info('🔍 Found ${hunks.length} hunks to review:\n');

      var stagedAny = false;

      for (var i = 0; i < hunks.length; i++) {
        final hunk = hunks[i];

        _logger
          ..info('\n--- Hunk ${i + 1}/${hunks.length}: ${hunk.fileName} ---')
          ..info('Changes: ${hunk.description}');

        // Show the hunk diff content
        final hunkDiff = (hunk.header + hunk.lines).join('\n');
        _logger
          ..info('\nDiff:')
          ..info('----------------------------------')
          ..info('${green.wrap(hunkDiff)}')
          ..info('----------------------------------\n');

        final choice = _logger.chooseOne(
          'What would you like to do with this hunk?',
          choices: [
            'Stage this hunk and commit',
            'Skip this hunk',
            "Stage this hunk (don't commit yet)",
            'Stop reviewing hunks',
          ],
        );

        switch (choice) {
          case 'Stage this hunk and commit':
            try {
              await GitUtils.stageHunk(hunk);
              await _generateAndCommitStaged(
                generator,
                language,
                prefix,
                withEmoji,
                noConfirm,
              );
              stagedAny = true;
            } catch (e) {
              _logger.err('Failed to stage/commit hunk: $e');
            }

          case 'Skip this hunk':
            _logger.info('Skipping hunk.');

          case "Stage this hunk (don't commit yet)":
            try {
              await GitUtils.stageHunk(hunk);
              _logger.success('Hunk staged. Will commit later.');
              stagedAny = true;
            } catch (e) {
              _logger.err('Failed to stage hunk: $e');
            }

          case 'Stop reviewing hunks':
            _logger.info('Stopped reviewing hunks.');
            // Check if we have anything staged to commit
            final hasStaged = await GitUtils.hasStagedChanges();
            if (hasStaged) {
              final shouldCommit =
                  _logger.confirm('You have staged changes. Commit them now?');
              if (shouldCommit) {
                await _generateAndCommitStaged(
                  generator,
                  language,
                  prefix,
                  withEmoji,
                  noConfirm,
                );
                stagedAny = true;
              }
            }
            return stagedAny;
        }
      }

      // After reviewing all hunks, check if we have anything staged to commit
      final hasStaged = await GitUtils.hasStagedChanges();
      if (hasStaged) {
        final shouldCommit =
            _logger.confirm('You have staged changes. Commit them now?');
        if (shouldCommit) {
          await _generateAndCommitStaged(
            generator,
            language,
            prefix,
            withEmoji,
            noConfirm,
          );
          stagedAny = true;
        }
      }

      return stagedAny;
    } catch (e) {
      _logger.err('Error during interactive staging: $e');
      return false;
    }
  }
}

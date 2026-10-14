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

import '../agent/agent_commit_generator.dart';
import '../agent/agent_tool_activity_formatter.dart';
import '../agent/git_agent_tools.dart';
import '../commit_utils.dart';
import '../config_manager.dart';
import '../exceptions/exceptions.dart';
import '../git_utils.dart';
import '../models/acp_local_agent_generator.dart';
import '../models/commit_generator.dart';
import '../models/commit_generator_factory.dart';
import '../models/language.dart';

/// Builds the [CommitGenerator] used to produce commit messages.
///
/// Defaults to [CommitGeneratorFactory.create]; tests inject a fake so the
/// command can run without real providers or network access.
typedef CommitGeneratorBuilder = CommitGenerator Function(
  String model,
  String? apiKey, {
  String? variant,
  String? baseUrl,
});

class CommitCommand extends Command<int> {
  /// [configManager] and [workingDirectory] default to the user's config file
  /// and the process working directory; tests inject both so a run never
  /// reads the developer's config or touches the checkout it runs from.
  CommitCommand({
    required Logger logger,
    CommitGeneratorBuilder? generatorBuilder,
    ConfigManager? configManager,
    String? workingDirectory,
  })  : _logger = logger,
        _generatorBuilder = generatorBuilder ?? CommitGeneratorFactory.create,
        _configManager = configManager,
        _workingDirectory = workingDirectory {
    argParser
      ..addOption(
        'model',
        abbr: 'm',
        help: 'AI model or ACP agent id to use',
      )
      ..addOption(
        'key',
        abbr: 'k',
        help: 'API key for the selected model. Prefer `gw save-key`: keys '
            'passed here can end up in your shell history.',
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
        'agent',
        help: 'Use agent mode when the selected model supports tools.',
        negatable: false,
      )
      ..addFlag(
        'confirm',
        abbr: 'c',
        help: 'Confirm commit message before applying',
      )
      ..addFlag(
        'dry-run',
        help: 'Generate and print the commit message without committing.',
        negatable: false,
      )
      ..addOption(
        'tag',
        abbr: 't',
        help: 'Create a git tag for this commit',
        valueHelp: 'v1.0.0',
      );
  }

  /// Exit code for every path where the user cancels, declines or discards
  /// the commit, so `gw commit && git push` never pushes after a cancel.
  ///
  /// `tempFail` (75) marks "nothing went wrong, nothing was done", which keeps
  /// cancels distinct from usage errors (64) and failures (70).
  static const ExitCode cancelledExitCode = ExitCode.tempFail;

  @override
  String get description => 'Generate a commit message based on staged changes';

  @override
  String get name => 'commit';

  final Logger _logger;
  final CommitGeneratorBuilder _generatorBuilder;
  final ConfigManager? _configManager;
  final String? _workingDirectory;
  final AgentToolActivityFormatter _agentToolFormatter =
      const AgentToolActivityFormatter();

  /// Runs the commit process, handling both single and multi-repo scenarios.
  /// Returns an appropriate exit code.
  @override
  Future<int> run() async {
    // Initialize config manager
    final configManager = _configManager ?? ConfigManager();
    await configManager.load();

    // Null means the process working directory.
    final workingDirectory = _workingDirectory;

    List<String>? subGitRepos;

    // Check if we're in a git repository
    if (!await GitUtils.isGitRepository(folderPath: workingDirectory)) {
      _logger.warn('Not a git repository. Checking subfolders...');

      subGitRepos = await GitUtils.findGitReposInSubfolders(
        folderPath: workingDirectory,
      );
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
        return cancelledExitCode.code;
      }
    }

    final bool hasStagedChanges = !hasSubGitRepos
        ? await GitUtils.hasStagedChanges(folderPath: workingDirectory)
        : (await GitUtils.foldersWithStagedChanges(subGitRepos)).isNotEmpty;

    // Check if there are staged changes
    if (!hasStagedChanges) {
      // Check if we should always add unstaged files
      if (configManager.shouldAlwaysAdd()) {
        // Check for unstaged changes or untracked files
        final hasUnstagedChanges = !hasSubGitRepos
            ? await GitUtils.hasUnstagedChanges(folderPath: workingDirectory)
            : (await GitUtils.foldersWithUnstagedChanges(subGitRepos))
                .isNotEmpty;

        final hasUntrackedFiles = !hasSubGitRepos
            ? await GitUtils.hasUntrackedFiles(folderPath: workingDirectory)
            : (await GitUtils.foldersWithUntrackedFiles(subGitRepos))
                .isNotEmpty;

        if (hasUnstagedChanges || hasUntrackedFiles) {
          _logger.info(
            'Unstaged changes or untracked files found. Staging all changes '
            'and new files...',
          );
          if (!hasSubGitRepos) {
            final int stagedFiles =
                await GitUtils.stageAllUnstagedFilesAndCount(
              folderPath: workingDirectory,
            );
            _logger.success('$stagedFiles files have been staged.');
          } else {
            final foldersWithChanges = <String>{
              ...await GitUtils.foldersWithUnstagedChanges(subGitRepos),
              ...await GitUtils.foldersWithUntrackedFiles(subGitRepos),
            };
            for (final f in foldersWithChanges) {
              final int stagedFiles =
                  await GitUtils.stageAllUnstagedFilesAndCount(folderPath: f);
              final folderName = path.basename(f);
              _logger.success(
                '[$folderName] $stagedFiles files have been staged.',
              );
            }
          }
        } else {
          _logger.err('No staged, unstaged, or untracked changes found!');
          return ExitCode.usage.code;
        }
      } else {
        // Check for unstaged or untracked changes
        final hasUnstagedChanges = !hasSubGitRepos
            ? await GitUtils.hasUnstagedChanges(folderPath: workingDirectory)
            : (await GitUtils.foldersWithUnstagedChanges(subGitRepos))
                .isNotEmpty;

        final hasUntrackedFiles = !hasSubGitRepos
            ? await GitUtils.hasUntrackedFiles(folderPath: workingDirectory)
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
                  await GitUtils.stageAllUnstagedFilesAndCount(
                folderPath: workingDirectory,
              );
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
            return cancelledExitCode.code;
          }
        } else {
          _logger.err('No staged, unstaged, or untracked changes found!');
          return ExitCode.usage.code;
        }
      }
    }

    // Get the model name and variant from args, config, or defaults. An empty
    // --model-variant counts as not passed.
    String? modelName = argResults?['model'] as String?;
    String modelVariant =
        (argResults?['model-variant'] as String?)?.trim() ?? '';

    // If modelName is not provided, use config or fallback to openai. The
    // configured default variant only applies when no variant was passed.
    if (modelName == null) {
      final (String, String)? defaults =
          configManager.getDefaultModelAndVariant();
      if (defaults != null) {
        modelName = defaults.$1;
        if (modelVariant.isEmpty) modelVariant = defaults.$2;
      } else {
        modelName = 'openai';
      }
    }

    final agentMode = _supportsAgentMode(modelName);

    // Get API key (from args, config, or environment)
    var apiKey = argResults?['key'] as String?;
    if (apiKey != null && apiKey.isNotEmpty) {
      _logger.warn(
        'Passing an API key with --key can leave it in your shell history. '
        'Save it once with `gw save-key --model $modelName` instead.',
      );
    }
    apiKey ??=
        configManager.getApiKey(modelName) ?? _getEnvironmentApiKey(modelName);

    if ((apiKey == null || apiKey.isEmpty) && _requiresApiKey(modelName)) {
      _logger.err(
        'No API key provided for $modelName. Save one with '
        '`gw save-key --model $modelName` or set the provider API key '
        'environment variable.',
      );
      return ExitCode.usage.code;
    }

    // Get prefix if available for things like ticket numbers
    final prefix = argResults?['prefix'] as String?;

    // Get tag if provided
    final tag = argResults?['tag'] as String?;

    // Handle --auto-push, fallback to false if not provided
    final autoPush = (argResults?['auto-push'] as bool?) ?? false;

    // Handle --dry-run: generate the message but never commit/push/tag.
    final dryRun = (argResults?['dry-run'] as bool?) ?? false;

    // Handle --confirm, fallback to global config, then false
    // Check if --confirm or --no-confirm was explicitly provided
    final confirm = argResults?.wasParsed('confirm') ?? false
        ? (argResults?['confirm'] as bool)
        : configManager.shouldConfirmCommits();

    // Get ollamaBaseUrl from configs
    final String? ollamaBaseUrl = configManager.getOllamaBaseURL();

    // Create the appropriate AI generator based on model name
    final generator = _generatorBuilder(
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
      // Check for large files before proceeding
      final largeFileResult = await _checkForLargeFiles(
        configManager,
        folderPath: workingDirectory,
      );
      if (largeFileResult != null) {
        return largeFileResult;
      }

      var updatedDiff = '';
      if (agentMode) {
        if (!await GitUtils.hasStagedChanges(folderPath: workingDirectory)) {
          _logger.err('No changes detected in staged files.');
          return ExitCode.usage.code;
        }
      } else {
        // Get the diff after large-file handling in case files were unstaged.
        updatedDiff = await GitUtils.getStagedDiff(
          folderPath: workingDirectory,
        );
        if (updatedDiff.isEmpty) {
          _logger.err('No changes detected in staged files.');
          return ExitCode.usage.code;
        }

        // Check if diff is too large - auto process file-by-file.
        if (GitUtils.isDiffTooLarge(
          updatedDiff,
          maxSize: configManager.getMaxDiffSize(),
        )) {
          _logger.info(
            '\nDiff exceeds max size '
            '(${GitUtils.estimateDiffSize(updatedDiff)} chars), processing '
            'file-by-file...\n',
          );

          return _processFileByFileSummaries(
            diff: updatedDiff,
            generator: generator,
            language: language,
            prefix: prefix,
            withEmoji: withEmoji,
            autoPush: autoPush,
            tag: tag,
            confirm: confirm,
            dryRun: dryRun,
            modelName: modelName,
            modelVariant: modelVariant,
            configManager: configManager,
            folderPath: workingDirectory,
          );
        }
      }

      try {
        _logger.info(
          _analysisMessage(
            modelName: modelName,
            modelVariant: modelVariant,
            prefix: prefix,
            agentMode: agentMode,
          ),
        );

        // Generate commit message with AI
        String commitMessage = await _generateCommitMessage(
          generator: generator,
          diff: updatedDiff,
          language: language,
          prefix: prefix,
          withEmoji: withEmoji,
          agentMode: agentMode,
          folderPath: workingDirectory,
        );

        try {
          commitMessage = GitUtils.sanitizeGeneratedCommitMessage(
            commitMessage,
            requireConventionalCommit: agentMode,
          );
        } catch (_) {
          // Silent prayer that it works
        }

        if (commitMessage.trim().isEmpty) {
          _logger.err(
            agentMode
                ? 'Error: Agent did not return a valid commit message.'
                : 'Error: Generated commit message is empty!',
          );
          _logAcpDebugPath();
          return ExitCode.software.code;
        }

        // Handle confirmation workflow if enabled (skipped for dry runs).
        if (confirm && !dryRun) {
          final finalMessage = await _handleCommitConfirmation(
            commitMessage: commitMessage,
            generator: generator,
            diff: updatedDiff,
            language: language,
            prefix: prefix,
            modelName: modelName,
            modelVariant: modelVariant,
            ollamaBaseUrl: ollamaBaseUrl,
            configManager: configManager,
            withEmoji: withEmoji,
            agentMode: agentMode,
            folderPath: workingDirectory,
          );

          if (finalMessage == null) {
            // User cancelled
            return cancelledExitCode.code;
          }

          commitMessage = finalMessage;
        } else {
          // Show message without confirmation
          _logger
            ..info('\n---------------------------------\n')
            ..info(commitMessage)
            ..info('\n---------------------------------\n');
        }

        if (dryRun) {
          _logger.info('Dry run: no commit was created.');
          return ExitCode.success.code;
        }

        try {
          await GitUtils.runGitCommit(
            message: commitMessage,
            autoPush: autoPush,
            folderPath: workingDirectory,
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
          e,
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
      final List<String> cancelledRepos = [];

      for (final f in foldersWithStagedChanges) {
        final folderName = path.basename(f);

        // Check for large files in this repo
        final largeFileResult = await _checkForLargeFiles(
          configManager,
          folderPath: f,
        );
        if (largeFileResult != null) {
          // User cancelled for this repo, but continue with others
          cancelledRepos.add(folderName);
          continue;
        }

        var diff = '';
        if (agentMode) {
          final hasStagedAfterLargeFileHandling =
              await GitUtils.hasStagedChanges(folderPath: f);
          if (!hasStagedAfterLargeFileHandling) {
            _logger.warn(
              '[$folderName] No staged changes remaining after handling large '
              'files, skipping.',
            );
            continue;
          }
        } else {
          // Re-get diff in case files were unstaged
          diff = await GitUtils.getStagedDiff(folderPath: f);
          if (diff.isEmpty) {
            _logger.warn(
              '[$folderName] No staged changes remaining after handling large '
              'files, skipping.',
            );
            continue;
          }
        }

        try {
          _logger.info('[$folderName] ${_analysisMessage(
            modelName: modelName,
            modelVariant: modelVariant,
            prefix: prefix,
            agentMode: agentMode,
          )}');

          // Generate commit message with AI
          String commitMessage = await _generateCommitMessage(
            generator: generator,
            diff: diff,
            language: language,
            prefix: prefix,
            withEmoji: withEmoji,
            agentMode: agentMode,
            folderPath: f,
          );

          try {
            commitMessage = GitUtils.sanitizeGeneratedCommitMessage(
              commitMessage,
              requireConventionalCommit: agentMode,
            );
          } catch (_) {
            // Silent prayer that it works
          }

          if (commitMessage.trim().isEmpty) {
            _logger.err(
              agentMode
                  ? '[$folderName] Error: Agent did not return a valid commit message.'
                  : '[$folderName] Error: Generated commit message is empty',
            );
            _logAcpDebugPath();
            failedRepos.add(folderName);
            continue;
          }

          // Handle confirmation workflow if enabled (skipped for dry runs).
          if (confirm && !dryRun) {
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
              agentMode: agentMode,
              folderPath: f,
            );

            if (finalMessage == null) {
              // User cancelled this repo
              _logger.warn('[$folderName] Commit cancelled by user.');
              cancelledRepos.add(folderName);
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

          if (dryRun) {
            _logger.info('[$folderName] Dry run: no commit was created.');
            successCount++;
            continue;
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

      if (cancelledRepos.isNotEmpty) {
        _logger.warn('Cancelled in: ${cancelledRepos.join(', ')}');
      }

      if (successCount == 1) {
        _logger.success('Processed 1 git repository.');
      } else {
        _logger.success('Processed $successCount git repositories.');
      }

      if (failedRepos.isNotEmpty) return ExitCode.software.code;
      if (cancelledRepos.isNotEmpty) return cancelledExitCode.code;
      return ExitCode.success.code;
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

  bool _requiresApiKey(String modelName) {
    return switch (modelName.toLowerCase()) {
      'claude' ||
      'openai' ||
      'gemini' ||
      'grok' ||
      'llama' ||
      'deepseek' ||
      'github' =>
        true,
      _ => false,
    };
  }

  bool _supportsAgentMode(String modelName) {
    return switch (modelName.toLowerCase()) {
      'openai' ||
      'codex' ||
      'claude-code' ||
      'claude' ||
      'gemini' ||
      'grok' ||
      'llama' ||
      'deepseek' ||
      'github' ||
      'ollama' =>
        true,
      _ => true,
    };
  }

  String _analysisMessage({
    required String modelName,
    required String modelVariant,
    required bool agentMode,
    String? prefix,
  }) {
    final displayName = _modelDisplayName(modelName);
    final variantText = modelVariant.isNotEmpty ? ' ($modelVariant)' : '';
    final agentText = agentMode ? ' (Agent Mode)' : '';
    final prefixText = prefix != null ? ' for ticket $prefix' : '';
    return 'Analyzing staged changes with $displayName$variantText'
        '$agentText$prefixText...';
  }

  String _modelDisplayName(String modelName) {
    return switch (modelName.toLowerCase()) {
      'claude' => 'Claude',
      'openai' => 'OpenAI',
      'claude-code' => 'Claude Code',
      'codex' => 'Codex',
      'gemini' => 'Gemini',
      'grok' => 'Grok',
      'llama' => 'Llama',
      'deepseek' => 'DeepSeek',
      'github' => 'GitHub Models',
      'ollama' => 'Ollama',
      _ => modelName,
    };
  }

  Future<String> _generateCommitMessage({
    required CommitGenerator generator,
    required String diff,
    required Language language,
    required bool withEmoji,
    required bool agentMode,
    String? prefix,
    String? folderPath,
  }) {
    if (!agentMode) {
      return generator.generateCommitMessage(
        diff,
        language,
        prefix: prefix,
        withEmoji: withEmoji,
      );
    }

    if (generator is! AgentCommitGenerator) {
      throw UnsupportedError(
        'Agent mode currently supports only openai and claude.',
      );
    }

    final agentGenerator = generator as AgentCommitGenerator;
    return agentGenerator.generateAgentCommitMessage(
      AgentCommitRequest(
        tools: GitAgentTools(
          folderPath: folderPath,
          onToolUse: _logAgentToolUse,
        ),
        language: language,
        prefix: prefix,
        withEmoji: withEmoji,
      ),
    );
  }

  void _logAgentToolUse(AgentToolUse toolUse) {
    _logger.info(_agentToolFormatter.format(toolUse));
  }

  void _logAcpDebugPath() {
    final logPath = AcpDebugLog.lastLogPath;
    if (logPath == null || logPath.isEmpty) return;
    _logger.info('ACP debug log: $logPath');
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
    bool agentMode = false,
    String? folderPath,
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
                currentMessage = await _generateCommitMessage(
                  generator: generator,
                  diff: diff,
                  language: language,
                  prefix: prefix,
                  withEmoji: withEmoji,
                  agentMode: agentMode,
                  folderPath: folderPath,
                );
                currentMessage = GitUtils.sanitizeGeneratedCommitMessage(
                  currentMessage,
                  requireConventionalCommit: agentMode,
                );
              } catch (e) {
                _logger.err('Failed to regenerate commit message: $e');
                continue;
              }

            case 'different model':
              final newModelName = _logger.chooseOne(
                'Select a different model:',
                choices: agentMode
                    ? [
                        'claude',
                        'openai',
                      ]
                    : [
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
                      ],
                defaultValue: modelName == 'openai' ? 'claude' : 'openai',
              );

              // Get API key for new model
              final newApiKey = configManager.getApiKey(newModelName) ??
                  _getEnvironmentApiKey(newModelName);

              if ((newApiKey == null || newApiKey.isEmpty) &&
                  _requiresApiKey(newModelName)) {
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
                currentMessage = await _generateCommitMessage(
                  generator: newGenerator,
                  diff: diff,
                  language: language,
                  prefix: prefix,
                  withEmoji: withEmoji,
                  agentMode: agentMode,
                  folderPath: folderPath,
                );
                currentMessage = GitUtils.sanitizeGeneratedCommitMessage(
                  currentMessage,
                  requireConventionalCommit: agentMode,
                );
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
                currentMessage = await _generateCommitMessage(
                  generator: generator,
                  diff: diff,
                  language: language,
                  prefix: prefix,
                  withEmoji: withEmoji,
                  agentMode: agentMode,
                  folderPath: folderPath,
                );
                currentMessage = GitUtils.sanitizeGeneratedCommitMessage(
                  currentMessage,
                  requireConventionalCommit: agentMode,
                );
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

  /// Checks for large files in staged changes and handles user prompts
  /// Returns an exit code if commit should be cancelled, null to continue
  Future<int?> _checkForLargeFiles(
    ConfigManager configManager, {
    String? folderPath,
  }) async {
    final maxFileSize = configManager.getMaxFileSize();
    final largeFiles = await GitUtils.getLargeFiles(
      maxFileSize,
      folderPath: folderPath,
    );

    if (largeFiles.isEmpty) return null; // Continue normally

    for (final (filePath, sizeBytes) in largeFiles) {
      final sizeInMB = (sizeBytes / 1024 / 1024).toStringAsFixed(1);
      final isInRemote = await GitUtils.isFileInRemoteHistory(
        filePath,
        folderPath: folderPath,
      );

      if (isInRemote) {
        // Just warn, file already exists in history
        _logger.warn(
          '⚠️  Large file: $filePath ($sizeInMB MB) - already in git history',
        );
      } else {
        // Block and ask
        _logger.warn('\n⚠️  Large file detected: $filePath ($sizeInMB MB)');
        final choice = _logger.chooseOne(
          'This file has never been pushed to remote. What would you like to do?',
          choices: [
            'Proceed anyway',
            'Add to .gitignore and unstage',
            'Cancel commit',
          ],
        );

        switch (choice) {
          case 'Add to .gitignore and unstage':
            await GitUtils.addToGitignore(filePath, folderPath: folderPath);
            await GitUtils.unstageFile(filePath, folderPath: folderPath);
            _logger.success('Added $filePath to .gitignore and unstaged it');
            break;
          case 'Cancel commit':
            _logger.info('Commit cancelled.');
            return cancelledExitCode.code;
          // 'Proceed anyway' continues
        }
      }
    }

    // Check if we still have staged changes after potentially unstaging files
    final hasStaged = await GitUtils.hasStagedChanges(folderPath: folderPath);
    if (!hasStaged) {
      _logger.info('No staged changes remaining after handling large files.');
      return cancelledExitCode.code;
    }

    return null; // Continue with commit
  }

  /// Processes large diffs by generating summaries for each file
  /// and then combining them into a final commit message
  Future<int> _processFileByFileSummaries({
    required String diff,
    required CommitGenerator generator,
    required Language language,
    String? prefix,
    required bool withEmoji,
    required bool autoPush,
    String? tag,
    required bool confirm,
    bool dryRun = false,
    required String modelName,
    required String modelVariant,
    required ConfigManager configManager,
    String? folderPath,
  }) async {
    final hunks = GitUtils.splitDiffIntoHunks(diff);
    final fileGroups = GitUtils.groupHunksByFile(hunks);
    final fileSummaries = <String, String>{};

    var index = 0;
    final total = fileGroups.length;

    for (final entry in fileGroups.entries) {
      index++;
      final fileName = entry.key;
      final fileHunks = entry.value;

      _logger.info('Processing $fileName ($index/$total)...');

      final fileDiff = GitUtils.reconstructFileDiff(fileHunks);
      final summaryPrompt = getFileSummaryPrompt(fileName, fileDiff, language);

      try {
        // Use generator to get summary
        final summary = await generator.generateCommitMessage(
          summaryPrompt,
          language,
          prefix: null,
          withEmoji: false,
        );

        fileSummaries[fileName] = summary.trim();
      } catch (e) {
        _logger.warn('Failed to summarize $fileName: $e');
        // Use a simple fallback summary
        final addedLines = fileHunks
            .expand((h) => h.lines)
            .where((l) => l.startsWith('+'))
            .length;
        final removedLines = fileHunks
            .expand((h) => h.lines)
            .where((l) => l.startsWith('-'))
            .length;
        fileSummaries[fileName] =
            'Modified ($addedLines added, $removedLines removed)';
      }
    }

    _logger.info('\nGenerating commit message from summaries...');

    // Generate final commit message from summaries
    final finalPrompt = getCommitFromSummariesPrompt(
      fileSummaries,
      language,
      prefix: prefix,
      withEmoji: withEmoji,
    );

    try {
      String commitMessage = await generator.generateCommitMessage(
        finalPrompt,
        language,
        prefix: prefix,
        withEmoji: withEmoji,
      );

      commitMessage = GitUtils.sanitizeGeneratedCommitMessage(commitMessage);

      if (commitMessage.trim().isEmpty) {
        _logger.err('Error: Generated commit message is empty!');
        _logAcpDebugPath();
        return ExitCode.software.code;
      }

      // Handle confirmation workflow if enabled
      if (confirm && !dryRun) {
        final finalMessage = await _handleCommitConfirmation(
          commitMessage: commitMessage,
          generator: generator,
          diff: diff,
          language: language,
          prefix: prefix,
          modelName: modelName,
          modelVariant: modelVariant,
          ollamaBaseUrl: null,
          configManager: configManager,
          withEmoji: withEmoji,
          folderPath: folderPath,
        );

        if (finalMessage == null) {
          return cancelledExitCode.code;
        }

        commitMessage = finalMessage;
      } else {
        // Show message without confirmation
        _logger
          ..info('\n---------------------------------\n')
          ..info(commitMessage)
          ..info('\n---------------------------------\n');
      }

      if (dryRun) {
        _logger.info('Dry run: no commit was created.');
        return ExitCode.success.code;
      }

      try {
        await GitUtils.runGitCommit(
          message: commitMessage,
          autoPush: autoPush,
          folderPath: folderPath,
          tag: tag,
        );
      } catch (e) {
        _logger.err('Error setting commit message: $e');
        return ExitCode.software.code;
      }

      return ExitCode.success.code;
    } catch (e) {
      _logger.err('Failed to generate commit message: $e');
      return ExitCode.software.code;
    }
  }
}

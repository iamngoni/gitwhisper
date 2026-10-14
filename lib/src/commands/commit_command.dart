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

/// Opens [message] for editing in the repository at [folderPath] and returns
/// the result, or null when it was left empty or the editor failed.
typedef CommitMessageEditor = Future<String?> Function(
  String message, {
  String? folderPath,
});

class CommitCommand extends Command<int> {
  /// [configManager] and [workingDirectory] default to the user's config file
  /// and the process working directory; tests inject both so a run never
  /// reads the developer's config or touches the checkout it runs from.
  /// [messageEditor] defaults to the user's git editor.
  CommitCommand({
    required Logger logger,
    CommitGeneratorBuilder? generatorBuilder,
    ConfigManager? configManager,
    String? workingDirectory,
    CommitMessageEditor? messageEditor,
  })  : _logger = logger,
        _generatorBuilder = generatorBuilder ?? CommitGeneratorFactory.create,
        _configManager = configManager,
        _workingDirectory = workingDirectory,
        _messageEditor = messageEditor ?? GitUtils.openGitEditor {
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
  final CommitMessageEditor _messageEditor;
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

    // The top of the work tree in single-repo mode. Every step runs there, so
    // staging, file paths and .gitignore cover the whole repository even when
    // gw is started from a subdirectory.
    String? repoRoot;

    // Check if we're in a git repository
    if (await GitUtils.isGitRepository(folderPath: workingDirectory)) {
      repoRoot =
          await GitUtils.getRepositoryRoot(folderPath: workingDirectory) ??
              workingDirectory;
    } else {
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

    // Stop before staging or calling the model while a merge is unresolved:
    // staging would mark conflicted files resolved, markers and all.
    final List<String> conflictedRepos = [];
    if (!hasSubGitRepos) {
      if (await _reportUnmergedFiles(repoRoot)) {
        return ExitCode.usage.code;
      }
    } else {
      for (final repo in [...subGitRepos]) {
        final folderName = path.basename(repo);
        if (await _reportUnmergedFiles(repo, label: '[$folderName] ')) {
          conflictedRepos.add(folderName);
          subGitRepos.remove(repo);
        }
      }
      if (subGitRepos.isEmpty) return ExitCode.usage.code;
    }

    final bool hasStagedChanges = !hasSubGitRepos
        ? await GitUtils.hasStagedChanges(folderPath: repoRoot)
        : (await GitUtils.foldersWithStagedChanges(subGitRepos)).isNotEmpty;

    // Check if there are staged changes
    if (!hasStagedChanges) {
      // Check if we should always add unstaged files
      if (configManager.shouldAlwaysAdd()) {
        // Check for unstaged changes or untracked files
        final hasUnstagedChanges = !hasSubGitRepos
            ? await GitUtils.hasUnstagedChanges(folderPath: repoRoot)
            : (await GitUtils.foldersWithUnstagedChanges(subGitRepos))
                .isNotEmpty;

        final hasUntrackedFiles = !hasSubGitRepos
            ? await GitUtils.hasUntrackedFiles(folderPath: repoRoot)
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
              folderPath: repoRoot,
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
            ? await GitUtils.hasUnstagedChanges(folderPath: repoRoot)
            : (await GitUtils.foldersWithUnstagedChanges(subGitRepos))
                .isNotEmpty;

        final hasUntrackedFiles = !hasSubGitRepos
            ? await GitUtils.hasUntrackedFiles(folderPath: repoRoot)
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
                folderPath: repoRoot,
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

    // Handle --confirm, fallback to global config, then false
    // Check if --confirm or --no-confirm was explicitly provided
    final confirm = argResults?.wasParsed('confirm') ?? false
        ? (argResults?['confirm'] as bool)
        : configManager.shouldConfirmCommits();

    final options = _CommitOptions(
      language: configManager.getWhisperLanguage(),
      withEmoji: configManager.shouldAllowEmojis(),
      maxDiffSize: configManager.getMaxDiffSize(),
      // Prefix for things like ticket numbers
      prefix: argResults?['prefix'] as String?,
      tag: argResults?['tag'] as String?,
      autoPush: (argResults?['auto-push'] as bool?) ?? false,
      confirm: confirm,
      // --dry-run generates the message but never commits, pushes or tags.
      dryRun: (argResults?['dry-run'] as bool?) ?? false,
      ollamaBaseUrl: configManager.getOllamaBaseURL(),
    );

    // Create the appropriate AI generator based on model name
    final model = _ModelChoice(
      generator: _generatorBuilder(
        modelName,
        apiKey,
        variant: modelVariant,
        baseUrl: options.baseUrl,
      ),
      name: modelName,
      variant: modelVariant,
      agentMode: _supportsAgentMode(modelName),
    );

    // --- Single repo flow ---
    if (!hasSubGitRepos) {
      final outcome = await _commitRepository(
        folderPath: repoRoot,
        model: model,
        options: options,
        configManager: configManager,
      );
      return switch (outcome) {
        _RepoOutcome.succeeded => ExitCode.success.code,
        _RepoOutcome.cancelled => cancelledExitCode.code,
        _RepoOutcome.skipped => ExitCode.usage.code,
        _RepoOutcome.failed => ExitCode.software.code,
      };
    }

    // --- Multi-repo flow ---
    final foldersWithStagedChanges =
        await GitUtils.foldersWithStagedChanges(subGitRepos);
    _logger.info('Working in ${foldersWithStagedChanges.length} git repos');

    int successCount = 0;
    final List<String> failedRepos = [...conflictedRepos];
    final List<String> cancelledRepos = [];

    for (final f in foldersWithStagedChanges) {
      final folderName = path.basename(f);
      final outcome = await _commitRepository(
        folderPath: f,
        repoName: folderName,
        model: model,
        options: options,
        configManager: configManager,
      );
      switch (outcome) {
        case _RepoOutcome.succeeded:
          successCount++;
        case _RepoOutcome.cancelled:
          cancelledRepos.add(folderName);
        case _RepoOutcome.failed:
          failedRepos.add(folderName);
        case _RepoOutcome.skipped:
          break;
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

  /// Generates a message for the staged changes in [folderPath], lets the
  /// user review it when confirmation is on, and commits it.
  ///
  /// [repoName] is set in multi-repo runs, where log lines are labelled with
  /// it and errors are summarised so the remaining repositories can continue.
  Future<_RepoOutcome> _commitRepository({
    required String? folderPath,
    required _ModelChoice model,
    required _CommitOptions options,
    required ConfigManager configManager,
    String? repoName,
  }) async {
    final multiRepo = repoName != null;
    final label = multiRepo ? '[$repoName] ' : '';

    // Check for large files before proceeding. A failure here (e.g. an
    // unwritable .gitignore) is reported so other repositories can continue.
    try {
      if (!await _checkForLargeFiles(configManager, folderPath: folderPath)) {
        return _RepoOutcome.cancelled;
      }
    } on Object catch (e) {
      _logger.err('${label}Could not handle large files: $e');
      return _RepoOutcome.failed;
    }

    if (!await GitUtils.hasStagedChanges(folderPath: folderPath)) {
      if (multiRepo) {
        _logger.warn(
          '${label}No staged changes remaining after handling large files, '
          'skipping.',
        );
      } else {
        _logger.err('No changes detected in staged files.');
      }
      return _RepoOutcome.skipped;
    }

    try {
      _logger.info(
        '$label${_analysisMessage(
          modelName: model.name,
          modelVariant: model.variant,
          prefix: options.prefix,
          agentMode: model.agentMode,
        )}',
      );

      // Generate commit message with AI
      String commitMessage = await _generateMessage(
        model: model,
        options: options,
        folderPath: folderPath,
        label: label,
      );

      if (commitMessage.trim().isEmpty) {
        _logger.err(
          model.agentMode
              ? '${label}Error: Agent did not return a valid commit message.'
              : '${label}Error: Generated commit message is empty!',
        );
        _logAcpDebugPath();
        return _RepoOutcome.failed;
      }

      // Handle confirmation workflow if enabled (skipped for dry runs).
      if (options.confirm && !options.dryRun) {
        if (multiRepo) _logger.info('${label}Review commit message:');
        final finalMessage = await _confirmCommitMessage(
          commitMessage: commitMessage,
          model: model,
          options: options,
          configManager: configManager,
          folderPath: folderPath,
          label: label,
        );

        if (finalMessage == null) {
          // User cancelled
          if (multiRepo) _logger.warn('${label}Commit cancelled by user.');
          return _RepoOutcome.cancelled;
        }

        commitMessage = finalMessage;
      } else if (multiRepo) {
        // Show message without confirmation
        _logger
          ..info('\n----------- $repoName -----------\n')
          ..info(commitMessage)
          ..info('\n-----------------------------------\n');
      } else {
        _logger
          ..info('\n---------------------------------\n')
          ..info(commitMessage)
          ..info('\n---------------------------------\n');
      }

      if (options.dryRun) {
        _logger.info('${label}Dry run: no commit was created.');
        return _RepoOutcome.succeeded;
      }

      return await _commitAndPublish(
        commitMessage,
        folderPath: folderPath,
        options: options,
        label: label,
      );
    } on ApiException catch (e) {
      if (multiRepo) {
        _logger.err('$label${ErrorHandler.getErrorSummary(e)}');
      } else {
        ErrorHandler.handleErrorWithRetry(
          e,
          context: 'generating commit message',
        );
        _logModelSwitchSuggestions(e);
      }
      return _RepoOutcome.failed;
    } on Object catch (e) {
      if (multiRepo) {
        _logger.err('${label}Error generating commit message: $e');
      } else {
        ErrorHandler.handleGeneralError(
          e,
          context: 'generating commit message',
        );
      }
      return _RepoOutcome.failed;
    }
  }

  /// Commits [message], then creates the tag and pushes when requested.
  ///
  /// Tag and push failures are reported as such: the commit already exists by
  /// then, and saying the commit failed would be wrong. They still count as a
  /// failure, so scripts do not assume the commit was pushed.
  Future<_RepoOutcome> _commitAndPublish(
    String message, {
    required String? folderPath,
    required _CommitOptions options,
    required String label,
  }) async {
    try {
      await GitUtils.runGitCommit(message: message, folderPath: folderPath);
    } on Object catch (e) {
      _logger.err('${label}Error creating the commit: $e');
      return _RepoOutcome.failed;
    }
    _logger.success('${label}Commit successful! 🎉');

    final tag = options.tag;
    final hasTag = tag != null && tag.isNotEmpty;
    if (hasTag) {
      try {
        await GitUtils.createTag(tag, folderPath: folderPath);
      } on Object catch (e) {
        _logger.err(
          '${label}The commit was created, but tagging it failed: $e'
          '${options.autoPush ? ' Nothing was pushed.' : ''}',
        );
        return _RepoOutcome.failed;
      }
      _logger.success('${label}Tag $tag created successfully!');
    }

    if (!options.autoPush) return _RepoOutcome.succeeded;

    _logger.info('${label}Syncing with remote branch...');
    final ({String remote, String target}) pushed;
    try {
      pushed = await GitUtils.pushCurrentBranch(folderPath: folderPath);
    } on Object catch (e) {
      _logger.err('${label}The commit was created, but pushing failed: $e');
      return _RepoOutcome.failed;
    }
    _logger.success('${label}Pushed to ${pushed.target} successfully! 🎉');

    if (hasTag) {
      try {
        await GitUtils.pushTag(
          tag,
          remote: pushed.remote,
          folderPath: folderPath,
        );
      } on Object catch (e) {
        _logger.err(
          '${label}The commit was pushed, but pushing tag $tag failed: $e',
        );
        return _RepoOutcome.failed;
      }
      _logger.success('${label}Tag $tag pushed successfully!');
    }

    return _RepoOutcome.succeeded;
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

  /// Generates a commit message for the staged changes in [folderPath] and
  /// sanitizes it. Returns an empty string when the model produced no usable
  /// message.
  Future<String> _generateMessage({
    required _ModelChoice model,
    required _CommitOptions options,
    required String? folderPath,
    required String label,
  }) async {
    final rawMessage = model.agentMode
        ? await _generateAgentMessage(
            generator: model.generator,
            options: options,
            folderPath: folderPath,
          )
        : await _generateDirectMessage(
            generator: model.generator,
            options: options,
            folderPath: folderPath,
            label: label,
          );

    return GitUtils.sanitizeGeneratedCommitMessage(
      rawMessage,
      requireConventionalCommit: model.agentMode,
      prefix: options.prefix,
    );
  }

  /// Lets the model inspect the staged changes through read-only git tools.
  Future<String> _generateAgentMessage({
    required CommitGenerator generator,
    required _CommitOptions options,
    required String? folderPath,
  }) {
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
        language: options.language,
        prefix: options.prefix,
        withEmoji: options.withEmoji,
      ),
    );
  }

  /// Sends the staged diff in the prompt. Diffs larger than the configured
  /// max diff size are summarised file by file first.
  Future<String> _generateDirectMessage({
    required CommitGenerator generator,
    required _CommitOptions options,
    required String? folderPath,
    required String label,
  }) async {
    final diff = await GitUtils.getStagedDiff(folderPath: folderPath);
    if (diff.isEmpty) return '';

    // Check if diff is too large - auto process file-by-file.
    if (GitUtils.isDiffTooLarge(diff, maxSize: options.maxDiffSize)) {
      _logger.info(
        '\n${label}Diff exceeds max size '
        '(${GitUtils.estimateDiffSize(diff)} chars), processing '
        'file-by-file...\n',
      );
      return _generateFromFileSummaries(
        generator: generator,
        diff: diff,
        options: options,
      );
    }

    return generator.generateCommitMessage(
      diff,
      options.language,
      prefix: options.prefix,
      withEmoji: options.withEmoji,
    );
  }

  /// Logs an error and returns true when the repository at [folderPath] has
  /// unresolved merge conflicts.
  Future<bool> _reportUnmergedFiles(
    String? folderPath, {
    String label = '',
  }) async {
    final unmerged = await GitUtils.getUnmergedFiles(folderPath: folderPath);
    if (unmerged.isEmpty) return false;
    _logger
      ..err('${label}Unresolved merge conflicts in: ${unmerged.join(', ')}')
      ..err(
        '${label}Resolve the conflicts and stage the results with `git add`, '
        'then run gw commit again.',
      );
    return true;
  }

  /// Lists alternatives for errors where switching models may help.
  ///
  /// [ErrorHandler.handleErrorWithFallback] would print the error itself a
  /// second time after [ErrorHandler.handleErrorWithRetry], so only the
  /// suggestions are logged here.
  void _logModelSwitchSuggestions(ApiException error) {
    if (!ErrorHandler.shouldSuggestModelSwitch(error)) return;
    final suggestions = ErrorHandler.getModelSwitchSuggestions(error);
    if (suggestions.isEmpty) return;
    _logger
      ..info('')
      ..info('You can try these alternatives:');
    for (final suggestion in suggestions) {
      _logger.info('• $suggestion');
    }
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
  Future<String?> _confirmCommitMessage({
    required String commitMessage,
    required _ModelChoice model,
    required _CommitOptions options,
    required ConfigManager configManager,
    required String? folderPath,
    required String label,
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
          final String? editedMessage;
          try {
            editedMessage = await _messageEditor(
              currentMessage,
              folderPath: folderPath,
            );
          } on Exception catch (e) {
            // Keep the current message so the user can still commit it.
            _logger.err('Could not open the editor: $e');
            continue;
          }
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
              _logger.info('Regenerating with ${model.name}...');
              try {
                currentMessage = await _generateMessage(
                  model: model,
                  options: options,
                  folderPath: folderPath,
                  label: label,
                );
              } on Object catch (e) {
                _logger.err('Failed to regenerate commit message: $e');
                continue;
              }

            case 'different model':
              final newModelName = _logger.chooseOne(
                'Select a different model:',
                choices: model.agentMode
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
                defaultValue: model.name == 'openai' ? 'claude' : 'openai',
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
              final newModel = _ModelChoice(
                generator: CommitGeneratorFactory.create(
                  newModelName,
                  newApiKey,
                  baseUrl: options.baseUrl,
                ),
                name: newModelName,
                variant: '',
                agentMode: model.agentMode,
              );

              _logger.info('Regenerating with $newModelName...');
              try {
                currentMessage = await _generateMessage(
                  model: newModel,
                  options: options,
                  folderPath: folderPath,
                  label: label,
                );
              } on Object catch (e) {
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
                currentMessage = await _generateMessage(
                  model: model,
                  options: options,
                  folderPath: folderPath,
                  label: label,
                );
              } on Object catch (e) {
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

  /// Checks for large files in staged changes and handles user prompts.
  ///
  /// Returns false when the user cancelled or nothing is left staged after
  /// unstaging large files, true to continue with the commit.
  Future<bool> _checkForLargeFiles(
    ConfigManager configManager, {
    String? folderPath,
  }) async {
    final maxFileSize = configManager.getMaxFileSize();
    final largeFiles = await GitUtils.getLargeFiles(
      maxFileSize,
      folderPath: folderPath,
    );

    if (largeFiles.isEmpty) return true; // Continue normally

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
          case 'Cancel commit':
            _logger.info('Commit cancelled.');
            return false;
          // 'Proceed anyway' continues
        }
      }
    }

    // Check if we still have staged changes after potentially unstaging files
    final hasStaged = await GitUtils.hasStagedChanges(folderPath: folderPath);
    if (!hasStaged) {
      _logger.info('No staged changes remaining after handling large files.');
      return false;
    }

    return true; // Continue with commit
  }

  /// Summarises a large [diff] file by file, then asks the model for a commit
  /// message based on those summaries. Returns the unsanitized message.
  Future<String> _generateFromFileSummaries({
    required CommitGenerator generator,
    required String diff,
    required _CommitOptions options,
  }) async {
    final language = options.language;
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
          withEmoji: false,
        );

        fileSummaries[fileName] = summary.trim();
      } on Object catch (e) {
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
      prefix: options.prefix,
      withEmoji: options.withEmoji,
    );

    return generator.generateCommitMessage(
      finalPrompt,
      language,
      prefix: options.prefix,
      withEmoji: options.withEmoji,
    );
  }
}

/// What happened to one repository during a commit run.
enum _RepoOutcome {
  /// Committed, or the message was generated for a dry run.
  succeeded,

  /// The user cancelled, declined or discarded the commit.
  cancelled,

  /// There was nothing to commit.
  skipped,

  /// Generating the message or creating the commit failed.
  failed,
}

/// Settings shared by every repository in one commit run.
class _CommitOptions {
  const _CommitOptions({
    required this.language,
    required this.withEmoji,
    required this.maxDiffSize,
    required this.autoPush,
    required this.confirm,
    required this.dryRun,
    this.prefix,
    this.tag,
    this.ollamaBaseUrl,
  });

  final Language language;
  final bool withEmoji;

  /// Direct-diff mode summarises diffs larger than this file by file.
  final int maxDiffSize;
  final bool autoPush;
  final bool confirm;
  final bool dryRun;
  final String? prefix;
  final String? tag;
  final String? ollamaBaseUrl;

  /// Base URL passed to generator builders (only Ollama uses it).
  String get baseUrl => ollamaBaseUrl ?? 'http://localhost:11434';
}

/// The generator that writes commit messages, and how it is driven.
class _ModelChoice {
  const _ModelChoice({
    required this.generator,
    required this.name,
    required this.variant,
    required this.agentMode,
  });

  final CommitGenerator generator;
  final String name;
  final String variant;
  final bool agentMode;
}

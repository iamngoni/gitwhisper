//
//  gitwhisper
//  command_runner.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pub_updater/pub_updater.dart';

import 'commands/commit_command.dart';
import 'commands/list_models_command.dart';
import 'commands/save_key_command.dart';
import 'commands/update_command.dart';
import 'version.dart';

class GitWhisperCommandRunner extends CompletionCommandRunner<int> {
  GitWhisperCommandRunner({
    Logger? logger,
    PubUpdater? pubUpdater,
  })  : _logger = logger ?? Logger(),
        _pubUpdater = pubUpdater ?? PubUpdater(),
        super('gitwhisper', 'AI-powered Git commit message generator') {
    argParser
      ..addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: 'Print the current version.',
      )
      ..addFlag(
        'verbose',
        help: 'Enable verbose logging.',
        negatable: false,
      );

    // Add commands
    addCommand(CommitCommand(logger: _logger));
    addCommand(ListModelsCommand(logger: _logger));
    addCommand(SaveKeyCommand(logger: _logger));
    addCommand(UpdateCommand(logger: _logger, pubUpdater: _pubUpdater));
  }

  @override
  void printUsage() {
    _logger.info('');
    _logger.info(
        'GitWhisper - Your AI companion for crafting perfect commit messages');
    _logger.info('');
    _logger.info(usage);
  }

  final Logger _logger;
  final PubUpdater _pubUpdater;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevelResults = parse(args);
      if (topLevelResults['verbose'] == true) {
        _logger.level = Level.verbose;
      }
      return await runCommand(topLevelResults) ?? ExitCode.success.code;
    } on FormatException catch (e, stackTrace) {
      // Print usage information if an invalid argument was provided
      _logger.err(e.message);
      _logger.detail(stackTrace.toString());
      printUsage();
      return ExitCode.usage.code;
    } on UsageException catch (e) {
      // Print usage information if the user provided a command that doesn't exist
      _logger.err(e.message);
      _logger.info('');
      _logger.info(e.usage);
      return ExitCode.usage.code;
    }
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // Handle version flag
    if (topLevelResults['version'] == true) {
      _logger.info('gitwhisper version: $packageVersion');
      return ExitCode.success.code;
    }

    // Handle no command
    final commandResult = await super.runCommand(topLevelResults);
    return commandResult;
  }
}

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

import 'commands/clear_defaults_command.dart';
import 'commands/commit_command.dart';
import 'commands/list_models_command.dart';
import 'commands/list_variants_command.dart';
import 'commands/save_key_command.dart';
import 'commands/set_defaults_command.dart';
import 'commands/update_command.dart';
import 'constants.dart';
import 'version.dart';

class GitWhisperCommandRunner extends CompletionCommandRunner<int> {
  GitWhisperCommandRunner({
    PubUpdater? pubUpdater,
  })  : _pubUpdater = pubUpdater ?? PubUpdater(),
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
    addCommand(CommitCommand(logger: $logger));
    addCommand(ListModelsCommand(logger: $logger));
    addCommand(ListVariantsCommand(logger: $logger));
    addCommand(SaveKeyCommand(logger: $logger));
    addCommand(SetDefaultsCommand(logger: $logger));
    addCommand(ClearDefaultsCommand(logger: $logger));
    addCommand(UpdateCommand(logger: $logger, pubUpdater: _pubUpdater));
  }

  @override
  void printUsage() {
    $logger
      ..info('')
      ..info(
        'GitWhisper - Your AI companion for crafting perfect commit messages',
      )
      ..info('')
      ..info(usage);
  }

  final PubUpdater _pubUpdater;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevelResults = parse(args);
      return await runCommand(topLevelResults) ?? ExitCode.success.code;
    } on FormatException catch (e, stackTrace) {
      // Print usage information if an invalid argument was provided
      $logger
        ..err(e.message)
        ..detail(stackTrace.toString());
      printUsage();
      return ExitCode.usage.code;
    } on UsageException catch (e) {
      // Print usage information if the user provided a command that doesn't exist
      $logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return ExitCode.usage.code;
    }
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // Handle version flag
    if (topLevelResults['version'] == true) {
      $logger.info('gitwhisper version: $packageVersion');
      return ExitCode.success.code;
    }

    // Handle no command
    final commandResult = await super.runCommand(topLevelResults);
    return commandResult;
  }
}

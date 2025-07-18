//
//  gitwhisper
//  change_language_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/07/18.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';
import '../models/language.dart';

class ChangeLanguageCommand extends Command<int> {
  ChangeLanguageCommand({
    required Logger logger,
  }) : _logger = logger;

  final Logger _logger;

  @override
  String get description => 'Change language to use for commit messages';

  @override
  String get name => 'change-language';

  @override
  Future<int> run() async {
    // Initialize config manager
    final configManager = ConfigManager();
    await configManager.load();

    const languages = Language.values;

    final Language language = _logger.chooseOne<Language>(
      'Select the language you need as the default for commit messages',
      choices: languages,
      defaultValue: Language.english,
      display: (language) {
        return language.name;
      },
    );

    configManager.setWhisperLanguage(language);
    await configManager.save();

    _logger.success(
      '$language successfully set as the default language for GIT activities',
    );
    return ExitCode.success.code;
  }
}

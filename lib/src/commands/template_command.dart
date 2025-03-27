//
//  gitwhisper
//  template_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/27.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../template_manager.dart';

class TemplateCommand extends Command<int> {
  TemplateCommand({
    required Logger logger,
  }) {
    addSubcommand(ListTemplatesCommand(logger: logger));
    addSubcommand(AddTemplateCommand(logger: logger));
    addSubcommand(DeleteTemplateCommand(logger: logger));
    addSubcommand(ShowTemplateCommand(logger: logger));
  }

  @override
  String get description => 'Manage commit message templates';

  @override
  String get name => 'template';
}

class ListTemplatesCommand extends Command<int> {
  ListTemplatesCommand({
    required Logger logger,
  }) : _logger = logger;

  @override
  String get description => 'List all available templates';

  @override
  String get name => 'list';

  final Logger _logger;

  @override
  Future<int> run() async {
    final templateManager = TemplateManager();
    final templates = templateManager.getAllTemplates();

    _logger
      ..info('')
      ..info('Available templates:')
      ..info('');

    for (final entry in templates.entries) {
      _logger.info('${entry.key}: ${entry.value}');
    }

    _logger
      ..info('')
      ..info('Usage example: gitwhisper commit --template default');

    return ExitCode.success.code;
  }
}

class AddTemplateCommand extends Command<int> {
  AddTemplateCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser
      ..addOption(
        'name',
        abbr: 'n',
        help: 'Name of the template',
        mandatory: true,
      )
      ..addOption(
        'format',
        abbr: 'f',
        help: 'Template format string',
        mandatory: true,
      );
  }

  @override
  String get description => 'Add or update a template';

  @override
  String get name => 'add';

  final Logger _logger;

  @override
  Future<int> run() async {
    final name = argResults?['name'] as String;
    final format = argResults?['format'] as String;

    TemplateManager().saveTemplate(name, format);

    _logger.info('Template "$name" saved: $format');

    return ExitCode.success.code;
  }
}

class DeleteTemplateCommand extends Command<int> {
  DeleteTemplateCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser.addOption(
      'name',
      abbr: 'n',
      help: 'Name of the template to delete',
      mandatory: true,
    );
  }

  @override
  String get description => 'Delete a template';

  @override
  String get name => 'delete';

  final Logger _logger;

  @override
  Future<int> run() async {
    final name = argResults?['name'] as String;

    try {
      final templateManager = TemplateManager();
      templateManager.deleteTemplate(name);

      _logger.info('Template "$name" deleted');
    } catch (e) {
      _logger.err('Error: $e');
      return ExitCode.software.code;
    }

    return ExitCode.success.code;
  }
}

class ShowTemplateCommand extends Command<int> {
  ShowTemplateCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser.addOption(
      'name',
      abbr: 'n',
      help: 'Name of the template to show',
      mandatory: true,
    );
  }

  @override
  String get description => 'Show a specific template';

  @override
  String get name => 'show';

  final Logger _logger;

  @override
  Future<int> run() async {
    final name = argResults?['name'] as String;

    final templateManager = TemplateManager();
    final template = templateManager.getTemplate(name);

    _logger
      ..info('')
      ..info('Template "$name":')
      ..info(template)
      ..info('')
      ..info('Available placeholders:')
      ..info('{{type}} - Commit type (feat, fix, etc.)')
      ..info('{{emoji}} - Type-specific emoji')
      ..info('{{description}} - Commit description')
      ..info('{{scope}} - Commit scope if available')
      ..info('{{prefix}} - User-specified prefix')
      ..info('');

    return ExitCode.success.code;
  }
}

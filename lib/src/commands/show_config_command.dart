//
//  gitwhisper
//  show_config_command.dart
//
//  Created by Ngonidzashe Mangudya on 2025/12/29.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../config_manager.dart';
import '../utils.dart';

class ShowConfigCommand extends Command<int> {
  ShowConfigCommand({
    required Logger logger,
  }) : _logger = logger;

  @override
  String get description => 'Shows current config file';

  @override
  String get name => 'show-config';

  final Logger _logger;

  @override
  Future<int> run() async {
    final configManager = ConfigManager();
    await configManager.load();

    final Map<String, dynamic> config = configManager.getConfig();

    _logger.info('Gitwhisper Configs:\n');

    void printConfigMap(Map<String, dynamic> map, {int indent = 0}) {
      final pad = ' ' * indent;

      for (final MapEntry<String, dynamic> entry in map.entries) {
        final key = entry.key.heading;
        final value = entry.value;

        if (value is Map) {
          // Print section header, then recurse
          _logger.info('$pad$key:');
          printConfigMap(
            value.map((k, v) => MapEntry(k.toString(), v)),
            indent: indent + 2,
          );
          continue;
        }

        if (value is List) {
          _logger.info('$pad$key:');
          for (final item in value) {
            _logger.info('$pad  - ${lightCyan.wrap('$item')}');
          }
          continue;
        }

        _logger..info('$pad$key:')
        ..info('$pad  ${lightCyan.wrap('$value')}');
      }
    }

    printConfigMap(config);

    return 0;
  }
}

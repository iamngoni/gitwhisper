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
    ConfigManager? configManager,
  })  : _logger = logger,
        _configManager = configManager {
    argParser.addFlag(
      'reveal',
      help: 'Show full API key values instead of masking them.',
      negatable: false,
    );
  }

  @override
  String get description => 'Shows current config file';

  @override
  String get name => 'show-config';

  final Logger _logger;
  final ConfigManager? _configManager;

  /// Config section whose values are secrets and are masked unless
  /// `--reveal` is passed.
  static const _secretSection = 'api_keys';

  @override
  Future<int> run() async {
    final configManager = _configManager ?? ConfigManager();
    await configManager.load();

    final Map<String, dynamic> config = configManager.getConfig();
    final reveal = argResults?['reveal'] == true;
    var maskedAny = false;

    _logger.info('Gitwhisper Configs:\n');

    String display(Object? value, {required bool secret}) {
      if (!secret || reveal || value == null) return '$value';
      maskedAny = true;
      return maskSecret('$value');
    }

    void printConfigMap(
      Map<String, dynamic> map, {
      int indent = 0,
      bool secret = false,
    }) {
      final pad = ' ' * indent;

      for (final MapEntry<String, dynamic> entry in map.entries) {
        final key = entry.key.heading;
        final value = entry.value;
        final secretEntry = secret || entry.key == _secretSection;

        if (value is Map) {
          // Print section header, then recurse
          _logger.info('$pad$key:');
          printConfigMap(
            value.map((k, v) => MapEntry(k.toString(), v)),
            indent: indent + 2,
            secret: secretEntry,
          );
          continue;
        }

        if (value is List) {
          _logger.info('$pad$key:');
          for (final item in value) {
            final shown = display(item, secret: secretEntry);
            _logger.info('$pad  - ${lightCyan.wrap(shown)}');
          }
          continue;
        }

        final shown = display(value, secret: secretEntry);
        _logger
          ..info('$pad$key:')
          ..info('$pad  ${lightCyan.wrap(shown)}');
      }
    }

    printConfigMap(config);

    if (maskedAny) {
      _logger
        ..info('')
        ..info(
          'API keys are masked. Run `gw show-config --reveal` to show the '
          'full values.',
        );
    }

    return 0;
  }
}

/// Masks a secret for display. Long values keep their first 3 and last 4
/// characters so a key can still be recognized; shorter values are hidden
/// entirely.
String maskSecret(String value) {
  if (value.length < 12) return '****';
  return '${value.substring(0, 3)}…${value.substring(value.length - 4)}';
}

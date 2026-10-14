import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/commands/show_config_command.dart';
import 'package:gitwhisper/src/config_manager.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  group('show-config', () {
    late Directory dir;
    late ConfigManager configManager;
    late _MockLogger logger;
    late List<String> lines;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gw_show_config_test_');
      configManager =
          ConfigManager(configPath: p.join(dir.path, '.git_whisper.yaml'));
      await configManager.load();
      configManager
        ..setApiKey('openai', 'sk-proj-abcdefghijklmnop1234')
        ..setApiKey('grok', 'short')
        ..setOllamaBaseURL('http://localhost:11434');
      await configManager.save();

      lines = <String>[];
      logger = _MockLogger();
      when(() => logger.info(any())).thenAnswer((invocation) {
        lines.add(invocation.positionalArguments.first as String? ?? '');
      });
    });

    tearDown(() => dir.delete(recursive: true));

    Future<int?> run(List<String> args) {
      final runner = CommandRunner<int>('gitwhisper', 'test')
        ..addCommand(
          ShowConfigCommand(
            logger: logger,
            configManager: ConfigManager(
              configPath: p.join(dir.path, '.git_whisper.yaml'),
            ),
          ),
        );
      return runner.run(<String>['show-config', ...args]);
    }

    test('masks every API key by default', () async {
      await run(const <String>[]);
      final output = lines.join('\n');

      expect(output, isNot(contains('sk-proj-abcdefghijklmnop1234')));
      expect(output, contains('sk-…1234'));
      expect(output, isNot(contains('short')));
      expect(output, contains('****'));
      expect(output, contains('--reveal'));
      // Non-secret values are still shown in full.
      expect(output, contains('http://localhost:11434'));
    });

    test('--reveal prints full API key values', () async {
      await run(const <String>['--reveal']);
      final output = lines.join('\n');

      expect(output, contains('sk-proj-abcdefghijklmnop1234'));
      expect(output, contains('short'));
    });
  });

  test('maskSecret keeps only a recognizable prefix and suffix', () {
    expect(maskSecret('sk-ant-api03-0123456789abcdef'), 'sk-…cdef');
    expect(maskSecret('tiny'), '****');
    expect(maskSecret('elevenchars'), '****');
  });
}

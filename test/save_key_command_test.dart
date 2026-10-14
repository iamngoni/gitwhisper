import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/commands/save_key_command.dart';
import 'package:gitwhisper/src/config_manager.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  group('save-key', () {
    late Directory dir;
    late String configPath;
    late _MockLogger logger;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gw_save_key_test_');
      configPath = p.join(dir.path, '.git_whisper.yaml');
      logger = _MockLogger();
    });

    tearDown(() => dir.delete(recursive: true));

    Future<int?> run(List<String> args) {
      final runner = CommandRunner<int>('gitwhisper', 'test')
        ..addCommand(
          SaveKeyCommand(
            logger: logger,
            configManager: ConfigManager(configPath: configPath),
          ),
        );
      return runner.run(<String>['save-key', ...args]);
    }

    Future<String?> savedKey(String model) async {
      final manager = ConfigManager(configPath: configPath);
      await manager.load();
      return manager.getApiKey(model);
    }

    test('prompts with hidden input when --key is omitted', () async {
      when(
        () => logger.prompt(any(), hidden: any(named: 'hidden')),
      ).thenReturn('sk-prompted-secret');

      final exitCode = await run(const <String>['--model', 'openai']);

      expect(exitCode, ExitCode.success.code);
      verify(() => logger.prompt(any(), hidden: true)).called(1);
      verifyNever(() => logger.warn(any()));
      expect(await savedKey('openai'), 'sk-prompted-secret');
    });

    test('still accepts --key but warns about shell history', () async {
      final exitCode = await run(
        const <String>['--model', 'openai', '--key', 'sk-flag-secret'],
      );

      expect(exitCode, ExitCode.success.code);
      final warning =
          verify(() => logger.warn(captureAny())).captured.single as String;
      expect(warning, contains('shell history'));
      expect(warning, contains('hidden prompt'));
      verifyNever(() => logger.prompt(any(), hidden: any(named: 'hidden')));
      expect(await savedKey('openai'), 'sk-flag-secret');
    });

    test('rejects an empty --key', () async {
      final exitCode =
          await run(const <String>['--model', 'openai', '--key', ' ']);

      expect(exitCode, ExitCode.usage.code);
      expect(File(configPath).existsSync(), isFalse);
    });
  });
}

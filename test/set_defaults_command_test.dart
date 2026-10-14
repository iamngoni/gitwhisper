import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/commands/set_defaults_command.dart';
import 'package:gitwhisper/src/config_manager.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SetDefaultsCommand without a terminal', () {
    late Directory home;
    late String configPath;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gw_set_defaults_');
      configPath = p.join(home.path, '.git_whisper.yaml');
    });

    tearDown(() => home.delete(recursive: true));

    Future<int?> run(List<String> args) {
      final runner = CommandRunner<int>('gw', 'test')
        ..addCommand(
          SetDefaultsCommand(
            logger: Logger(level: Level.quiet),
            configManager: ConfigManager(configPath: configPath),
            canPrompt: () => false,
          ),
        );
      return runner.run(['set-defaults', ...args]);
    }

    test('saves the defaults without asking about confirmation', () async {
      final exitCode = await run([
        '--model',
        'ollama',
        '--model-variant',
        'llama3.2:latest',
        '--base-url',
        'http://127.0.0.1:11434',
      ]);

      expect(exitCode, ExitCode.success.code);
      final saved = ConfigManager(configPath: configPath);
      await saved.load();
      expect(saved.getDefaultModelAndVariant(), ('ollama', 'llama3.2:latest'));
    });

    test('changes the emoji setting only when --allow-emojis is passed',
        () async {
      Future<bool> allowsEmojis() async {
        final saved = ConfigManager(configPath: configPath);
        await saved.load();
        return saved.shouldAllowEmojis();
      }

      await run(['--model', 'openai', '--no-allow-emojis']);
      expect(await allowsEmojis(), isFalse);

      final exitCode = await run(['--model', 'claude']);
      expect(exitCode, ExitCode.success.code);
      expect(await allowsEmojis(), isFalse, reason: 'flag not passed');

      await run(['--model', 'claude', '--allow-emojis']);
      expect(await allowsEmojis(), isTrue);
    });

    test('requires --model instead of opening a picker', () async {
      final exitCode = await run(['--model-variant', 'gpt-5.6-terra']);

      expect(exitCode, ExitCode.usage.code);
      expect(File(configPath).existsSync(), isFalse);
    });
  });
}

import 'dart:io';

import 'package:gitwhisper/src/config_manager.dart';
import 'package:gitwhisper/src/user_home.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ConfigManager.save', () {
    late Directory dir;
    late String configPath;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gw_config_test_');
      configPath = p.join(dir.path, '.git_whisper.yaml');
    });

    tearDown(() => dir.delete(recursive: true));

    test(
      'creates the config file owner-only (0600)',
      () async {
        final manager = ConfigManager(configPath: configPath);
        await manager.load();
        manager.setApiKey('openai', 'sk-test-secret-value');
        await manager.save();

        expect(_mode(configPath), 0x180, reason: 'expected 0600');
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : null,
    );

    test(
      'tightens an existing world-readable config file',
      () async {
        File(configPath).writeAsStringSync('{"api_keys":{}}');
        await Process.run('chmod', <String>['644', configPath]);

        final manager = ConfigManager(configPath: configPath);
        await manager.load();
        manager.setApiKey('claude', 'sk-ant-test-value');
        await manager.save();

        expect(_mode(configPath), 0x180, reason: 'expected 0600');
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : null,
    );

    test('replaces the file atomically and leaves no temp files', () async {
      final first = ConfigManager(configPath: configPath);
      await first.load();
      first.setApiKey('openai', 'sk-first-key-value');
      await first.save();

      final second = ConfigManager(configPath: configPath);
      await second.load();
      second.setApiKey('gemini', 'gemini-second-key');
      await second.save();

      final reloaded = ConfigManager(configPath: configPath);
      await reloaded.load();
      expect(reloaded.getApiKey('openai'), 'sk-first-key-value');
      expect(reloaded.getApiKey('gemini'), 'gemini-second-key');
      expect(
        dir.listSync().map((entity) => p.basename(entity.path)),
        <String>['.git_whisper.yaml'],
        reason: 'the staging directory must be cleaned up',
      );
    });

    test(
      'writes through a symlinked config file and keeps the link',
      () async {
        final realFile = File(p.join(dir.path, 'dotfiles', 'git_whisper.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"api_keys":{}}');
        Link(configPath).createSync(realFile.path);

        final manager = ConfigManager(configPath: configPath);
        await manager.load();
        manager.setApiKey('openai', 'sk-linked-key-value');
        await manager.save();

        expect(FileSystemEntity.isLinkSync(configPath), isTrue);
        expect(realFile.readAsStringSync(), contains('sk-linked-key-value'));
        expect(_mode(realFile.path), 0x180, reason: 'expected 0600');
      },
      skip: Platform.isWindows ? 'POSIX symlinks only' : null,
    );
  });

  group('ConfigManager.load', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gw_config_test_');
    });

    tearDown(() => dir.delete(recursive: true));

    test(
      'makes a config file written by older versions owner-only',
      () async {
        final configPath = p.join(dir.path, '.git_whisper.yaml');
        File(configPath).writeAsStringSync('{"api_keys":{"openai":"sk-old"}}');
        await Process.run('chmod', <String>['644', configPath]);

        final manager = ConfigManager(configPath: configPath);
        await manager.load();

        expect(_mode(configPath), 0x180, reason: 'expected 0600');
        expect(manager.getApiKey('openai'), 'sk-old');
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : null,
    );

    test('uses the config file in HOME', () async {
      final manager = ConfigManager(
        environment: <String, String>{'HOME': dir.path},
      );
      await manager.load();
      manager.setApiKey('openai', 'sk-home-key');
      await manager.save();

      expect(
        File(p.join(dir.path, '.git_whisper.yaml')).readAsStringSync(),
        contains('sk-home-key'),
      );
    });

    test(
      'refuses an empty or relative HOME instead of using the working '
      'directory',
      () async {
        // Relative to the working directory, this HOME reaches a folder with
        // a config file. Using it would let a repository supply API keys.
        File(p.join(dir.path, '.git_whisper.yaml'))
            .writeAsStringSync('{"api_keys":{"openai":"sk-cwd"}}');

        for (final home in <String>['', p.relative(dir.path)]) {
          final manager = ConfigManager(
            environment: <String, String>{'HOME': home},
          );

          await expectLater(
            manager.load(),
            throwsA(isA<UserHomeException>()),
            reason: 'HOME="$home"',
          );
        }
      },
      skip: Platform.isWindows ? 'Windows uses USERPROFILE' : null,
    );
  });
}

int _mode(String path) => File(path).statSync().mode & 0x1FF;

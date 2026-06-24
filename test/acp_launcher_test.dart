import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/acp/acp_client.dart';
import 'package:gitwhisper/src/acp/acp_launcher.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ACP launcher', () {
    test('launches npx distributions when no npm install is cached', () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_npm_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'codex-acp',
        'name': 'Codex CLI',
        'version': '0.15.0',
        'distribution': <String, dynamic>{
          'npx': <String, dynamic>{
            'package': '@zed-industries/codex-acp@0.15.0',
          },
        },
      }).resolve('codex-acp');

      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        installBinary: (_, __) async => fail('npx should not install'),
      );
      final statuses = <String>[];

      final command = await launcher.launchCommandFor(
        agent,
        onStatus: statuses.add,
      );

      expect(command.executable, 'npx');
      expect(command.arguments, ['-y', '@zed-industries/codex-acp@0.15.0']);
      expect(command.workingDirectory, isNull);
      expect(statuses, ['Using npx package @zed-industries/codex-acp@0.15.0']);
    });

    test('installs npx distributions and launches the cached npm bin',
        () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_npm_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'codex-acp',
        'name': 'Codex CLI',
        'version': '0.15.0',
        'distribution': <String, dynamic>{
          'npx': <String, dynamic>{
            'package': '@zed-industries/codex-acp@0.15.0',
          },
        },
      }).resolve('codex-acp');
      final statuses = <String>[];
      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        platformKey: 'darwin-aarch64',
        installNpm: (packageSpec, directory) async {
          expect(packageSpec, '@zed-industries/codex-acp@0.15.0');
          await _writeFakeNpmPackage(
            directory: directory,
            packageName: '@zed-industries/codex-acp',
            binName: 'codex-acp',
          );
        },
      );

      await launcher.install(agent, onStatus: statuses.add);
      final command =
          await launcher.launchCommandFor(agent, onStatus: statuses.add);

      final npmDirectory = p.join(
        temp.path,
        'codex-acp',
        '0.15.0',
        'darwin-aarch64',
        'npm',
      );
      expect(
        command.executable,
        p.join(npmDirectory, 'node_modules', '.bin', _binFileName('codex-acp')),
      );
      expect(command.arguments, isEmpty);
      expect(command.workingDirectory, npmDirectory);
      expect(
        statuses,
        contains('Installing npm package @zed-industries/codex-acp@0.15.0'),
      );
      expect(
        statuses,
        contains(
          'Using installed npm package @zed-industries/codex-acp@0.15.0',
        ),
      );
    });

    test('launches platform binary distributions from the agent cache',
        () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_bin_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'vtcode',
        'name': 'VT Code',
        'version': '0.96.14',
        'distribution': <String, dynamic>{
          'binary': <String, dynamic>{
            'darwin-aarch64': <String, dynamic>{
              'archive': 'https://example.com/vtcode.tar.gz',
              'cmd': './vtcode',
              'args': <String>['acp'],
              'env': <String, String>{
                'VT_ACP_ENABLED': '1',
              },
            },
          },
        },
      }).resolve('vtcode');

      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        platformKey: 'darwin-aarch64',
        installBinary: (binary, directory) async {
          await File(p.join(directory.path, 'vtcode')).writeAsString('fake');
        },
      );

      final command = await launcher.launchCommandFor(agent);

      expect(
        command.executable,
        p.join(temp.path, 'vtcode', '0.96.14', 'darwin-aarch64', 'vtcode'),
      );
      expect(command.arguments, ['acp']);
      expect(command.environment, containsPair('VT_ACP_ENABLED', '1'));
      expect(
        command.workingDirectory,
        p.join(temp.path, 'vtcode', '0.96.14', 'darwin-aarch64'),
      );
    });

    test('reports install progress when launch installs a binary', () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_bin_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'junie',
        'name': 'Junie',
        'version': '1668.43.0',
        'distribution': <String, dynamic>{
          'binary': <String, dynamic>{
            'darwin-aarch64': <String, dynamic>{
              'archive': 'https://example.com/junie.tar.gz',
              'cmd': './junie',
              'args': <String>['acp'],
            },
          },
        },
      }).resolve('junie');
      final statuses = <String>[];

      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        platformKey: 'darwin-aarch64',
        installBinary: (binary, directory) async {
          await File(p.join(directory.path, 'junie')).writeAsString('fake');
        },
      );

      await launcher.launchCommandFor(agent, onStatus: statuses.add);

      expect(statuses, contains('Installing test binary'));
    });

    test('reports platform-specific unsupported binaries clearly', () async {
      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'vtcode',
        'name': 'VT Code',
        'version': '0.96.14',
        'distribution': <String, dynamic>{
          'binary': <String, dynamic>{
            'linux-x86_64': <String, dynamic>{
              'archive': 'https://example.com/vtcode.tar.gz',
              'cmd': './vtcode',
            },
          },
        },
      }).resolve('vtcode');

      final launcher = AcpAgentLauncher(
        cacheDirectory: Directory.systemTemp,
        platformKey: 'darwin-aarch64',
      );

      expect(
        () => launcher.launchCommandFor(agent),
        throwsA(isA<AcpRegistryException>()),
      );
    });

    test('maps fallback auth commands to cached platform binaries', () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_bin_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'poolside',
        'name': 'Poolside',
        'version': '1.0.0',
        'distribution': <String, dynamic>{
          'binary': <String, dynamic>{
            'darwin-aarch64': <String, dynamic>{
              'archive': 'https://example.com/pool.tar.gz',
              'cmd': './pool-darwin-arm64',
              'args': <String>['acp'],
            },
          },
        },
      }).resolve('poolside');

      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        platformKey: 'darwin-aarch64',
        installBinary: (binary, directory) async {
          await File(
            p.join(directory.path, 'pool-darwin-arm64'),
          ).writeAsString('fake');
        },
      );

      final command = await launcher.authLaunchCommandFor(
        agent,
        const AcpAuthMethod(
          id: 'terminal-auth',
          name: 'Terminal authentication',
          description: 'Run `pool login`.',
          type: 'terminal',
          command: <String>['pool', 'login'],
        ),
      );

      expect(
        command.executable,
        p.join(
          temp.path,
          'poolside',
          '1.0.0',
          'darwin-aarch64',
          'pool-darwin-arm64',
        ),
      );
      expect(command.arguments, ['login']);
    });

    test('maps fallback auth commands through npx packages', () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_npm_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'auggie',
        'name': 'Auggie CLI',
        'version': '0.28.0',
        'distribution': <String, dynamic>{
          'npx': <String, dynamic>{
            'package': '@augmentcode/auggie@0.28.0',
            'env': <String, String>{'AUGMENT_ACP': '1'},
          },
        },
      }).resolve('auggie');

      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        installBinary: (_, __) async => fail('npx should not install'),
      );

      final command = await launcher.authLaunchCommandFor(
        agent,
        const AcpAuthMethod(
          id: 'terminal-auth',
          name: 'Terminal authentication',
          description: 'Run `auggie login`.',
          type: 'terminal',
          command: <String>['auggie', 'login'],
        ),
      );

      expect(command.executable, 'npx');
      expect(command.arguments, ['-y', '@augmentcode/auggie@0.28.0', 'login']);
      expect(command.environment, containsPair('AUGMENT_ACP', '1'));
    });

    test('maps fallback auth commands through installed npm packages',
        () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_npm_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'auggie',
        'name': 'Auggie CLI',
        'version': '0.28.0',
        'distribution': <String, dynamic>{
          'npx': <String, dynamic>{
            'package': '@augmentcode/auggie@0.28.0',
            'env': <String, String>{'AUGMENT_ACP': '1'},
          },
        },
      }).resolve('auggie');
      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        platformKey: 'darwin-aarch64',
        installNpm: (packageSpec, directory) async {
          await _writeFakeNpmPackage(
            directory: directory,
            packageName: '@augmentcode/auggie',
            binName: 'auggie',
          );
        },
      );

      await launcher.install(agent);
      final command = await launcher.authLaunchCommandFor(
        agent,
        const AcpAuthMethod(
          id: 'terminal-auth',
          name: 'Terminal authentication',
          description: 'Run `auggie login`.',
          type: 'terminal',
          command: <String>['auggie', 'login'],
        ),
      );

      expect(command.executable, isNot('npx'));
      expect(command.arguments, ['login']);
      expect(command.environment, containsPair('AUGMENT_ACP', '1'));
      expect(command.workingDirectory, contains(p.join('auggie', '0.28.0')));
    });

    test('maps generic agent auth command to cursor-agent binary', () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_bin_');
      addTearDown(() => temp.delete(recursive: true));

      final agent = _registryFromAgent(<String, dynamic>{
        'id': 'cursor',
        'name': 'Cursor',
        'version': '2026.05.20',
        'distribution': <String, dynamic>{
          'binary': <String, dynamic>{
            'darwin-aarch64': <String, dynamic>{
              'archive': 'https://example.com/cursor.tar.gz',
              'cmd': './dist-package/cursor-agent',
              'args': <String>['acp'],
            },
          },
        },
      }).resolve('cursor');

      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        platformKey: 'darwin-aarch64',
        installBinary: (binary, directory) async {
          await Directory(
            p.join(directory.path, 'dist-package'),
          ).create(recursive: true);
          await File(
            p.join(directory.path, 'dist-package', 'cursor-agent'),
          ).writeAsString('fake');
        },
      );

      final command = await launcher.authLaunchCommandFor(
        agent,
        const AcpAuthMethod(
          id: 'cursor_login',
          name: 'Terminal authentication',
          description: "Run 'agent login'.",
          type: 'terminal',
          command: <String>['agent', 'login'],
          authenticateMethodId: 'cursor_login',
        ),
      );

      expect(
        command.executable,
        p.join(
          temp.path,
          'cursor',
          '2026.05.20',
          'darwin-aarch64',
          'dist-package',
          'cursor-agent',
        ),
      );
      expect(command.arguments, ['login']);
    });
  });
}

Future<void> _writeFakeNpmPackage({
  required Directory directory,
  required String packageName,
  required String binName,
}) async {
  final packageDirectory = Directory(
    p.joinAll(<String>[
      directory.path,
      'node_modules',
      ...packageName.split('/'),
    ]),
  );
  await packageDirectory.create(recursive: true);
  await File(p.join(packageDirectory.path, 'package.json')).writeAsString(
    jsonEncode(<String, dynamic>{
      'name': packageName,
      'bin': <String, String>{
        binName: 'bin/$binName.js',
      },
    }),
  );

  final binDirectory =
      Directory(p.join(directory.path, 'node_modules', '.bin'));
  await binDirectory.create(recursive: true);
  await File(p.join(binDirectory.path, _binFileName(binName))).writeAsString(
    '#!/usr/bin/env node\n',
  );
}

String _binFileName(String binName) {
  return Platform.isWindows ? '$binName.cmd' : binName;
}

AcpRegistry _registryFromAgent(Map<String, dynamic> agent) {
  return AcpRegistry.fromJson(
    jsonDecode(
      jsonEncode(<String, dynamic>{
        'agents': <Map<String, dynamic>>[agent],
      }),
    ) as Map<String, dynamic>,
  );
}

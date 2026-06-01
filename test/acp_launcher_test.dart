import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/acp/acp_client.dart';
import 'package:gitwhisper/src/acp/acp_launcher.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ACP launcher', () {
    test('launches npx distributions without installing a binary', () async {
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
        cacheDirectory: Directory.systemTemp,
        installBinary: (_, __) async => fail('npx should not install'),
      );

      final command = await launcher.launchCommandFor(agent);

      expect(command.executable, 'npx');
      expect(command.arguments, ['-y', '@zed-industries/codex-acp@0.15.0']);
      expect(command.workingDirectory, isNull);
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
  });
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

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/acp/acp_launcher.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:gitwhisper/src/commands/acp_command.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('acp list returns agents from the cached registry', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>['acp', 'list']);

    expect(exitCode, ExitCode.success.code);
  });

  test('acp list --all includes unsupported registry entries', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'list',
      '--all',
    ]);

    expect(exitCode, ExitCode.success.code);
  });

  test('acp resolve resolves aliases', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'resolve',
      'codex',
    ]);

    expect(exitCode, ExitCode.success.code);
  });

  test('acp resolve rejects unsupported generic agents', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'resolve',
      'vtcode',
    ]);

    expect(exitCode, ExitCode.software.code);
  });

  test('acp info shows binary-only agents', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'info',
      'vtcode',
    ]);

    expect(exitCode, ExitCode.success.code);
  });

  test('acp install installs binary-only agents', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'install',
      'vtcode',
    ]);

    expect(exitCode, ExitCode.success.code);
    expect(
      File(
        p.join(
          fixture.agentCache.path,
          'vtcode',
          '0.96.14',
          'darwin-aarch64',
          'vtcode',
        ),
      ).existsSync(),
      isTrue,
    );
  });

  test('acp install installs npx agents into the npm cache', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'install',
      'codex',
    ]);

    expect(exitCode, ExitCode.success.code);
    expect(
      File(
        p.join(
          fixture.agentCache.path,
          'codex-acp',
          '0.15.0',
          'darwin-aarch64',
          'npm',
          'node_modules',
          '.bin',
          _binFileName('codex-acp'),
        ),
      ).existsSync(),
      isTrue,
    );
  });

  test('acp cache path returns cache locations', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'cache',
      'path',
    ]);

    expect(exitCode, ExitCode.success.code);
  });
}

class AcpCommandFixture {
  AcpCommandFixture._({
    required this.root,
    required this.agentCache,
    required this.runner,
  });

  final Directory root;
  final Directory agentCache;
  final CommandRunner<int> runner;

  static Future<AcpCommandFixture> create() async {
    final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_cmd_');
    final agentCache = await Directory(p.join(temp.path, 'agents')).create();
    final registryFile = File(p.join(temp.path, 'registry.json'));
    await registryFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'agents': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'codex-acp',
            'name': 'Codex CLI',
            'version': '0.15.0',
            'distribution': <String, dynamic>{
              'npx': <String, dynamic>{
                'package': '@zed-industries/codex-acp@0.15.0',
              },
            },
          },
          <String, dynamic>{
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
          },
        ],
      }),
    );

    final runner = CommandRunner<int>('gitwhisper_test', 'test')
      ..addCommand(
        AcpCommand(
          logger: Logger(),
          registryLoader: AcpRegistryLoader(
            registryUrl: 'http://127.0.0.1:1/unused.json',
            cacheFile: registryFile,
          ),
          agentLauncher: AcpAgentLauncher(
            cacheDirectory: agentCache,
            platformKey: 'darwin-aarch64',
            installBinary: (_, directory) async {
              await File(p.join(directory.path, 'vtcode'))
                  .writeAsString('fake');
            },
            installNpm: (packageSpec, directory) async {
              expect(packageSpec, '@zed-industries/codex-acp@0.15.0');
              await _writeFakeNpmPackage(
                directory: directory,
                packageName: '@zed-industries/codex-acp',
                binName: 'codex-acp',
              );
            },
          ),
        ),
      );

    return AcpCommandFixture._(
      root: temp,
      agentCache: agentCache,
      runner: runner,
    );
  }

  Future<void> dispose() => root.delete(recursive: true);
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

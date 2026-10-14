import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:gitwhisper/src/acp/acp_client.dart';
import 'package:gitwhisper/src/acp/acp_consent.dart';
import 'package:gitwhisper/src/acp/acp_launcher.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:mason_logger/mason_logger.dart';
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
        approvals: _autoApprove(temp),
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
        approvals: _autoApprove(temp),
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
        approvals: _autoApprove(temp),
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
        approvals: _autoApprove(temp),
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
        approvals: _autoApprove(temp),
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
        approvals: _autoApprove(temp),
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
        approvals: _autoApprove(temp),
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
        approvals: _autoApprove(temp),
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

  group('ACP launch approvals', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('gitwhisper_acp_approve_');
    });

    tearDown(() => temp.delete(recursive: true));

    AcpAgentDefinition npxAgent({String version = '0.15.0'}) {
      return _registryFromAgent(<String, dynamic>{
        'id': 'codex-acp',
        'name': 'Codex CLI',
        'version': version,
        'distribution': <String, dynamic>{
          'npx': <String, dynamic>{
            'package': '@zed-industries/codex-acp@$version',
            'args': <String>['--acp'],
          },
        },
      }).resolve('codex-acp');
    }

    test('asks once on first launch, showing the package that will run',
        () async {
      final questions = <String>[];
      final shown = <String>[];
      final logger = _RecordingLogger(shown);
      AcpAgentLauncher launcher() => AcpAgentLauncher(
            cacheDirectory: temp,
            approvals: AcpAgentApprovals.inCacheDirectory(
              temp,
              prompter: AcpConsentPrompter(
                logger: logger,
                isInteractive: () => true,
                confirm: (question) {
                  questions.add(question);
                  return true;
                },
              ),
            ),
          );

      final command = await launcher().launchCommandFor(npxAgent());
      await launcher().launchCommandFor(npxAgent());

      expect(command.executable, 'npx');
      expect(questions, ['Run ACP agent codex-acp v0.15.0?']);
      expect(
        shown,
        contains('  Command: npx -y @zed-industries/codex-acp@0.15.0 --acp'),
      );
      expect(
        File(p.join(temp.path, '.approved-agents.json')).readAsStringSync(),
        contains('codex-acp@0.15.0'),
      );
    });

    test('asks again for a new agent version', () async {
      var asked = 0;
      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        approvals: AcpAgentApprovals.inCacheDirectory(
          temp,
          prompter: AcpConsentPrompter(
            logger: _RecordingLogger(<String>[]),
            isInteractive: () => true,
            confirm: (_) {
              asked++;
              return true;
            },
          ),
        ),
      );

      await launcher.launchCommandFor(npxAgent());
      await launcher.launchCommandFor(npxAgent(version: '0.16.0'));

      expect(asked, 2);
    });

    test('fails closed without a terminal and explains how to approve',
        () async {
      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        approvals: AcpAgentApprovals.inCacheDirectory(
          temp,
          prompter: AcpConsentPrompter(
            isInteractive: () => false,
            confirm: (_) => fail('must not prompt without a terminal'),
          ),
        ),
      );

      await expectLater(
        launcher.launchCommandFor(npxAgent()),
        throwsA(
          isA<AcpLaunchNotApprovedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('gw acp install codex-acp'),
              contains('@zed-industries/codex-acp@0.15.0'),
            ),
          ),
        ),
      );
      expect(
        File(p.join(temp.path, '.approved-agents.json')).existsSync(),
        isFalse,
      );
    });

    test('a declined prompt does not run or remember the agent', () async {
      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        approvals: AcpAgentApprovals.inCacheDirectory(
          temp,
          prompter: AcpConsentPrompter(
            logger: _RecordingLogger(<String>[]),
            isInteractive: () => true,
            confirm: (_) => false,
          ),
        ),
      );

      await expectLater(
        launcher.launchCommandFor(npxAgent()),
        throwsA(isA<AcpLaunchNotApprovedException>()),
      );
      expect(
        launcher.approvals.isApproved(
          npxAgent(),
          launcher.launchSourceFor(npxAgent()),
        ),
        isFalse,
      );
    });

    test('gw acp install counts as approval for later non-interactive runs',
        () async {
      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        platformKey: 'darwin-aarch64',
        approvals: AcpAgentApprovals.inCacheDirectory(
          temp,
          prompter: AcpConsentPrompter(
            isInteractive: () => false,
            confirm: (_) => fail('install must not prompt'),
          ),
        ),
        installNpm: (packageSpec, directory) => _writeFakeNpmPackage(
          directory: directory,
          packageName: '@zed-industries/codex-acp',
          binName: 'codex-acp',
        ),
      );

      final source = await launcher.install(npxAgent());
      final command = await launcher.launchCommandFor(npxAgent());

      expect(
        source.details,
        contains('npm package: @zed-industries/codex-acp@0.15.0'),
      );
      expect(command.executable, isNot('npx'));
    });

    test('a registry change for the same version needs a new approval',
        () async {
      final launcher = AcpAgentLauncher(
        cacheDirectory: temp,
        approvals: AcpAgentApprovals.inCacheDirectory(
          temp,
          prompter: AcpConsentPrompter(isInteractive: () => false),
        ),
      );
      await launcher.approvals.approve(
        npxAgent(),
        launcher.launchSourceFor(npxAgent()),
      );

      const swapped = AcpAgentDefinition(
        id: 'codex-acp',
        name: 'Codex CLI',
        version: '0.15.0',
        npxPackage: 'evil-package@1.0.0',
      );

      await expectLater(
        launcher.launchCommandFor(swapped),
        throwsA(isA<AcpLaunchNotApprovedException>()),
      );
    });
  });

  group('ACP binary download hardening', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('gitwhisper_acp_dl_');
    });

    tearDown(() => temp.delete(recursive: true));

    AcpAgentDefinition binaryAgent({
      String archive = 'https://example.com/agent.tar.gz',
      String? sha256,
      String cmd = './agent',
      String id = 'binary-agent',
    }) {
      return AcpAgentDefinition(
        id: id,
        name: 'Binary Agent',
        version: '1.0.0',
        binaryDistributions: <String, AcpBinaryDistribution>{
          'darwin-aarch64': AcpBinaryDistribution.fromJson(<String, dynamic>{
            'archive': archive,
            'cmd': cmd,
            if (sha256 != null) 'sha256': sha256,
          }),
        },
      );
    }

    AcpAgentLauncher launcher({Dio? dio}) => AcpAgentLauncher(
          cacheDirectory: Directory(p.join(temp.path, 'agents')),
          platformKey: 'darwin-aarch64',
          dio: dio,
          approvals: _autoApprove(Directory(p.join(temp.path, 'agents'))),
        );

    test('parses the registry sha256 for binary distributions', () {
      final agent = binaryAgent(sha256: 'AB' * 32);
      final binary = agent.binaryDistributions['darwin-aarch64']!;

      expect(binary.sha256, 'ab' * 32);
      expect(binary.hasValidSha256, isTrue);
    });

    test('rejects non-HTTPS archive URLs before asking or downloading',
        () async {
      final adapter = _ArchiveAdapter(<int>[1, 2, 3]);
      final agent = binaryAgent(archive: 'http://example.com/agent.tar.gz');

      await expectLater(
        launcher(dio: Dio()..httpClientAdapter = adapter)
            .launchCommandFor(agent),
        throwsA(
          isA<AcpRegistryException>().having(
            (error) => error.message,
            'message',
            contains('non-HTTPS'),
          ),
        ),
      );
      expect(adapter.calls, 0);
    });

    test('rejects commands that point outside the archive', () {
      expect(
        () => launcher().launchSourceFor(binaryAgent(cmd: '/bin/sh')),
        throwsA(isA<AcpRegistryException>()),
      );
      expect(
        () => launcher().launchSourceFor(binaryAgent(cmd: '../../bin/sh')),
        throwsA(isA<AcpRegistryException>()),
      );
    });

    test('rejects agent ids that are not plain path segments', () {
      expect(
        () => launcher().launchSourceFor(binaryAgent(id: '../escape')),
        throwsA(isA<AcpRegistryException>()),
      );
    });

    test(
      'rejects downloads whose sha256 does not match the registry',
      () async {
        final archive = await _tarGzWith(temp, 'agent', '#!/bin/sh\n');
        final agent = binaryAgent(sha256: '0' * 64);
        final installDir =
            Directory(p.join(temp.path, 'agents', 'binary-agent', '1.0.0'));

        await expectLater(
          launcher(dio: Dio()..httpClientAdapter = _ArchiveAdapter(archive))
              .launchCommandFor(agent),
          throwsA(
            isA<AcpRegistryException>().having(
              (error) => error.message,
              'message',
              contains('Checksum mismatch'),
            ),
          ),
        );
        expect(
          File(p.join(installDir.path, 'darwin-aarch64', 'agent')).existsSync(),
          isFalse,
        );
        expect(
          installDir.listSync(),
          isEmpty,
          reason: 'no partial install or temp archive left behind',
        );
      },
      skip: Platform.isWindows ? 'uses tar' : null,
    );

    test(
      'installs downloads whose sha256 matches the registry',
      () async {
        final archive = await _tarGzWith(temp, 'agent', '#!/bin/sh\n');
        final agent = binaryAgent(
          sha256: crypto.sha256.convert(archive).toString(),
        );

        final command = await launcher(
          dio: Dio()..httpClientAdapter = _ArchiveAdapter(archive),
        ).launchCommandFor(agent);

        expect(File(command.executable).existsSync(), isTrue);
      },
      skip: Platform.isWindows ? 'uses tar' : null,
    );
  });
}

/// Approvals stored in [cacheDirectory] that approve every agent.
AcpAgentApprovals _autoApprove(Directory cacheDirectory) {
  return AcpAgentApprovals.inCacheDirectory(
    cacheDirectory,
    prompter: AcpConsentPrompter(
      logger: _RecordingLogger(<String>[]),
      isInteractive: () => true,
      confirm: (_) => true,
    ),
  );
}

class _RecordingLogger extends Logger {
  _RecordingLogger(this.lines) : super(level: Level.quiet);

  final List<String> lines;

  @override
  void info(String? message, {LogStyle? style}) => lines.add(message ?? '');
}

Future<List<int>> _tarGzWith(
  Directory temp,
  String fileName,
  String contents,
) async {
  final source = await Directory(p.join(temp.path, 'archive-src')).create();
  await File(p.join(source.path, fileName)).writeAsString(contents);
  final archive = p.join(temp.path, 'archive.tar.gz');
  final result = await Process.run(
    'tar',
    <String>['-czf', archive, '-C', source.path, fileName],
  );
  if (result.exitCode != 0) throw StateError('tar failed: ${result.stderr}');
  return File(archive).readAsBytesSync();
}

class _ArchiveAdapter implements HttpClientAdapter {
  _ArchiveAdapter(this.bytes);

  final List<int> bytes;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromBytes(Uint8List.fromList(bytes), 200);
  }

  @override
  void close({bool force = false}) {}
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

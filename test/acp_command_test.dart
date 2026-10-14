import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/acp/acp_consent.dart';
import 'package:gitwhisper/src/acp/acp_launcher.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:gitwhisper/src/acp/acp_repo_trust.dart';
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

  test('acp install approves the agent for non-interactive launches', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);
    final registry = await AcpRegistryLoader(
      registryUrl: 'http://127.0.0.1:1/unused.json',
      cacheFile: File(p.join(fixture.root.path, 'registry.json')),
    ).load();
    final agent = registry.resolve('vtcode');

    await expectLater(
      fixture.launcher.launchCommandFor(agent),
      throwsA(isA<AcpLaunchNotApprovedException>()),
      reason: 'not approved before install',
    );

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'install',
      'vtcode',
    ]);
    final command = await fixture.launcher.launchCommandFor(agent);

    expect(exitCode, ExitCode.success.code);
    expect(command.arguments, ['acp']);
  });

  test('acp info rejects partial agent ids with a suggestion', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'info',
      'vtcod',
    ]);

    expect(exitCode, ExitCode.software.code);
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

  test('acp trust trusts the repository and acp untrust removes it', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);
    final repo = Directory(
      p.join(fixture.root.resolveSymbolicLinksSync(), 'repo'),
    );
    Directory(p.join(repo.path, '.git')).createSync(recursive: true);
    Directory(p.join(repo.path, '.claude')).createSync();
    final subdirectory = Directory(p.join(repo.path, 'src'))..createSync();
    bool isTrusted() =>
        AcpTrustedRepos(file: fixture.trustFile).isTrusted(repo.path);

    expect(
      await fixture.runner.run(<String>['acp', 'trust', subdirectory.path]),
      ExitCode.success.code,
    );
    expect(isTrusted(), isTrue, reason: 'trust covers the whole repository');

    expect(
      await fixture.runner.run(<String>['acp', 'untrust', repo.path]),
      ExitCode.success.code,
    );
    expect(isTrusted(), isFalse);
  });

  test('acp trust rejects a path that is not a directory', () async {
    final fixture = await AcpCommandFixture.create();
    addTearDown(fixture.dispose);

    final exitCode = await fixture.runner.run(<String>[
      'acp',
      'trust',
      p.join(fixture.root.path, 'missing'),
    ]);

    expect(exitCode, ExitCode.usage.code);
    expect(fixture.trustFile.existsSync(), isFalse);
  });

  test(
    'reports a missing home directory instead of using the current one',
    () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_no_home_');
      addTearDown(() => temp.delete(recursive: true));
      final script = File(p.join(temp.path, 'no_home.dart'))
        ..writeAsStringSync(_noHomeScript);
      final cwd = await Directory(p.join(temp.path, 'repo')).create();
      final packageConfig =
          p.join(Directory.current.path, '.dart_tool', 'package_config.json');

      final result = await Process.run(
        Platform.resolvedExecutable,
        <String>['--packages=$packageConfig', script.path],
        workingDirectory: cwd.path,
        environment: <String, String>{'HOME': '', 'USERPROFILE': ''},
      );

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(LineSplitter.split(result.stdout as String), <String>[
        'acp cache path: ${ExitCode.config.code}',
        'registry: no home',
        'agents: no home',
        'logs: no home',
        'trust: no home',
      ]);
      expect(
        result.stderr,
        contains('Could not determine your home directory'),
      );
      expect(
        cwd.listSync(),
        isEmpty,
        reason: 'nothing is read from or written to the current directory',
      );
    },
    skip: Platform.isWindows ? 'POSIX HOME only' : null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Builds `gw acp` and every ACP default with no home directory, then runs
/// `gw acp cache path`.
const _noHomeScript = r'''
import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/acp/acp_debug_log.dart';
import 'package:gitwhisper/src/acp/acp_launcher.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:gitwhisper/src/acp/acp_repo_trust.dart';
import 'package:gitwhisper/src/commands/acp_command.dart';
import 'package:gitwhisper/src/user_home.dart';
import 'package:mason_logger/mason_logger.dart';

Future<void> main() async {
  final runner = CommandRunner<int>('gw', 'test')
    ..addCommand(AcpCommand(logger: Logger()));
  print('acp cache path: ${await runner.run(['acp', 'cache', 'path'])}');

  void check(String name, Object Function() resolve) {
    try {
      print('$name: ${resolve()}');
    } on UserHomeException {
      print('$name: no home');
    }
  }

  check('registry', () => AcpRegistryLoader().cacheFile.path);
  check('agents', () => AcpAgentLauncher().cacheDirectory.path);
  check('logs', () => AcpDebugLogs().directory.path);
  check('trust', () => AcpTrustedRepos().file.path);
}
''';

class AcpCommandFixture {
  AcpCommandFixture._({
    required this.root,
    required this.agentCache,
    required this.trustFile,
    required this.runner,
    required this.launcher,
  });

  final Directory root;
  final Directory agentCache;
  final File trustFile;
  final CommandRunner<int> runner;
  final AcpAgentLauncher launcher;

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

    final launcher = AcpAgentLauncher(
      cacheDirectory: agentCache,
      platformKey: 'darwin-aarch64',
      // Tests have no terminal: launches outside `acp install` fail closed.
      approvals: AcpAgentApprovals.inCacheDirectory(
        agentCache,
        prompter: AcpConsentPrompter(
          isInteractive: () => false,
          confirm: (_) => fail('acp commands must not prompt'),
        ),
      ),
      installBinary: (_, directory) async {
        await File(p.join(directory.path, 'vtcode')).writeAsString('fake');
      },
      installNpm: (packageSpec, directory) async {
        expect(packageSpec, '@zed-industries/codex-acp@0.15.0');
        await _writeFakeNpmPackage(
          directory: directory,
          packageName: '@zed-industries/codex-acp',
          binName: 'codex-acp',
        );
      },
    );

    final trustFile = File(p.join(temp.path, 'trusted-repos.json'));
    final runner = CommandRunner<int>('gitwhisper_test', 'test')
      ..addCommand(
        AcpCommand(
          logger: Logger(),
          registryLoader: AcpRegistryLoader(
            registryUrl: 'http://127.0.0.1:1/unused.json',
            cacheFile: registryFile,
          ),
          agentLauncher: launcher,
          trustedRepos: AcpTrustedRepos(file: trustFile),
        ),
      );

    return AcpCommandFixture._(
      root: temp,
      agentCache: agentCache,
      trustFile: trustFile,
      runner: runner,
      launcher: launcher,
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

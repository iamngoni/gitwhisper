import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/acp/acp_consent.dart';
import 'package:gitwhisper/src/acp/acp_repo_trust.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory repo;
  late File trustFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gitwhisper_acp_trust_');
    // Real paths, so expectations match what the scan reports on macOS,
    // where the temp directory is behind a symlink.
    temp = Directory(temp.resolveSymbolicLinksSync());
    repo = await Directory(p.join(temp.path, 'repo')).create();
    await Directory(p.join(repo.path, '.git')).create();
    trustFile = File(p.join(temp.path, 'home', 'trusted-repos.json'));
  });

  tearDown(() => temp.delete(recursive: true));

  void touch(String relativePath, {bool directory = false}) {
    final target = p.joinAll(<String>[repo.path, ...relativePath.split('/')]);
    if (directory) {
      Directory(target).createSync(recursive: true);
    } else {
      File(target)
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
    }
  }

  List<String> foundIn(String directory) => AcpTrustedRepos.scan(directory)
      .agentConfig
      .map((config) => config.displayPath)
      .toList();

  group('scan', () {
    test('finds every listed agent config path', () {
      for (final entry in acpRepoAgentConfigPaths.keys) {
        touch(entry, directory: !entry.contains('.json') && entry != '.npmrc');
      }

      final found = AcpTrustedRepos.scan(repo.path).agentConfig;

      expect(
        found.map((config) => config.relativePath),
        unorderedEquals(acpRepoAgentConfigPaths.keys),
      );
      expect(foundIn(repo.path), containsAll(['.claude/', '.mcp.json']));
    });

    test('ignores plain instruction files and unrelated config', () {
      touch('AGENTS.md');
      touch('CLAUDE.md');
      touch('GEMINI.md');
      touch('.github/workflows/ci.yaml');
      touch('.vscode/settings.json');
      touch('package.json');

      expect(foundIn(repo.path), isEmpty);
    });

    test('flags symlinks, even dangling ones', () {
      Link(p.join(repo.path, '.claude')).createSync('/nonexistent/claude');

      expect(foundIn(repo.path), ['.claude']);
    });

    test('checks from a subdirectory up to the repository root only', () {
      touch('.mcp.json');
      touch('packages/app/.gemini', directory: true);
      // Above the repository root: not supplied by the repository.
      Directory(p.join(temp.path, '.claude')).createSync();
      final subdirectory = Directory(p.join(repo.path, 'packages', 'app'));

      final scan = AcpTrustedRepos.scan(subdirectory.path);

      expect(scan.root, repo.path);
      expect(
        scan.agentConfig.map((config) => config.displayPath),
        ['.mcp.json', 'packages/app/.gemini/'],
      );
    });

    test('outside a git repository, checks only the directory itself', () {
      final plain = Directory(p.join(temp.path, 'plain', 'project'))
        ..createSync(recursive: true);
      Directory(p.join(temp.path, 'plain', '.claude')).createSync();
      File(p.join(plain.path, '.npmrc')).writeAsStringSync('x=1');

      final scan = AcpTrustedRepos.scan(plain.path);

      expect(scan.root, plain.path);
      expect(scan.agentConfig.map((config) => config.displayPath), [
        '.npmrc',
      ]);
    });

    test('treats a .git file (worktree or submodule) as the root', () {
      final worktree = Directory(p.join(temp.path, 'worktree'))..createSync();
      File(p.join(worktree.path, '.git')).writeAsStringSync('gitdir: x');
      Directory(p.join(worktree.path, '.codex')).createSync();

      final scan = AcpTrustedRepos.scan(worktree.path);

      expect(scan.root, worktree.path);
      expect(scan.agentConfig.single.displayPath, '.codex/');
    });
  });

  group('ensureTrusted', () {
    AcpTrustedRepos trustedRepos({
      bool interactive = true,
      bool answer = true,
      List<String>? questions,
      List<String>? shown,
    }) {
      return AcpTrustedRepos(
        file: trustFile,
        prompter: AcpConsentPrompter(
          logger: _RecordingLogger(shown ?? <String>[]),
          isInteractive: () => interactive,
          confirm: (question) {
            questions?.add(question);
            return answer;
          },
        ),
      );
    }

    test('does not ask, or touch the trust file, without agent config',
        () async {
      touch('AGENTS.md');

      await AcpTrustedRepos(
        file: trustFile,
        prompter: AcpConsentPrompter(
          isInteractive: () => true,
          confirm: (_) => fail('nothing to trust'),
        ),
      ).ensureTrusted(repo.path, agentId: 'claude-acp');

      expect(trustFile.existsSync(), isFalse);
    });

    test('lists what it found, asks once and remembers the repository',
        () async {
      touch('.claude/settings.json');
      touch('node_modules', directory: true);
      final questions = <String>[];
      final shown = <String>[];

      await trustedRepos(questions: questions, shown: shown)
          .ensureTrusted(repo.path, agentId: 'claude-acp');
      await trustedRepos(questions: questions)
          .ensureTrusted(p.join(repo.path, '.claude'), agentId: 'codex-acp');

      expect(questions, hasLength(1));
      expect(questions.single, contains(repo.path));
      expect(shown, contains(contains('.claude/')));
      expect(shown, contains(contains('node_modules/')));
      expect(shown, contains(contains('run commands')));
      final stored = jsonDecode(trustFile.readAsStringSync()) as Map;
      expect((stored['trusted'] as Map).keys, [repo.path]);
      if (!Platform.isWindows) {
        expect(trustFile.statSync().mode & 0x1FF, 0x180, reason: '0600');
      }
    });

    test('a declined prompt throws and is not remembered', () async {
      touch('.mcp.json');

      await expectLater(
        trustedRepos(answer: false)
            .ensureTrusted(repo.path, agentId: 'claude-acp'),
        throwsA(
          isA<AcpRepoNotTrustedException>().having(
            (error) => error.message,
            'message',
            contains('gw acp trust ${repo.path}'),
          ),
        ),
      );
      expect(trustedRepos().isTrusted(repo.path), isFalse);
    });

    test('fails closed without a terminal and explains gw acp trust', () async {
      touch('.gemini/settings.json');

      await expectLater(
        AcpTrustedRepos(
          file: trustFile,
          prompter: AcpConsentPrompter(
            isInteractive: () => false,
            confirm: (_) => fail('must not prompt without a terminal'),
          ),
        ).ensureTrusted(repo.path, agentId: 'gemini'),
        throwsA(
          isA<AcpRepoNotTrustedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('.gemini/'),
              contains('interactive terminal'),
              contains('gw acp trust ${repo.path}'),
            ),
          ),
        ),
      );
      expect(trustFile.existsSync(), isFalse);
    });

    test('a corrupt trust file trusts nothing', () async {
      touch('.cursor', directory: true);
      trustFile
        ..createSync(recursive: true)
        ..writeAsStringSync('{"trusted": {"${repo.path}": ');

      await expectLater(
        trustedRepos(interactive: false)
            .ensureTrusted(repo.path, agentId: 'cursor'),
        throwsA(isA<AcpRepoNotTrustedException>()),
      );
    });

    test('untrust removes a trusted repository', () async {
      final trusted = trustedRepos();
      await trusted.trust(repo.path);

      expect(await trusted.untrust(repo.path), isTrue);
      expect(await trusted.untrust(repo.path), isFalse);
      expect(trustedRepos().isTrusted(repo.path), isFalse);
    });
  });
}

class _RecordingLogger extends Logger {
  _RecordingLogger(this.lines) : super(level: Level.quiet);

  final List<String> lines;

  @override
  void info(String? message, {LogStyle? style}) => lines.add(message ?? '');
}

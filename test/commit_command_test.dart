import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/commands/commit_command.dart';
import 'package:gitwhisper/src/models/commit_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('commit --dry-run', () {
    late Directory repo;
    late Directory previousCwd;

    setUp(() async {
      previousCwd = Directory.current;
      repo = await Directory.systemTemp.createTemp('gw_commit_test');
      await _git(['init'], repo.path);
      await _git(['config', 'user.email', 'test@test.com'], repo.path);
      await _git(['config', 'user.name', 'Test'], repo.path);
      await _git(['commit', '--allow-empty', '-m', 'initial'], repo.path);
      File(p.join(repo.path, 'calc.py'))
          .writeAsStringSync('def add(a, b):\n    return a + b\n');
      await _git(['add', 'calc.py'], repo.path);
      Directory.current = repo;
    });

    tearDown(() async {
      Directory.current = previousCwd;
      await repo.delete(recursive: true);
    });

    test('generates the message but does not create a commit', () async {
      final fake = _FakeGenerator('feat: add calculator helpers');
      final before = await _commitCount(repo);

      final exit = await _runCommit(['--model', 'codex', '--dry-run'], fake);

      expect(exit, ExitCode.success.code);
      expect(fake.calls, 1, reason: 'commit message should still be generated');
      expect(await _commitCount(repo), before, reason: 'no commit expected');
      expect(await _stagedFiles(repo), 'calc.py',
          reason: 'staged changes should be left intact');
    });

    test('skips the confirm prompt under --dry-run', () async {
      // --confirm would normally block on an interactive prompt; --dry-run must
      // bypass it entirely. The test would hang here if it did not.
      final fake = _FakeGenerator('feat: add calculator helpers');

      final exit = await _runCommit(
        ['--model', 'codex', '--dry-run', '--confirm'],
        fake,
      );

      expect(exit, ExitCode.success.code);
      expect(await _stagedFiles(repo), 'calc.py');
    });

    test('creates a commit when --dry-run is not passed', () async {
      final fake = _FakeGenerator('feat: add calculator helpers');
      final before = await _commitCount(repo);

      final exit = await _runCommit(['--model', 'codex', '--no-confirm'], fake);

      expect(exit, ExitCode.success.code);
      expect(await _commitCount(repo), before + 1, reason: 'commit expected');
      expect(await _stagedFiles(repo), isEmpty);
      final subject = await _git(['log', '-1', '--pretty=%s'], repo.path);
      expect((subject.stdout as String).trim(), 'feat: add calculator helpers');
    });
  });
}

Future<int> _runCommit(List<String> args, CommitGenerator fake) async {
  final runner = CommandRunner<int>('gitwhisper', 'test')
    ..addCommand(
      CommitCommand(
        logger: Logger(level: Level.quiet),
        generatorBuilder: (model, apiKey, {variant, baseUrl}) => fake,
      ),
    );
  return await runner.run(['commit', ...args]) ?? 0;
}

Future<ProcessResult> _git(List<String> args, String dir) =>
    Process.run('git', args, workingDirectory: dir);

Future<int> _commitCount(Directory repo) async {
  final result = await _git(['rev-list', '--count', 'HEAD'], repo.path);
  return int.parse((result.stdout as String).trim());
}

Future<String> _stagedFiles(Directory repo) async {
  final result = await _git(['diff', '--cached', '--name-only'], repo.path);
  return (result.stdout as String).trim();
}

/// Fake generator that returns a canned conventional commit message without
/// touching any provider or network. Implements [AgentCommitGenerator] because
/// the commit command runs in agent mode by default.
class _FakeGenerator extends CommitGenerator implements AgentCommitGenerator {
  _FakeGenerator(this._message) : super(null);

  final String _message;
  int calls = 0;

  @override
  String get modelName => 'fake';

  @override
  String get defaultVariant => '';

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) async {
    calls++;
    return _message;
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async =>
      _message;

  @override
  Future<String> generateAgentCommitMessage(AgentCommitRequest request) async {
    calls++;
    return _message;
  }
}

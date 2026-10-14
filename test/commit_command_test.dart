import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/commands/commit_command.dart';
import 'package:gitwhisper/src/config_manager.dart';
import 'package:gitwhisper/src/models/commit_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// These tests run real git commands, so every repository lives in a temp
// sandbox with its own identity, signing disabled, and an empty hooks
// directory. The command is pointed at the sandbox through its
// workingDirectory and configManager parameters: tests never change
// Directory.current (which is process-wide while suites run concurrently) and
// never read or write the developer's ~/.git_whisper.yaml.
void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('gw_commit_test_');
  });

  tearDown(() async {
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  group('commit --dry-run', () {
    late Directory repo;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      File(p.join(repo.path, 'calc.py'))
          .writeAsStringSync('def add(a, b):\n    return a + b\n');
      await _gitOk(['add', 'calc.py'], repo.path);
    });

    test('generates the message but does not create a commit', () async {
      final fake = _FakeGenerator('feat: add calculator helpers');
      final before = await _commitCount(repo);

      final exit = await _runCommit(
        ['--model', 'codex', '--dry-run'],
        fake,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(fake.calls, 1, reason: 'commit message should still be generated');
      expect(await _commitCount(repo), before, reason: 'no commit expected');
      expect(
        await _stagedFiles(repo),
        'calc.py',
        reason: 'staged changes should be left intact',
      );
    });

    test('skips the confirm prompt under --dry-run', () async {
      // --confirm would normally prompt; the scripted logger has no answers,
      // so the test fails loudly if --dry-run does not bypass the prompt.
      final fake = _FakeGenerator('feat: add calculator helpers');

      final exit = await _runCommit(
        ['--model', 'codex', '--dry-run', '--confirm'],
        fake,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(await _stagedFiles(repo), 'calc.py');
    });

    test('creates a commit when --dry-run is not passed', () async {
      final fake = _FakeGenerator('feat: add calculator helpers');
      final before = await _commitCount(repo);

      final exit = await _runCommit(
        ['--model', 'codex', '--no-confirm'],
        fake,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(await _commitCount(repo), before + 1, reason: 'commit expected');
      expect(await _stagedFiles(repo), isEmpty);
      expect(await _lastSubject(repo), 'feat: add calculator helpers');
    });
  });

  group('commit test isolation', () {
    test('commits in the injected directory without changing the cwd',
        () async {
      final repo = await _createRepo(sandbox, 'repo');
      File(p.join(repo.path, 'a.txt')).writeAsStringSync('a\n');
      await _gitOk(['add', 'a.txt'], repo.path);
      final cwdBefore = Directory.current.path;

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(Directory.current.path, cwdBefore);
      expect(await _lastSubject(repo), 'feat: Add a');
    });

    test('reads settings from the injected config manager', () async {
      final repo = await _createRepo(sandbox, 'repo');
      File(p.join(repo.path, 'a.txt')).writeAsStringSync('a\n');
      await _gitOk(['add', 'a.txt'], repo.path);
      final logger = _ScriptedLogger(answers: ['commit']);

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
        logger: logger,
        config: _TestConfigManager(confirmCommits: true),
      );

      expect(exit, ExitCode.success.code);
      expect(
        logger.prompts,
        contains('What would you like to do with this commit message?'),
        reason: 'confirm_commits from the injected config should apply',
      );
    });
  });

  group('commit model selection', () {
    late Directory repo;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
    });

    Future<List<String>> buildFor(
      List<String> args, {
      (String, String?)? defaults,
    }) async {
      final built = <String>[];
      await _runCommit(
        [...args, '--dry-run'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
        config: _TestConfigManager(defaults: defaults),
        builtModels: built,
      );
      return built;
    }

    test('--model-variant applies to the configured default model', () async {
      expect(
        await buildFor(
          ['--model-variant', 'opus-x'],
          defaults: ('claude', 'sonnet-y'),
        ),
        ['claude:opus-x'],
      );
    });

    test('the configured default variant applies when none is passed',
        () async {
      expect(
        await buildFor([], defaults: ('claude', 'sonnet-y')),
        ['claude:sonnet-y'],
      );
    });

    test('an empty --model-variant counts as not passed', () async {
      expect(
        await buildFor(
          ['--model-variant', ''],
          defaults: ('claude', 'sonnet-y'),
        ),
        ['claude:sonnet-y'],
      );
    });

    test('--model-variant applies without --model or configured defaults',
        () async {
      expect(await buildFor(['--model-variant', 'gpt-x']), ['openai:gpt-x']);
    });
  });

  group('commit cancellation exit codes', () {
    final cancelled = CommitCommand.cancelledExitCode.code;

    test('uses tempFail rather than success or usage', () {
      expect(cancelled, ExitCode.tempFail.code);
      expect(cancelled, isNot(ExitCode.success.code));
      expect(cancelled, isNot(ExitCode.usage.code));
    });

    test('discarding the message exits with the cancelled code', () async {
      final repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
      final before = await _commitCount(repo);

      final exit = await _runCommit(
        ['--model', 'codex', '--confirm'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
        logger: _ScriptedLogger(answers: ['discard']),
      );

      expect(exit, cancelled);
      expect(await _commitCount(repo), before);
    });

    test('cancelling at the large-file prompt exits with the cancelled code',
        () async {
      final repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'big.bin', 'x' * 64);
      final before = await _commitCount(repo);

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add big file'),
        workingDirectory: repo.path,
        logger: _ScriptedLogger(answers: ['Cancel commit']),
        config: _TestConfigManager(maxFileSize: 16),
      );

      expect(exit, cancelled);
      expect(await _commitCount(repo), before);
    });

    test('nothing left staged after large-file handling is a cancel', () async {
      final repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'big.bin', 'x' * 64);
      final fake = _FakeGenerator('feat: Add big file');

      final exit = await _runCommit(
        ['--model', 'codex'],
        fake,
        workingDirectory: repo.path,
        logger: _ScriptedLogger(answers: ['Add to .gitignore and unstage']),
        config: _TestConfigManager(maxFileSize: 16),
      );

      expect(exit, cancelled);
      expect(fake.calls, 0, reason: 'nothing should be sent to the model');
      expect(await _stagedFiles(repo), isEmpty);
    });

    test('declining to stage unstaged changes exits with the cancelled code',
        () async {
      final repo = await _createRepo(sandbox, 'repo');
      File(p.join(repo.path, 'a.txt')).writeAsStringSync('a\n');

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
        logger: _ScriptedLogger(answers: ['no']),
      );

      expect(exit, cancelled);
      expect(await _stagedFiles(repo), isEmpty);
    });

    test('aborting the subfolder prompt exits with the cancelled code',
        () async {
      final workspace = Directory(p.join(sandbox.path, 'workspace'))
        ..createSync();
      final repo = await _createRepo(workspace, 'one');
      await _stageFile(repo, 'a.txt', 'a\n');

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: workspace.path,
        logger: _ScriptedLogger(answers: ['abort']),
      );

      expect(exit, cancelled);
    });

    test('a discarded repo in multi-repo mode is cancelled, not failed',
        () async {
      final workspace = Directory(p.join(sandbox.path, 'workspace'))
        ..createSync();
      final one = await _createRepo(workspace, 'one');
      final two = await _createRepo(workspace, 'two');
      await _stageFile(one, 'a.txt', 'a\n');
      await _stageFile(two, 'b.txt', 'b\n');
      final logger = _ScriptedLogger(
        answers: ['continue', 'commit', 'discard'],
      );

      final exit = await _runCommit(
        ['--model', 'codex', '--confirm'],
        _FakeGenerator('feat: Add file'),
        workingDirectory: workspace.path,
        logger: logger,
      );

      expect(exit, cancelled);
      expect(logger.errors.where((e) => e.startsWith('Failed in')), isEmpty);
      expect(
        logger.warnings.where((w) => w.startsWith('Cancelled in: ')),
        hasLength(1),
      );
      final counts = [await _commitCount(one), await _commitCount(two)]..sort();
      expect(counts, [1, 2], reason: 'exactly one repo should be committed');
    });
  });
}

Future<int> _runCommit(
  List<String> args,
  CommitGenerator generator, {
  required String workingDirectory,
  Logger? logger,
  ConfigManager? config,
  List<String>? builtModels,
}) async {
  final runner = CommandRunner<int>('gitwhisper', 'test')
    ..addCommand(
      CommitCommand(
        logger: logger ?? _ScriptedLogger(),
        generatorBuilder: (model, apiKey, {variant, baseUrl}) {
          final hasVariant = variant != null && variant.isNotEmpty;
          builtModels?.add(hasVariant ? '$model:$variant' : model);
          return generator;
        },
        configManager: config ?? _TestConfigManager(),
        workingDirectory: workingDirectory,
      ),
    );
  return await runner.run(['commit', ...args]) ?? 0;
}

/// Creates a git repository at [parent]/[name] that is isolated from the
/// developer's global git configuration: no templates, no hooks, no signing,
/// and a local identity.
Future<Directory> _createRepo(
  Directory parent,
  String name, {
  bool initialCommit = true,
}) async {
  final repo = Directory(p.join(parent.path, name))
    ..createSync(recursive: true);
  final empty = Directory(p.join(parent.path, '.empty-$name'))
    ..createSync(recursive: true);

  await _gitOk(['init', '-q', '--template=${empty.path}'], repo.path);
  await _gitOk(['symbolic-ref', 'HEAD', 'refs/heads/main'], repo.path);
  const settings = <String, String>{
    'user.name': 'GitWhisper Test',
    'user.email': 'test@example.com',
    'commit.gpgsign': 'false',
    'tag.gpgsign': 'false',
    'push.gpgsign': 'false',
    'push.default': 'simple',
  };
  for (final entry in settings.entries) {
    await _gitOk(['config', entry.key, entry.value], repo.path);
  }
  await _gitOk(['config', 'core.hooksPath', empty.path], repo.path);

  if (initialCommit) {
    await _gitOk(['commit', '--allow-empty', '-q', '-m', 'initial'], repo.path);
  }
  return repo;
}

Future<ProcessResult> _git(List<String> args, String dir) =>
    Process.run('git', args, workingDirectory: dir);

Future<String> _gitOk(List<String> args, String dir) async {
  final result = await _git(args, dir);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

Future<void> _stageFile(Directory repo, String name, String content) async {
  final file = File(p.join(repo.path, name));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  await _gitOk(['add', '--', name], repo.path);
}

Future<int> _commitCount(Directory repo) async {
  final count = await _gitOk(['rev-list', '--count', 'HEAD'], repo.path);
  return int.parse(count);
}

Future<String> _stagedFiles(Directory repo) =>
    _gitOk(['diff', '--cached', '--name-only'], repo.path);

Future<String> _lastSubject(Directory repo) =>
    _gitOk(['log', '-1', '--pretty=%s'], repo.path);

/// In-memory config so tests never read or write ~/.git_whisper.yaml.
class _TestConfigManager extends ConfigManager {
  _TestConfigManager({
    bool alwaysAdd = false,
    bool confirmCommits = false,
    int? maxDiffSize,
    int? maxFileSize,
    (String, String?)? defaults,
  }) {
    setAlwaysAdd(value: alwaysAdd);
    setConfirmCommits(value: confirmCommits);
    if (maxDiffSize != null) setMaxDiffSize(maxDiffSize);
    if (maxFileSize != null) setMaxFileSize(maxFileSize);
    if (defaults != null) setDefaults(defaults.$1, defaults.$2);
  }

  @override
  Future<void> load() async {}

  @override
  Future<void> save() async {
    throw StateError('Tests must not write the user config file.');
  }

  /// A dummy key for every provider, so the command never falls back to the
  /// developer's *_API_KEY environment variables. Fake generators ignore it.
  @override
  String? getApiKey(String model) => 'test-api-key';
}

/// Logger that records output and answers prompts from a script, so tests can
/// drive interactive flows without a terminal. Running out of answers throws
/// instead of blocking on stdin.
class _ScriptedLogger extends Logger {
  _ScriptedLogger({List<String> answers = const []})
      : _answers = [...answers],
        super(level: Level.quiet);

  final List<String> _answers;
  final List<String?> prompts = [];
  final List<String> infos = [];
  final List<String> warnings = [];
  final List<String> errors = [];
  final List<String> successes = [];

  String _next(String? message) {
    prompts.add(message);
    if (_answers.isEmpty) {
      throw StateError('Unexpected prompt: $message');
    }
    return _answers.removeAt(0);
  }

  @override
  void info(String? message, {LogStyle? style}) => infos.add('$message');

  @override
  void warn(String? message, {String tag = 'WARN', LogStyle? style}) =>
      warnings.add('$message');

  @override
  void err(String? message, {LogStyle? style}) => errors.add('$message');

  @override
  void success(String? message, {LogStyle? style}) => successes.add('$message');

  @override
  T chooseOne<T extends Object?>(
    String? message, {
    required List<T> choices,
    T? defaultValue,
    String Function(T choice)? display,
  }) {
    final answer = _next(message);
    return choices.firstWhere(
      (choice) => '$choice' == answer,
      orElse: () => throw StateError('"$answer" is not one of $choices'),
    );
  }

  @override
  String prompt(String? message, {Object? defaultValue, bool hidden = false}) =>
      _next(message);

  @override
  bool confirm(String? message, {bool defaultValue = false}) =>
      _next(message) == 'yes';
}

/// Fake generator that returns canned messages without touching any provider
/// or network. Implements [AgentCommitGenerator] because the commit command
/// runs in agent mode by default.
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

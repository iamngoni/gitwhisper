import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/commands/commit_command.dart';
import 'package:gitwhisper/src/config_manager.dart';
import 'package:gitwhisper/src/constants.dart';
import 'package:gitwhisper/src/exceptions/exceptions.dart';
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

  group('commit --key', () {
    late Directory repo;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
    });

    test('still works but warns about shell history', () async {
      final logger = _ScriptedLogger();
      String? usedKey;

      final runner = CommandRunner<int>('gitwhisper', 'test')
        ..addCommand(
          CommitCommand(
            logger: logger,
            generatorBuilder: (model, apiKey, {variant, baseUrl}) {
              usedKey = apiKey;
              return _FakeGenerator('feat: Add a');
            },
            configManager: _TestConfigManager(),
            workingDirectory: repo.path,
          ),
        );
      final exit = await runner.run(
        ['commit', '--model', 'openai', '--key', 'sk-cli', '--dry-run'],
      );

      expect(exit, ExitCode.success.code);
      expect(usedKey, 'sk-cli');
      expect(
        logger.warnings,
        contains(
          allOf(contains('shell history'), contains('gw save-key')),
        ),
      );
    });

    test('does not warn when the key comes from config', () async {
      final logger = _ScriptedLogger();

      await _runCommit(
        ['--model', 'openai', '--dry-run'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
        logger: logger,
      );

      expect(logger.warnings.where((w) => w.contains('--key')), isEmpty);
    });
  });

  group('commit API errors', () {
    setUpAll(() {
      // Initialize the global logger outside the capture zone so it resolves
      // stdout per write instead of pinning the first zone's overrides.
      expect($logger.level, isNotNull);
    });

    test('prints a server error once, then the model-switch suggestions',
        () async {
      final repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
      final logger = _ScriptedLogger();

      final (exit, output) = await _captureOutput(
        () => _runCommit(
          ['--model', 'codex'],
          _FakeGenerator(
            'unused',
            agentError: const ServerException(
              message: 'upstream exploded',
              statusCode: 503,
            ),
          ),
          workingDirectory: repo.path,
          logger: logger,
        ),
      );

      expect(exit, ExitCode.software.code);
      expect('API Error:'.allMatches(output), hasLength(1), reason: output);
      expect(
        'upstream exploded'.allMatches(output).length,
        lessThanOrEqualTo(2),
        reason: 'the raw error and its friendly message, each once',
      );
      expect(logger.infos, contains('You can try these alternatives:'));
    });
  });

  group('commit --prefix', () {
    test('keeps a non-JIRA prefix on the committed message', () async {
      final repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');

      final exit = await _runCommit(
        ['--model', 'codex', '--prefix', '#42'],
        _FakeGenerator('Feat: Add dark mode'),
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(await _lastSubject(repo), '#42 -> feat: Add dark mode');
    });
  });

  group('commit confirm edit', () {
    late Directory repo;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
    });

    Future<(int, _ScriptedLogger)> runEdit(CommitMessageEditor editor) async {
      final logger = _ScriptedLogger(answers: ['edit', 'commit']);
      final exit = await _runCommit(
        ['--model', 'codex', '--confirm'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
        logger: logger,
        messageEditor: editor,
      );
      return (exit, logger);
    }

    test('commits the edited message, editing in the repository', () async {
      String? editedIn;
      final (exit, _) = await runEdit((message, {folderPath}) async {
        editedIn = folderPath;
        return 'feat: Edited by hand';
      });

      expect(exit, ExitCode.success.code);
      expect(editedIn, repo.path);
      expect(await _lastSubject(repo), 'feat: Edited by hand');
    });

    test('keeps the message when the editor cannot be started', () async {
      final (exit, logger) = await runEdit((message, {folderPath}) async {
        throw const ProcessException('/bin/sh', [], 'not found', 2);
      });

      expect(exit, ExitCode.success.code);
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(logger.errors, contains(startsWith('Could not open the editor')));
    });

    test('keeps the message when the editor returns nothing', () async {
      final (exit, logger) = await runEdit(
        (message, {folderPath}) async => null,
      );

      expect(exit, ExitCode.success.code);
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(logger.warnings, isNotEmpty);
    });
  });

  group('commit with unresolved merge conflicts', () {
    test('stops before staging or calling the model', () async {
      final repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'sub/keep.txt', 'keep\n');
      await _createMergeConflict(repo, 'conflict.txt');
      File(p.join(repo.path, 'other.txt')).writeAsStringSync('other\n');
      final fake = _FakeGenerator('feat: Add a');
      final logger = _ScriptedLogger();

      // Run from a subdirectory: the conflict at the root must still count.
      final exit = await _runCommit(
        ['--model', 'codex'],
        fake,
        workingDirectory: p.join(repo.path, 'sub'),
        logger: logger,
        config: _TestConfigManager(alwaysAdd: true),
      );

      expect(exit, ExitCode.usage.code);
      expect(fake.calls, 0);
      expect(logger.errors.first, contains('conflict.txt'));
      expect(
        await _gitOk(['ls-files', '-u'], repo.path),
        isNotEmpty,
        reason: 'the conflicted file must not be staged as resolved',
      );
    });

    test('skips only the conflicted repo in multi-repo mode', () async {
      final workspace = Directory(p.join(sandbox.path, 'workspace'))
        ..createSync();
      final conflicted = await _createRepo(workspace, 'conflicted');
      final clean = await _createRepo(workspace, 'clean');
      await _createMergeConflict(conflicted, 'conflict.txt');
      await _stageFile(clean, 'a.txt', 'a\n');
      final logger = _ScriptedLogger(answers: ['continue']);

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: workspace.path,
        logger: logger,
      );

      expect(exit, ExitCode.software.code);
      expect(await _lastSubject(clean), 'feat: Add a');
      expect(logger.errors, contains('Failed in: conflicted'));
    });
  });

  group('commit always_add', () {
    test('stages a repo whose only changes are untracked files', () async {
      final repo = await _createRepo(sandbox, 'repo');
      File(p.join(repo.path, 'new.txt')).writeAsStringSync('new\n');

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add new file'),
        workingDirectory: repo.path,
        config: _TestConfigManager(alwaysAdd: true),
      );

      expect(exit, ExitCode.success.code);
      expect(await _lastSubject(repo), 'feat: Add new file');
      expect(
        await _gitOk(['show', '--name-only', '--pretty=', 'HEAD'], repo.path),
        'new.txt',
      );
    });

    test('stages untracked-only repos in multi-repo mode', () async {
      final workspace = Directory(p.join(sandbox.path, 'workspace'))
        ..createSync();
      final repo = await _createRepo(workspace, 'one');
      File(p.join(repo.path, 'new.txt')).writeAsStringSync('new\n');

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add new file'),
        workingDirectory: workspace.path,
        logger: _ScriptedLogger(answers: ['continue']),
        config: _TestConfigManager(alwaysAdd: true),
      );

      expect(exit, ExitCode.success.code);
      expect(await _lastSubject(repo), 'feat: Add new file');
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
  CommitMessageEditor? messageEditor,
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
        // Never launch a real editor from tests.
        messageEditor: messageEditor ??
            (message, {folderPath}) =>
                throw StateError('Unexpected editor launch'),
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

/// Leaves [repo] mid-merge with [file] conflicted.
Future<void> _createMergeConflict(Directory repo, String file) async {
  await _stageFile(repo, file, 'base\n');
  await _gitOk(['commit', '-q', '-m', 'base'], repo.path);
  await _gitOk(['checkout', '-q', '-b', 'other'], repo.path);
  await _stageFile(repo, file, 'theirs\n');
  await _gitOk(['commit', '-q', '-m', 'theirs'], repo.path);
  await _gitOk(['checkout', '-q', 'main'], repo.path);
  await _stageFile(repo, file, 'ours\n');
  await _gitOk(['commit', '-q', '-m', 'ours'], repo.path);
  final merge = await _git(['merge', 'other'], repo.path);
  expect(merge.exitCode, isNot(0), reason: 'the merge should conflict');
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

/// Captures what a logger writes to stdout/stderr inside
/// [IOOverrides.runZoned].
class _CapturedStdout implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs [body] and returns its result with everything written to stdout and
/// stderr, including output from the global `$logger` used by ErrorHandler.
Future<(int, String)> _captureOutput(Future<int> Function() body) async {
  final out = _CapturedStdout();
  final code = await IOOverrides.runZoned(
    body,
    stdout: () => out,
    stderr: () => out,
  );
  return (code, out.buffer.toString());
}

/// Fake generator that returns canned messages without touching any provider
/// or network. Implements [AgentCommitGenerator] because the commit command
/// runs in agent mode by default.
///
/// `responses` are returned in order and the last one repeats. [agentError] is
/// thrown from agent mode only, to simulate providers that reject tool use.
class _FakeGenerator extends CommitGenerator implements AgentCommitGenerator {
  _FakeGenerator(
    String message, {
    List<String>? responses,
    this.agentError,
  })  : _responses = responses ?? [message],
        super(null);

  final List<String> _responses;
  final Exception? agentError;
  int calls = 0;
  final List<AgentCommitRequest> agentRequests = [];
  final List<String> directInputs = [];

  String _nextResponse() =>
      _responses.length > 1 ? _responses.removeAt(0) : _responses.first;

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
    directInputs.add(diff);
    return _nextResponse();
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async =>
      _nextResponse();

  @override
  Future<String> generateAgentCommitMessage(AgentCommitRequest request) async {
    calls++;
    agentRequests.add(request);
    final error = agentError;
    if (error != null) throw error;
    return _nextResponse();
  }
}

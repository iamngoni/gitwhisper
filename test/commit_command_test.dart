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
      expect(_canonical(editedIn!), _canonical(repo.path));
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

  group('commit confirm retry', () {
    late Directory repo;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
    });

    test('keeps the previous message when a retry returns nothing usable',
        () async {
      // The sanitizer turns the prose answer into an empty message.
      final fake = _FakeGenerator(
        'unused',
        responses: ['feat: Add a', 'I could not decide.'],
      );
      final logger = _ScriptedLogger(
        answers: ['retry', 'same model', 'commit'],
      );

      final exit = await _runCommit(
        ['--model', 'codex', '--confirm'],
        fake,
        workingDirectory: repo.path,
        logger: logger,
      );

      expect(exit, ExitCode.success.code);
      expect(fake.agentRequests, hasLength(2));
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(
        logger.warnings,
        contains(contains('Keeping the previous one')),
      );
    });

    test('sends added context to the agent and keeps it for later retries',
        () async {
      final fake = _FakeGenerator(
        'unused',
        responses: ['feat: Add a', 'feat: Add the a file', 'feat: Add file a'],
      );
      final logger = _ScriptedLogger(
        answers: [
          'retry',
          'add context',
          '  mention the a file  ',
          'retry',
          'same model',
          'commit',
        ],
      );

      final exit = await _runCommit(
        ['--model', 'codex', '--confirm'],
        fake,
        workingDirectory: repo.path,
        logger: logger,
      );

      expect(exit, ExitCode.success.code);
      expect(
        fake.agentRequests.map((request) => request.additionalContext),
        [null, 'mention the a file', 'mention the a file'],
      );
      expect(await _lastSubject(repo), 'feat: Add file a');
    });

    test('regenerates without context when none is entered', () async {
      final fake = _FakeGenerator(
        'unused',
        responses: ['feat: Add a', 'feat: Add the a file'],
      );
      final logger = _ScriptedLogger(
        answers: ['retry', 'add context', '   ', 'commit'],
      );

      final exit = await _runCommit(
        ['--model', 'codex', '--confirm'],
        fake,
        workingDirectory: repo.path,
        logger: logger,
      );

      expect(exit, ExitCode.success.code);
      expect(
        fake.agentRequests.map((request) => request.additionalContext),
        [null, null],
      );
      expect(logger.warnings, contains(startsWith('No context provided')));
      expect(await _lastSubject(repo), 'feat: Add the a file');
    });

    test('--no-agent puts added context in the prompt', () async {
      final fake = _FakeGenerator(
        'unused',
        responses: ['feat: Add a', 'feat: Add the a file'],
      );
      final logger = _ScriptedLogger(
        answers: ['retry', 'add context', 'mention the a file', 'commit'],
      );

      final exit = await _runCommit(
        ['--model', 'codex', '--no-agent', '--confirm'],
        fake,
        workingDirectory: repo.path,
        logger: logger,
      );

      expect(exit, ExitCode.success.code);
      expect(fake.directInputs, hasLength(2));
      expect(fake.directInputs[0], isNot(contains('ADDITIONAL CONTEXT')));
      expect(
        fake.directInputs[1],
        allOf(
          contains('diff --git a/a.txt b/a.txt'),
          contains('ADDITIONAL CONTEXT FROM THE USER'),
          contains('mention the a file'),
        ),
      );
      expect(await _lastSubject(repo), 'feat: Add the a file');
    });

    test('--no-agent puts added context in the file-by-file prompt', () async {
      await _stageFile(repo, 'b.txt', 'b\n');
      final fake = _FakeGenerator(
        'unused',
        responses: [
          'Adds a',
          'Adds b',
          'feat: Add two files',
          'Adds a',
          'Adds b',
          'feat: Add files a and b',
        ],
      );
      final logger = _ScriptedLogger(
        answers: ['retry', 'add context', 'mention both files', 'commit'],
      );

      final exit = await _runCommit(
        ['--model', 'codex', '--no-agent', '--confirm'],
        fake,
        workingDirectory: repo.path,
        logger: logger,
        config: _TestConfigManager(maxDiffSize: 10),
      );

      expect(exit, ExitCode.success.code);
      expect(fake.directInputs, hasLength(6));
      expect(fake.directInputs[2], isNot(contains('ADDITIONAL CONTEXT')));
      expect(
        fake.directInputs[5],
        allOf(
          contains('- a.txt: Adds a'),
          contains('ADDITIONAL CONTEXT FROM THE USER'),
          contains('mention both files'),
        ),
      );
      expect(await _lastSubject(repo), 'feat: Add files a and b');
    });
  });

  // Pushes only ever go to bare repositories inside the temp sandbox.
  group('commit --auto-push', () {
    late Directory repo;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
    });

    Future<(int, _ScriptedLogger)> commitAndPush([
      List<String> extraArgs = const [],
      String? workingDirectory,
    ]) async {
      final logger = _ScriptedLogger();
      final exit = await _runCommit(
        ['--model', 'codex', '--auto-push', ...extraArgs],
        _FakeGenerator('feat: Add a'),
        workingDirectory: workingDirectory ?? repo.path,
        logger: logger,
      );
      return (exit, logger);
    }

    test('pushes to the only remote and sets it as the upstream', () async {
      final origin = await _createBareRemote(sandbox, 'origin');
      await _gitOk(['remote', 'add', 'origin', origin.path], repo.path);

      final (exit, logger) = await commitAndPush();

      expect(exit, ExitCode.success.code);
      expect(await _ref(origin, 'refs/heads/main'), await _ref(repo, 'HEAD'));
      expect(
        await _gitOk(['rev-parse', '--abbrev-ref', '@{upstream}'], repo.path),
        'origin/main',
      );
      expect(
        logger.successes,
        contains('Pushed to origin/main successfully! 🎉'),
      );
    });

    test('pushes to the configured upstream when there are several remotes',
        () async {
      final origin = await _createBareRemote(sandbox, 'origin');
      final upstream = await _createBareRemote(sandbox, 'upstream');
      await _gitOk(['remote', 'add', 'origin', origin.path], repo.path);
      await _gitOk(['remote', 'add', 'upstream', upstream.path], repo.path);
      await _gitOk(['push', '-q', '-u', 'upstream', 'main'], repo.path);

      final (exit, _) = await commitAndPush();

      expect(exit, ExitCode.success.code);
      expect(await _ref(upstream, 'refs/heads/main'), await _ref(repo, 'HEAD'));
      expect(await _ref(origin, 'refs/heads/main'), isNull);
    });

    test('explains several remotes without an upstream, keeping the commit',
        () async {
      final origin = await _createBareRemote(sandbox, 'origin');
      final upstream = await _createBareRemote(sandbox, 'upstream');
      await _gitOk(['remote', 'add', 'origin', origin.path], repo.path);
      await _gitOk(['remote', 'add', 'upstream', upstream.path], repo.path);

      final (exit, logger) = await commitAndPush();

      expect(exit, ExitCode.software.code);
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(logger.successes, contains('Commit successful! 🎉'));
      expect(
        logger.errors.single,
        allOf(
          contains('The commit was created, but pushing failed'),
          contains('origin, upstream'),
          contains('git push -u <remote> main'),
        ),
      );
      expect(await _ref(origin, 'refs/heads/main'), isNull);
      expect(await _ref(upstream, 'refs/heads/main'), isNull);
    });

    test('explains a missing remote, keeping the commit', () async {
      final (exit, logger) = await commitAndPush();

      expect(exit, ExitCode.software.code);
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(logger.errors.single, contains('git remote add origin'));
    });

    test('explains a detached HEAD, keeping the commit', () async {
      final origin = await _createBareRemote(sandbox, 'origin');
      await _gitOk(['remote', 'add', 'origin', origin.path], repo.path);
      await _gitOk(['checkout', '-q', '--detach'], repo.path);

      final (exit, logger) = await commitAndPush();

      expect(exit, ExitCode.software.code);
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(logger.errors.single, contains('HEAD is detached'));
      expect(await _ref(origin, 'refs/heads/main'), isNull);
    });

    test('pushes the tag to the same remote', () async {
      final origin = await _createBareRemote(sandbox, 'origin');
      await _gitOk(['remote', 'add', 'origin', origin.path], repo.path);

      final (exit, _) = await commitAndPush(['--tag', 'v1.2.3']);

      expect(exit, ExitCode.success.code);
      expect(await _ref(origin, 'refs/tags/v1.2.3'), await _ref(repo, 'HEAD'));
    });

    test('reports a tag failure without pushing, keeping the commit', () async {
      final origin = await _createBareRemote(sandbox, 'origin');
      await _gitOk(['remote', 'add', 'origin', origin.path], repo.path);
      await _gitOk(['tag', 'v1.2.3'], repo.path);

      final (exit, logger) = await commitAndPush(['--tag', 'v1.2.3']);

      expect(exit, ExitCode.software.code);
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(
        logger.errors.single,
        allOf(contains('tagging it failed'), contains('Nothing was pushed')),
      );
      expect(await _ref(origin, 'refs/heads/main'), isNull);
    });

    test('runs git remote in each repository in multi-repo mode', () async {
      final workspace = Directory(p.join(sandbox.path, 'workspace'))
        ..createSync();
      final one = await _createRepo(workspace, 'one');
      await _stageFile(one, 'a.txt', 'a\n');
      // Not called "origin", so a lookup in the wrong directory cannot pass.
      final backup = await _createBareRemote(sandbox, 'backup');
      await _gitOk(['remote', 'add', 'backup', backup.path], one.path);
      final logger = _ScriptedLogger(answers: ['continue']);

      final exit = await _runCommit(
        ['--model', 'codex', '--auto-push'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: workspace.path,
        logger: logger,
      );

      expect(exit, ExitCode.success.code);
      expect(await _ref(backup, 'refs/heads/main'), await _ref(one, 'HEAD'));
      expect(
        logger.successes,
        contains('[one] Pushed to backup/main successfully! 🎉'),
      );
    });
  });

  group('commit from a subdirectory', () {
    late Directory repo;
    late String subdirectory;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'root.txt', 'root\n');
      await _stageFile(repo, 'sub/keep.txt', 'keep\n');
      await _gitOk(['commit', '-q', '-m', 'files'], repo.path);
      subdirectory = p.join(repo.path, 'sub');
    });

    test('stages changes outside the subdirectory', () async {
      File(p.join(repo.path, 'root.txt')).writeAsStringSync('changed\n');
      File(p.join(repo.path, 'new.txt')).writeAsStringSync('new\n');

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Update root files'),
        workingDirectory: subdirectory,
        logger: _ScriptedLogger(answers: ['yes']),
      );

      expect(exit, ExitCode.success.code);
      expect(
        await _gitOk(['show', '--name-only', '--pretty=', 'HEAD'], repo.path),
        'new.txt\nroot.txt',
      );
    });

    test('checks large files staged outside the subdirectory', () async {
      await _stageFile(repo, 'big.bin', 'x' * 64);
      final logger = _ScriptedLogger(answers: ['Cancel commit']);

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add big file'),
        workingDirectory: subdirectory,
        logger: logger,
        config: _TestConfigManager(maxFileSize: 16),
      );

      expect(exit, CommitCommand.cancelledExitCode.code);
      expect(logger.warnings.join('\n'), contains('big.bin'));
    });

    test('adds large files to the top-level .gitignore', () async {
      await _stageFile(repo, 'assets/big.bin', 'x' * 64);
      await _stageFile(repo, 'small.txt', 'small\n');

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add small file'),
        workingDirectory: subdirectory,
        logger: _ScriptedLogger(answers: ['Add to .gitignore and unstage']),
        config: _TestConfigManager(maxFileSize: 16),
      );

      expect(exit, ExitCode.success.code);
      expect(
        File(p.join(repo.path, '.gitignore')).readAsStringSync(),
        'assets/big.bin\n',
      );
      expect(File(p.join(subdirectory, '.gitignore')).existsSync(), isFalse);
      expect(
        await _gitOk(['show', '--name-only', '--pretty=', 'HEAD'], repo.path),
        'small.txt',
      );
    });

    test('gives agent tools the repository root', () async {
      final fake = _FakeGenerator('feat: Add a');
      await _stageFile(repo, 'a.txt', 'a\n');

      await _runCommit(
        ['--model', 'codex', '--dry-run'],
        fake,
        workingDirectory: subdirectory,
      );

      final toolsFolder = fake.agentRequests.single.tools.folderPath;
      expect(_canonical(toolsFolder!), _canonical(repo.path));
    });
  });

  group('commit agent mode', () {
    late Directory repo;

    setUp(() async {
      repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'a.txt', 'a\n');
    });

    test('--agent defaults on and is negatable', () {
      final parser = CommitCommand(logger: _ScriptedLogger()).argParser;

      expect(parser.parse([])['agent'], isTrue);
      expect(parser.parse(['--agent'])['agent'], isTrue);
      expect(parser.parse(['--no-agent'])['agent'], isFalse);
    });

    test('is used by default', () async {
      final fake = _FakeGenerator('feat: Add a');

      final exit = await _runCommit(
        ['--model', 'codex'],
        fake,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(fake.agentRequests, hasLength(1));
      expect(fake.directInputs, isEmpty);
    });

    test('--no-agent sends the staged diff instead', () async {
      final fake = _FakeGenerator('feat: Add a');

      final exit = await _runCommit(
        ['--model', 'codex', '--no-agent'],
        fake,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(fake.agentRequests, isEmpty);
      expect(fake.directInputs.single, contains('diff --git a/a.txt b/a.txt'));
      expect(await _lastSubject(repo), 'feat: Add a');
    });

    test('is skipped for generators without agent support', () async {
      final generator = _DirectOnlyGenerator('feat: Add a');

      final exit = await _runCommit(
        ['--model', 'some-agent'],
        generator,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.success.code);
      expect(generator.directInputs, hasLength(1));
    });

    test('--no-agent summarises diffs over max-diff-size file by file',
        () async {
      await _stageFile(repo, 'b.txt', 'b\n');
      final fake = _FakeGenerator(
        'unused',
        responses: ['Adds a', 'Adds b', 'feat: Add two files'],
      );

      final exit = await _runCommit(
        ['--model', 'codex', '--no-agent'],
        fake,
        workingDirectory: repo.path,
        config: _TestConfigManager(maxDiffSize: 10),
      );

      expect(exit, ExitCode.success.code);
      expect(fake.directInputs, hasLength(3));
      expect(fake.directInputs.last, contains('- a.txt: Adds a'));
      expect(await _lastSubject(repo), 'feat: Add two files');
    });

    test('falls back to the staged diff when the model rejects tools',
        () async {
      final fake = _FakeGenerator(
        'feat: Add a',
        agentError: const InvalidRequestException(
          message: 'registry.ollama.ai/library/gemma3:latest does not '
              'support tools',
        ),
      );
      final logger = _ScriptedLogger();

      final exit = await _runCommit(
        ['--model', 'ollama'],
        fake,
        workingDirectory: repo.path,
        logger: logger,
      );

      expect(exit, ExitCode.success.code);
      expect(fake.agentRequests, hasLength(1));
      expect(fake.directInputs, hasLength(1));
      expect(await _lastSubject(repo), 'feat: Add a');
      expect(
        logger.warnings.single,
        allOf(contains('rejected tool use'), contains('does not support')),
      );
    });

    test('stays in direct mode for later repositories after a fallback',
        () async {
      final workspace = Directory(p.join(sandbox.path, 'workspace'))
        ..createSync();
      final one = await _createRepo(workspace, 'one');
      final two = await _createRepo(workspace, 'two');
      await _stageFile(one, 'a.txt', 'a\n');
      await _stageFile(two, 'b.txt', 'b\n');
      final fake = _FakeGenerator(
        'feat: Add file',
        agentError: const InvalidRequestException(
          message: 'Function calling is not enabled for this model',
        ),
      );

      final exit = await _runCommit(
        ['--model', 'gemini'],
        fake,
        workingDirectory: workspace.path,
        logger: _ScriptedLogger(answers: ['continue']),
      );

      expect(exit, ExitCode.success.code);
      expect(fake.agentRequests, hasLength(1));
      expect(fake.directInputs, hasLength(2));
    });

    test('does not fall back for agent-only providers', () async {
      final fake = _FakeGenerator(
        'feat: Add a',
        agentError: const InvalidRequestException(
          message: 'this model does not support tools',
        ),
      );

      final exit = await _runCommit(
        ['--model', 'codex'],
        fake,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.software.code);
      expect(fake.directInputs, isEmpty);
    });

    test('does not fall back for unrelated errors', () async {
      final fake = _FakeGenerator(
        'feat: Add a',
        agentError: const ServerException(
          message: 'upstream exploded',
          statusCode: 503,
        ),
      );

      final exit = await _runCommit(
        ['--model', 'ollama'],
        fake,
        workingDirectory: repo.path,
      );

      expect(exit, ExitCode.software.code);
      expect(fake.directInputs, isEmpty);
    });

    test(
        'the different-model retry offers every provider and uses the '
        'injected builder', () async {
      final built = <String>[];

      final exit = await _runCommit(
        ['--model', 'codex', '--confirm'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: repo.path,
        logger: _ScriptedLogger(
          answers: ['retry', 'different model', 'gemini', 'commit'],
        ),
        builtModels: built,
      );

      expect(exit, ExitCode.success.code);
      expect(built, ['codex', 'gemini']);
    });
  });

  group('commit large-file "Add to .gitignore and unstage"', () {
    Future<int> addToGitignore(
      Directory repo, {
      List<String> extraAnswers = const [],
    }) {
      return _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add small file'),
        workingDirectory: repo.path,
        logger: _ScriptedLogger(
          answers: ['Add to .gitignore and unstage', ...extraAnswers],
        ),
        config: _TestConfigManager(maxFileSize: 16),
      );
    }

    test('works on a branch with no commits yet', () async {
      final repo = await _createRepo(sandbox, 'repo', initialCommit: false);
      await _stageFile(repo, 'big.bin', 'x' * 64);
      await _stageFile(repo, 'small.txt', 'small\n');
      // Change the working copy after staging, which `git rm --cached` only
      // accepts with -f.
      File(p.join(repo.path, 'big.bin')).writeAsStringSync('y' * 64);

      final exit = await addToGitignore(repo);

      expect(exit, ExitCode.success.code);
      expect(
        await _gitOk(['show', '--name-only', '--pretty=', 'HEAD'], repo.path),
        'small.txt',
      );
      expect(File(p.join(repo.path, 'big.bin')).readAsStringSync(), 'y' * 64);
      expect(
        File(p.join(repo.path, '.gitignore')).readAsStringSync(),
        'big.bin\n',
      );
    });

    test('restores a tracked file instead of staging its deletion', () async {
      final repo = await _createRepo(sandbox, 'repo');
      await _stageFile(repo, 'big.bin', 'x' * 64);
      await _gitOk(['commit', '-q', '-m', 'add big file'], repo.path);
      await _stageFile(repo, 'big.bin', 'y' * 64);

      final exit = await addToGitignore(repo);

      expect(exit, CommitCommand.cancelledExitCode.code);
      expect(await _stagedFiles(repo), isEmpty);
      expect(await _gitOk(['ls-files', 'big.bin'], repo.path), 'big.bin');
    });

    test('reports a failure and continues with the other repositories',
        () async {
      final workspace = Directory(p.join(sandbox.path, 'workspace'))
        ..createSync();
      final broken = await _createRepo(workspace, 'broken');
      final fine = await _createRepo(workspace, 'fine');
      await _stageFile(broken, 'big.bin', 'x' * 64);
      // A directory where .gitignore should be makes the write fail.
      Directory(p.join(broken.path, '.gitignore')).createSync();
      await _stageFile(fine, 'a.txt', 'a\n');
      final logger = _ScriptedLogger(
        answers: ['continue', 'Add to .gitignore and unstage'],
      );

      final exit = await _runCommit(
        ['--model', 'codex'],
        _FakeGenerator('feat: Add a'),
        workingDirectory: workspace.path,
        logger: logger,
        config: _TestConfigManager(maxFileSize: 16),
      );

      expect(exit, ExitCode.software.code);
      expect(await _lastSubject(fine), 'feat: Add a');
      expect(
        logger.errors,
        contains(startsWith('[broken] Could not handle large files')),
      );
      expect(logger.errors, contains('Failed in: broken'));
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

/// [path] with symlinks resolved; git reports /private/var on macOS where
/// Directory.systemTemp says /var.
String _canonical(String path) => Directory(path).resolveSymbolicLinksSync();

/// Creates an empty bare repository in the sandbox to push to.
Future<Directory> _createBareRemote(Directory parent, String name) async {
  final bare = Directory(p.join(parent.path, '$name.git'))
    ..createSync(recursive: true);
  final empty = Directory(p.join(parent.path, '.empty-$name.git'))
    ..createSync(recursive: true);
  await _gitOk(['init', '--bare', '-q', '--template=${empty.path}'], bare.path);
  await _gitOk(['config', 'core.hooksPath', empty.path], bare.path);
  return bare;
}

/// The commit [ref] points to in [repo], or null if it does not exist.
Future<String?> _ref(Directory repo, String ref) async {
  final result = await _git(['rev-parse', '--verify', '-q', ref], repo.path);
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
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

/// Generator without an agent implementation, like a provider that only
/// accepts a prompt.
class _DirectOnlyGenerator extends CommitGenerator {
  _DirectOnlyGenerator(this._message) : super(null);

  final String _message;
  final List<String> directInputs = [];

  @override
  String get modelName => 'direct-only';

  @override
  String get defaultVariant => '';

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) async {
    directInputs.add(diff);
    return _message;
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async =>
      _message;
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

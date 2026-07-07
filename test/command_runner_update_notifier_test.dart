import 'package:gitwhisper/src/command_runner.dart';
import 'package:gitwhisper/src/update/update_notifier.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

void main() {
  test('checks for updates before normal commands', () async {
    final notifier = RecordingUpdateNotifier();
    final runner = GitWhisperCommandRunner(updateNotifier: notifier);

    final exitCode = await runner.run(['list-models']);

    expect(exitCode, 0);
    expect(notifier.calls, 1);
  });

  test('stops after a successful automatic update', () async {
    final notifier = RecordingUpdateNotifier(updated: true);
    final runner = GitWhisperCommandRunner(updateNotifier: notifier);

    final exitCode = await runner.run([
      'set-defaults',
      '--model',
      'openai',
      '--confirm-commits',
      '--no-confirm-commits',
    ]);

    expect(exitCode, ExitCode.success.code);
    expect(notifier.calls, 1);
  });

  test('does not check for updates for version command', () async {
    final notifier = RecordingUpdateNotifier();
    final runner = GitWhisperCommandRunner(updateNotifier: notifier);

    final exitCode = await runner.run(['--version']);

    expect(exitCode, 0);
    expect(notifier.calls, 0);
  });

  test('does not check for updates for update command', () async {
    final notifier = RecordingUpdateNotifier();
    final runner = GitWhisperCommandRunner(updateNotifier: notifier);

    final exitCode = await runner.run(['update', '--help']);

    expect(exitCode, 0);
    expect(notifier.calls, 0);
  });

  test('does not check for updates for mcp command', () async {
    final notifier = RecordingUpdateNotifier();
    final runner = GitWhisperCommandRunner(updateNotifier: notifier);

    final exitCode = await runner.run(['mcp', 'git-tools']);

    expect(exitCode, ExitCode.usage.code);
    expect(notifier.calls, 0);
  });
}

class RecordingUpdateNotifier extends UpdateNotifier {
  RecordingUpdateNotifier({this.updated = false}) : super(logger: Logger());

  final bool updated;
  int calls = 0;

  @override
  Future<bool> maybePrompt() async {
    calls++;
    return updated;
  }
}

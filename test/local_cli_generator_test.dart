import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/models/claude_code_generator.dart';
import 'package:gitwhisper/src/models/codex_cli_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CodexCliGenerator', () {
    test('passes the GitWhisper prompt to codex exec via stdin', () async {
      final fakeCli = await FakeCli.create('codex');
      addTearDown(fakeCli.dispose);

      final generator = CodexCliGenerator(
        variant: 'gpt-5.1',
        environment: fakeCli.environment,
        workingDirectory: fakeCli.workingDirectory,
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/lib/a.dart b/lib/a.dart\n+final value = 1;',
        Language.english,
        prefix: 'GW-12',
      );

      expect(message, 'feat: add local cli support');

      final invocation = await fakeCli.readInvocation();
      expect(
        invocation.args,
        [
          'exec',
          '--sandbox',
          'read-only',
          '--ephemeral',
          '--cd',
          fakeCli.workingDirectory,
          '--model',
          'gpt-5.1',
          '--skip-git-repo-check',
          '-',
        ],
      );
      expect(invocation.stdin, contains('GW-12'));
      expect(invocation.stdin, contains('diff --git'));
    });

    test('reports a helpful error when codex is unavailable', () async {
      const generator = CodexCliGenerator(
        environment: {'PATH': ''},
      );

      expect(
        () => generator.analyzeChanges('diff', Language.english),
        throwsA(
          isA<ProcessException>().having(
            (error) => error.message,
            'message',
            contains('Codex CLI was not found'),
          ),
        ),
      );
    });
  });

  group('ClaudeCodeGenerator', () {
    test('passes the GitWhisper prompt to claude print via stdin', () async {
      final fakeCli = await FakeCli.create('claude');
      addTearDown(fakeCli.dispose);

      final generator = ClaudeCodeGenerator(
        variant: 'sonnet',
        environment: fakeCli.environment,
        workingDirectory: fakeCli.workingDirectory,
      );

      final analysis = await generator.analyzeChanges(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
      );

      expect(analysis, 'feat: add local cli support');

      final invocation = await fakeCli.readInvocation();
      expect(invocation.args, ['--print', '--model', 'sonnet']);
      expect(invocation.stdin, contains('diff --git'));
    });
  });
}

class FakeCli {
  FakeCli._({
    required this.root,
    required this.binDir,
    required this.captureFile,
    required this.workingDirectory,
  });

  final Directory root;
  final Directory binDir;
  final File captureFile;
  final String workingDirectory;

  Map<String, String> get environment => {
        'PATH': '${binDir.path}${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH'] ?? ''}',
        'GITWHISPER_FAKE_CAPTURE': captureFile.path,
      };

  static Future<FakeCli> create(String executable) async {
    final root = await Directory.systemTemp.createTemp('gitwhisper_cli_test_');
    final binDir = await Directory(p.join(root.path, 'bin')).create();
    final workingDirectory =
        await Directory(p.join(root.path, 'workspace')).create();
    final captureFile = File(p.join(root.path, 'invocation.json'));

    if (Platform.isWindows) {
      await File(p.join(binDir.path, '$executable.bat')).writeAsString(
        r'''
@echo off
setlocal enabledelayedexpansion
set ARGS=
:loop
if "%~1"=="" goto done
set ARGS=!ARGS!,"%~1"
shift
goto loop
:done
powershell -NoProfile -Command "\$stdin = [Console]::In.ReadToEnd(); \$json = @{ args = @($env:ARGS.TrimStart(',')); stdin = \$stdin } | ConvertTo-Json -Compress; [IO.File]::WriteAllText(\$env:GITWHISPER_FAKE_CAPTURE, \$json)"
echo feat: add local cli support
''',
      );
    } else {
      final script = File(p.join(binDir.path, executable));
      await script.writeAsString(
        r'''
#!/usr/bin/env sh
stdin_file="$(mktemp)"
cat > "$stdin_file"
python3 - "$GITWHISPER_FAKE_CAPTURE" "$stdin_file" "$@" <<'PY'
import json
import sys

capture_file = sys.argv[1]
stdin_file = sys.argv[2]
args = sys.argv[3:]
with open(stdin_file, 'r', encoding='utf-8') as handle:
    stdin = handle.read()
with open(capture_file, 'w', encoding='utf-8') as handle:
    json.dump({'args': args, 'stdin': stdin}, handle)
print('feat: add local cli support')
PY
rm -f "$stdin_file"
''',
      );
      await Process.run('chmod', ['+x', script.path]);
    }

    return FakeCli._(
      root: root,
      binDir: binDir,
      captureFile: captureFile,
      workingDirectory: workingDirectory.path,
    );
  }

  Future<FakeInvocation> readInvocation() async {
    final json =
        jsonDecode(await captureFile.readAsString()) as Map<String, dynamic>;
    return FakeInvocation(
      args: (json['args'] as List<dynamic>).cast<String>(),
      stdin: json['stdin'] as String,
    );
  }

  Future<void> dispose() => root.delete(recursive: true);
}

class FakeInvocation {
  const FakeInvocation({
    required this.args,
    required this.stdin,
  });

  final List<String> args;
  final String stdin;
}

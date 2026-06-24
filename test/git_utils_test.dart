import 'dart:io';
import 'dart:typed_data';

import 'package:gitwhisper/src/git_utils.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('GitUtils.getStagedDiff', () {
    late Directory repo;

    setUp(() async {
      repo = await Directory.systemTemp.createTemp('gitwhisper_diff_');
      Future<void> git(List<String> args) async {
        final result =
            await Process.run('git', args, workingDirectory: repo.path);
        if (result.exitCode != 0) {
          throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      await git(['init']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'user.name', 'Test']);
    });

    tearDown(() async {
      if (repo.existsSync()) await repo.delete(recursive: true);
    });

    test('does not crash when staged content is not valid UTF-8', () async {
      // Bytes that are invalid UTF-8 (lone 0xFF/0xFE, then a bad continuation
      // sequence). Previously these crashed Process.run's UTF-8 stream decoder
      // with "Unexpected extension byte".
      final badBytes = Uint8List.fromList(
        <int>[0xFF, 0xFE, 0x00, ...'invalid'.codeUnits, 0xC0, 0xC1, 0x0A],
      );
      File(path.join(repo.path, 'bad.bin')).writeAsBytesSync(badBytes);

      final stage = await Process.run(
        'git',
        ['add', 'bad.bin'],
        workingDirectory: repo.path,
      );
      expect(stage.exitCode, 0);

      final diff = await GitUtils.getStagedDiff(folderPath: repo.path);

      // The call returns (no throw) and references the staged file.
      expect(diff, contains('bad.bin'));
    });
  });

  group('GitUtils.sanitizeGeneratedCommitMessage', () {
    test('keeps plain commit messages unchanged', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'feat: Add local provider support',
        ),
        'feat: Add local provider support',
      );
    });

    test('extracts conventional commit lines from explanatory agent output',
        () {
      const raw = '''
Based on the staged changes, I can see:

1. **src/utils/utils.rs** - Added date formatting
2. **emails/*.html** - Redesigned templates

These are two distinct changes:

refactor: Redesign email templates with new brand identity

fix: Add German date formatting for payment emails
''';

      expect(
        GitUtils.sanitizeGeneratedCommitMessage(raw),
        '''
refactor: Redesign email templates with new brand identity
fix: Add German date formatting for payment emails
'''
            .trim(),
      );
    });

    test('preserves ticket-prefixed commit lines', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'Here you go:\n\nPAY-123 -> fix: Add payment date formatting',
        ),
        'PAY-123 -> fix: Add payment date formatting',
      );
    });

    test('extracts conventional commit from same-line agent preface', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          "I'll inspect the staged changes.docs: Add ACP smoke test note",
          requireConventionalCommit: true,
        ),
        'docs: Add ACP smoke test note',
      );
    });

    test('deduplicates repeated commit lines from agent output', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'feat: add ACP retry handling\nfeat: add ACP retry handling',
          requireConventionalCommit: true,
        ),
        'feat: add ACP retry handling',
      );
    });

    test('strict mode rejects planning text without commit lines', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          "I'll inspect the staged changes to generate the commit message.",
          requireConventionalCommit: true,
        ),
        isEmpty,
      );
    });
  });
}

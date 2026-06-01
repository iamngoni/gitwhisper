import 'package:gitwhisper/src/git_utils.dart';
import 'package:test/test.dart';

void main() {
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

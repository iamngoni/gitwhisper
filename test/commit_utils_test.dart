import 'package:gitwhisper/src/commit_utils.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:test/test.dart';

void main() {
  group('appendAdditionalContext', () {
    test('returns the diff unchanged without context', () {
      expect(appendAdditionalContext('diff', null), 'diff');
      expect(appendAdditionalContext('diff', '  \n '), 'diff');
    });

    test('appends trimmed context after the diff', () {
      final input = appendAdditionalContext('diff', '  focus on tests \n');

      expect(input, startsWith('diff\n'));
      expect(
        input,
        contains(
          'ADDITIONAL CONTEXT FROM THE USER (not part of the diff):\n'
          'focus on tests\n',
        ),
      );
    });
  });

  group('getCommitFromSummariesPrompt', () {
    const summaries = {'a.txt': 'Adds a'};

    test('is unchanged when no context is given', () {
      expect(
        getCommitFromSummariesPrompt(
          summaries,
          Language.english,
          additionalContext: '  ',
        ),
        getCommitFromSummariesPrompt(summaries, Language.english),
      );
    });

    test('includes added context before the rules', () {
      final prompt = getCommitFromSummariesPrompt(
        summaries,
        Language.english,
        additionalContext: 'mention the a file',
      );

      final context = prompt.indexOf(
        'ADDITIONAL CONTEXT FROM THE USER:\nmention the a file',
      );
      expect(context, isNonNegative);
      expect(context, lessThan(prompt.indexOf('Rules:')));
      expect(context, greaterThan(prompt.indexOf('- a.txt: Adds a')));
    });
  });

  group('getAgentCommitPrompt', () {
    test('includes added context', () {
      expect(
        getAgentCommitPrompt(
          Language.english,
          additionalContext: ' mention the a file ',
        ),
        contains('ADDITIONAL CONTEXT FROM THE USER:\nmention the a file\n'),
      );
    });
  });
}

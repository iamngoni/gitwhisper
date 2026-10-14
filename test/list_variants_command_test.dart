import 'package:gitwhisper/src/commands/list_variants_command.dart';
import 'package:gitwhisper/src/models/model_variants.dart';
import 'package:test/test.dart';

void main() {
  group('ListVariantsCommand', () {
    test('labels the ModelVariants default for every provider', () {
      for (final model in ListVariantsCommand.models) {
        if (model == 'github') continue;

        final lines = ListVariantsCommand.variantLines(model);
        final defaults = lines.where((line) => line.contains('(default)'));

        expect(
          defaults,
          <String>['  - ${ModelVariants.getDefault(model)} (default)'],
          reason: model,
        );
      }
    });

    test('lists no retired or wrong-API models', () {
      final output = ListVariantsCommand.models
          .expand(ListVariantsCommand.variantLines)
          .join('\n');

      for (final retired in <String>[
        'gemini-1.5',
        'gemini-2.0-flash',
        'gemini-2.5-flash-image',
        'gemini-2.5-computer-use',
        'gpt-4.5-preview',
        'o1-preview',
        'o1-mini',
        'gpt-realtime',
        'gpt-5-pro',
        'claude-3-',
        'claude-sonnet-4-20250514',
        'claude-opus-4-1',
        'grok-2',
        'grok-3',
        'grok-4-heavy',
        'deepseek-chat',
        'deepseek-reasoner',
        'llama-3',
      ]) {
        expect(output, isNot(contains(retired)), reason: retired);
      }
    });

    test('says GitHub Models is retired instead of listing variants', () {
      expect(
        ListVariantsCommand.variantLines('github').join('\n'),
        contains('retired on July 30, 2026'),
      );
    });
  });
}

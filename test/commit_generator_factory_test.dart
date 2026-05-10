import 'package:gitwhisper/src/models/claude_code_generator.dart';
import 'package:gitwhisper/src/models/codex_cli_generator.dart';
import 'package:gitwhisper/src/models/commit_generator_factory.dart';
import 'package:test/test.dart';

void main() {
  group('CommitGeneratorFactory', () {
    test('creates local CLI providers without API keys', () {
      expect(
        CommitGeneratorFactory.create('codex', null),
        isA<CodexCliGenerator>(),
      );
      expect(
        CommitGeneratorFactory.create('claude-code', null),
        isA<ClaudeCodeGenerator>(),
      );
    });
  });
}

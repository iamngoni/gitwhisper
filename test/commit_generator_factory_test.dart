import 'package:gitwhisper/src/models/acp_local_agent_generator.dart';
import 'package:gitwhisper/src/models/claude_code_direct_generator.dart';
import 'package:gitwhisper/src/models/codex_direct_generator.dart';
import 'package:gitwhisper/src/models/commit_generator_factory.dart';
import 'package:test/test.dart';

void main() {
  group('CommitGeneratorFactory', () {
    test('creates Codex and Claude Code direct providers', () {
      expect(
        CommitGeneratorFactory.create('codex', null),
        isA<CodexDirectGenerator>(),
      );
      expect(
        CommitGeneratorFactory.create('claude-code', null),
        isA<ClaudeCodeDirectGenerator>(),
      );
    });

    test('creates arbitrary ACP providers by model id', () {
      expect(
        CommitGeneratorFactory.create('vtcode', null),
        isA<AcpLocalAgentGenerator>(),
      );
    });
  });
}

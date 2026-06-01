import 'package:gitwhisper/src/models/acp_local_agent_generator.dart';
import 'package:gitwhisper/src/models/commit_generator_factory.dart';
import 'package:test/test.dart';

void main() {
  group('CommitGeneratorFactory', () {
    test('creates compatibility aliases as generic ACP providers', () {
      expect(
        CommitGeneratorFactory.create('codex', null),
        isA<AcpLocalAgentGenerator>(),
      );
      expect(
        CommitGeneratorFactory.create('claude-code', null),
        isA<AcpLocalAgentGenerator>(),
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

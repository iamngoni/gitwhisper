import 'package:gitwhisper/src/models/acp_local_agent_generator.dart';
import 'package:gitwhisper/src/models/claude_code_direct_generator.dart';
import 'package:gitwhisper/src/models/codex_direct_generator.dart';
import 'package:gitwhisper/src/models/commit_generator_factory.dart';
import 'package:gitwhisper/src/models/deepseek_generator.dart';
import 'package:gitwhisper/src/models/github_generator.dart';
import 'package:gitwhisper/src/models/grok_generator.dart';
import 'package:gitwhisper/src/models/llama_generator.dart';
import 'package:gitwhisper/src/models/openai_compatible_generator.dart';
import 'package:gitwhisper/src/models/openai_generator.dart';
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

    test('creates OpenAI-compatible providers from one shared base', () {
      for (final (model, type) in <(String, TypeMatcher<Object>)>[
        ('openai', isA<OpenAIGenerator>()),
        ('grok', isA<GrokGenerator>()),
        ('deepseek', isA<DeepseekGenerator>()),
        ('llama', isA<LlamaGenerator>()),
        ('github', isA<GithubGenerator>()),
      ]) {
        final generator = CommitGeneratorFactory.create(model, 'test-key');

        expect(generator, type, reason: model);
        expect(generator, isA<OpenAiCompatibleGenerator>(), reason: model);
        expect(generator.modelName, model);
      }
    });

    test('creates arbitrary ACP providers by model id', () {
      expect(
        CommitGeneratorFactory.create('vtcode', null),
        isA<AcpLocalAgentGenerator>(),
      );
    });
  });
}

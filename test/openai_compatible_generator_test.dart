import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/openai_compatible_agent_runner.dart';
import 'package:gitwhisper/src/exceptions/exceptions.dart';
import 'package:gitwhisper/src/models/deepseek_generator.dart';
import 'package:gitwhisper/src/models/github_generator.dart';
import 'package:gitwhisper/src/models/grok_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:gitwhisper/src/models/llama_generator.dart';
import 'package:gitwhisper/src/models/model_variants.dart';
import 'package:gitwhisper/src/models/openai_compatible_generator.dart';
import 'package:gitwhisper/src/models/openai_generator.dart';
import 'package:test/test.dart';

import 'helpers/mock_dio.dart';

void main() {
  group('OpenAI-compatible providers', () {
    for (final scenario in <({
      String label,
      OpenAiCompatibleGenerator Function() create,
      String endpoint,
      String maxTokensKey,
    })>[
      (
        label: 'OpenAI',
        create: () => OpenAIGenerator('test-key'),
        endpoint: 'https://api.openai.com/v1/chat/completions',
        maxTokensKey: 'max_completion_tokens',
      ),
      (
        label: 'Grok',
        create: () => GrokGenerator('test-key'),
        endpoint: 'https://api.x.ai/v1/chat/completions',
        maxTokensKey: 'max_tokens',
      ),
      (
        label: 'DeepSeek',
        create: () => DeepseekGenerator('test-key'),
        endpoint: 'https://api.deepseek.com/chat/completions',
        maxTokensKey: 'max_tokens',
      ),
      (
        label: 'Meta Model API (llama)',
        create: () => LlamaGenerator('test-key'),
        endpoint: 'https://api.meta.ai/v1/chat/completions',
        maxTokensKey: 'max_completion_tokens',
      ),
    ]) {
      test('${scenario.label} sends commit requests to its endpoint', () async {
        final requests = mockDio(<MockReply>[
          MockReply.json(_chatReply('feat: Add provider tests')),
        ]);
        final generator = scenario.create();

        final message = await generator.generateCommitMessage(
          'diff --git a/a b/a',
          Language.english,
        );

        expect(message, 'feat: Add provider tests');
        final request = requests.single;
        expect(request.uri.toString(), scenario.endpoint);
        expect(request.headers['Authorization'], 'Bearer test-key');
        final body = bodyOf(request);
        expect(body['model'], ModelVariants.getDefault(generator.modelName));
        expect(body[scenario.maxTokensKey], generator.maxTokens);
        expect(body, isNot(contains('store')));
      });
    }

    test('never asks OpenAI to store diffs', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(_chatReply('feat: Add a thing')),
        MockReply.json(_chatReply('Looks fine.')),
        MockReply.json(_chatReply('feat: Add a thing')),
      ]);
      final generator = OpenAIGenerator('test-key', variant: 'gpt-test');

      await generator.generateCommitMessage('diff', Language.english);
      await generator.analyzeChanges('diff', Language.english);
      await generator.generateAgentCommitMessage(_agentRequest());

      expect(requests, hasLength(3));
      for (final request in requests) {
        expect(bodyOf(request), isNot(contains('store')));
      }
    });

    test('raises a provider-named error when content is missing', () async {
      mockDio(<MockReply>[
        MockReply.json(_chatReply(null)),
      ]);

      await expectLater(
        OpenAIGenerator('test-key').generateCommitMessage(
          'diff',
          Language.english,
        ),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            'OpenAI returned an empty commit message.',
          ),
        ),
      );
    });

    test('raises a provider-named error when choices are empty', () async {
      mockDio(<MockReply>[
        const MockReply.json(<String, dynamic>{'choices': <dynamic>[]}),
      ]);

      await expectLater(
        GrokGenerator('test-key').generateCommitMessage(
          'diff',
          Language.english,
        ),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            'Grok response did not include any choices.',
          ),
        ),
      );
    });

    test('reports refusals instead of returning an empty message', () async {
      mockDio(<MockReply>[
        MockReply.json(
          _chatReply(null, extra: <String, dynamic>{'refusal': 'No thanks.'}),
        ),
      ]);

      await expectLater(
        OpenAIGenerator('test-key').generateCommitMessage(
          'diff',
          Language.english,
        ),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            contains('declined the request: No thanks.'),
          ),
        ),
      );
    });

    test('retries a truncated commit message with a larger limit', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(_chatReply('feat: Add', finishReason: 'length')),
        MockReply.json(_chatReply('feat: Add retry handling')),
      ]);
      final generator = DeepseekGenerator('test-key');

      final message = await generator.generateCommitMessage(
        'diff',
        Language.english,
      );

      expect(message, 'feat: Add retry handling');
      expect(bodyOf(requests[0])['max_tokens'], generator.maxTokens);
      expect(
        bodyOf(requests[1])['max_tokens'],
        generator.truncationRetryMaxTokens,
      );
    });

    test('raises instead of using a message that is still truncated', () async {
      mockDio(<MockReply>[
        MockReply.json(_chatReply('feat: Add', finishReason: 'length')),
        MockReply.json(_chatReply('feat: Add re', finishReason: 'length')),
      ]);

      await expectLater(
        OpenAIGenerator('test-key').generateCommitMessage(
          'diff',
          Language.english,
        ),
        throwsA(isA<ResponseTruncatedException>()),
      );
    });

    test('keeps a truncated analysis but says it was cut off', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(_chatReply('Partial analysis', finishReason: 'length')),
      ]);
      final generator = GrokGenerator('test-key');

      final analysis = await generator.analyzeChanges('diff', Language.english);

      expect(analysis, startsWith('Partial analysis'));
      expect(analysis, contains('[Analysis truncated'));
      expect(
        bodyOf(requests.single)['max_tokens'],
        generator.maxAnalysisTokens,
      );
    });

    test('keeps the provider error text in the thrown exception', () async {
      mockDio(<MockReply>[
        const MockReply(
          <String, dynamic>{
            'error': <String, dynamic>{
              'message': 'This model does not support tools.',
              'type': 'invalid_request_error',
            },
          },
          statusCode: 400,
        ),
      ]);

      await expectLater(
        DeepseekGenerator('test-key').generateAgentCommitMessage(
          _agentRequest(),
        ),
        throwsA(
          isA<InvalidRequestException>().having(
            (e) => e.message,
            'message',
            'This model does not support tools.',
          ),
        ),
      );
    });
  });

  group('OpenAI-compatible agent mode', () {
    for (final scenario in <({
      String label,
      AgentCommitGenerator Function() create,
      String expected,
    })>[
      (
        label: 'OpenAI',
        create: () => OpenAIGenerator('test-key'),
        expected: 'required',
      ),
      // DeepSeek thinking mode and the Meta Model API reject `required`.
      (
        label: 'DeepSeek',
        create: () => DeepseekGenerator('test-key'),
        expected: 'auto',
      ),
      (
        label: 'Meta Model API (llama)',
        create: () => LlamaGenerator('test-key'),
        expected: 'auto',
      ),
    ]) {
      test('${scenario.label} sends tool_choice ${scenario.expected} first',
          () async {
        final requests = mockDio(<MockReply>[
          MockReply.json(_chatReply('feat: Add a thing')),
        ]);

        await scenario.create().generateAgentCommitMessage(_agentRequest());

        expect(bodyOf(requests.single)['tool_choice'], scenario.expected);
      });
    }

    test('asks for the message with tools disabled once the budget is used',
        () async {
      final tools = FakeAgentTools();
      final requests = mockDio(<MockReply>[
        MockReply.json(
          _chatReply(
            null,
            finishReason: 'tool_calls',
            toolCalls: <Map<String, dynamic>>[
              _toolCall('call_1', 'list_staged_files'),
              _toolCall('call_2', 'get_diff_stat'),
            ],
          ),
        ),
        MockReply.json(_chatReply('feat: Add budget handling')),
      ]);

      final message =
          await OpenAIGenerator('test-key').generateAgentCommitMessage(
        _agentRequest(tools: tools, maxToolCalls: 1),
      );

      expect(message, 'feat: Add budget handling');
      expect(tools.calls, <String>['list_staged_files']);
      expect(requests, hasLength(2));

      final finalBody = bodyOf(requests[1]);
      expect(finalBody['tool_choice'], 'none');
      final messages = finalBody['messages'] as List<dynamic>;
      expect(
        messages.whereType<Map<String, dynamic>>().map((m) => m['content']),
        containsAllInOrder(<Object?>[
          'result of list_staged_files',
          agentToolBudgetSkippedResult,
          agentToolBudgetExhaustedPrompt(1),
        ]),
      );
    });

    test('drops the tools for the final Meta Model API request', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(
          _chatReply(
            null,
            finishReason: 'tool_calls',
            toolCalls: <Map<String, dynamic>>[
              _toolCall('call_1', 'list_staged_files'),
            ],
          ),
        ),
        MockReply.json(_chatReply('feat: Add Meta support')),
      ]);

      await LlamaGenerator('test-key').generateAgentCommitMessage(
        _agentRequest(maxToolCalls: 1),
      );

      final finalBody = bodyOf(requests[1]);
      expect(finalBody, isNot(contains('tools')));
      expect(finalBody, isNot(contains('tool_choice')));
    });

    test('raises when no message comes back after tools are disabled',
        () async {
      mockDio(<MockReply>[
        MockReply.json(
          _chatReply(
            null,
            finishReason: 'tool_calls',
            toolCalls: <Map<String, dynamic>>[
              _toolCall('call_1', 'list_staged_files'),
            ],
          ),
        ),
        MockReply.json(
          _chatReply(
            null,
            finishReason: 'tool_calls',
            toolCalls: <Map<String, dynamic>>[
              _toolCall('call_2', 'get_diff_stat'),
            ],
          ),
        ),
      ]);

      await expectLater(
        GrokGenerator('test-key').generateAgentCommitMessage(
          _agentRequest(maxToolCalls: 1),
        ),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            contains('after they were disabled'),
          ),
        ),
      );
    });

    test('retries a truncated agent turn with a larger limit', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(_chatReply('feat: Add', finishReason: 'length')),
        MockReply.json(_chatReply('feat: Add agent retries')),
      ]);
      final generator = OpenAIGenerator('test-key');

      final message = await generator.generateAgentCommitMessage(
        _agentRequest(),
      );

      expect(message, 'feat: Add agent retries');
      expect(
        bodyOf(requests[0])['max_completion_tokens'],
        generator.agentTurnMaxTokens,
      );
      expect(
        bodyOf(requests[1])['max_completion_tokens'],
        generator.truncationRetryMaxTokens,
      );
    });
  });

  group('GitHub Models', () {
    test('fails fast with a retirement error and makes no request', () async {
      final requests = mockDio(const <MockReply>[]);
      final generator = GithubGenerator('test-key');

      for (final call in <Future<String> Function()>[
        () => generator.generateCommitMessage('diff', Language.english),
        () => generator.analyzeChanges('diff', Language.english),
        () => generator.generateAgentCommitMessage(_agentRequest()),
      ]) {
        await expectLater(call(), throwsA(isA<ProviderRetiredException>()));
      }
      expect(requests, isEmpty);
    });
  });
}

AgentCommitRequest _agentRequest({
  FakeAgentTools? tools,
  int maxToolCalls = 32,
}) {
  return AgentCommitRequest(
    tools: tools ?? FakeAgentTools(),
    language: Language.english,
    maxToolCalls: maxToolCalls,
  );
}

Map<String, dynamic> _chatReply(
  String? content, {
  String finishReason = 'stop',
  List<Map<String, dynamic>>? toolCalls,
  Map<String, dynamic> extra = const <String, dynamic>{},
}) {
  return <String, dynamic>{
    'choices': <Map<String, dynamic>>[
      <String, dynamic>{
        'finish_reason': finishReason,
        'message': <String, dynamic>{
          'role': 'assistant',
          'content': content,
          if (toolCalls != null) 'tool_calls': toolCalls,
          ...extra,
        },
      },
    ],
  };
}

Map<String, dynamic> _toolCall(String id, String name) {
  return <String, dynamic>{
    'id': id,
    'type': 'function',
    'function': <String, dynamic>{'name': name, 'arguments': '{}'},
  };
}

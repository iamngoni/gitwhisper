import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/openai_compatible_agent_runner.dart';
import 'package:gitwhisper/src/exceptions/exceptions.dart';
import 'package:gitwhisper/src/models/claude_generator.dart';
import 'package:gitwhisper/src/models/gemini_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:gitwhisper/src/models/model_variants.dart';
import 'package:gitwhisper/src/models/ollama_generator.dart';
import 'package:test/test.dart';

import 'helpers/mock_dio.dart';

void main() {
  group('ClaudeGenerator', () {
    test('uses the current default model', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(_claudeReply(<Map<String, dynamic>>[_text('feat: X')])),
      ]);

      await ClaudeGenerator('test-key').generateCommitMessage(
        'diff',
        Language.english,
      );

      expect(bodyOf(requests.single)['model'], ModelVariants.claudeDefault);
    });

    test('raises a provider-named error when content is missing', () async {
      mockDio(<MockReply>[
        const MockReply.json(<String, dynamic>{'stop_reason': 'end_turn'}),
      ]);

      await expectLater(
        ClaudeGenerator('test-key').generateCommitMessage(
          'diff',
          Language.english,
        ),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            'Claude response did not include content.',
          ),
        ),
      );
    });

    test('retries a commit message cut off at max_tokens', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(
          _claudeReply(
            <Map<String, dynamic>>[_text('feat: Add')],
            stopReason: 'max_tokens',
          ),
        ),
        MockReply.json(
          _claudeReply(<Map<String, dynamic>>[_text('feat: Add retries')]),
        ),
      ]);
      final generator = ClaudeGenerator('test-key');

      final message = await generator.generateCommitMessage(
        'diff',
        Language.english,
      );

      expect(message, 'feat: Add retries');
      expect(bodyOf(requests[0])['max_tokens'], generator.maxTokens);
      expect(
        bodyOf(requests[1])['max_tokens'],
        generator.truncationRetryMaxTokens,
      );
    });

    test('reports refusals', () async {
      mockDio(<MockReply>[
        MockReply.json(
          _claudeReply(<Map<String, dynamic>>[], stopReason: 'refusal'),
        ),
      ]);

      await expectLater(
        ClaudeGenerator('test-key').generateCommitMessage(
          'diff',
          Language.english,
        ),
        throwsA(
          isA<InvalidResponseException>()
              .having((e) => e.errorType, 'errorType', 'refusal'),
        ),
      );
    });

    test('asks for the message with tool_choice none once the budget is used',
        () async {
      final tools = FakeAgentTools();
      final requests = mockDio(<MockReply>[
        MockReply.json(
          _claudeReply(
            <Map<String, dynamic>>[
              _toolUse('toolu_1', 'list_staged_files'),
              _toolUse('toolu_2', 'get_diff_stat'),
            ],
            stopReason: 'tool_use',
          ),
        ),
        MockReply.json(
          _claudeReply(<Map<String, dynamic>>[_text('feat: Add budget')]),
        ),
      ]);

      final message = await ClaudeGenerator('test-key')
          .generateAgentCommitMessage(_agentRequest(tools: tools));

      expect(message, 'feat: Add budget');
      expect(tools.calls, <String>['list_staged_files']);
      expect(bodyOf(requests[0])['tool_choice'], <String, dynamic>{
        'type': 'auto',
      });

      final finalBody = bodyOf(requests[1]);
      expect(finalBody['tool_choice'], <String, dynamic>{'type': 'none'});
      expect(finalBody['tools'], isNotEmpty);
      final messages = finalBody['messages'] as List<dynamic>;
      final toolResults = (messages.last as Map<String, dynamic>)['content']
          as List<Map<String, dynamic>>;
      expect(toolResults[0]['content'], 'result of list_staged_files');
      expect(toolResults[1]['content'], agentToolBudgetSkippedResult);
      expect(toolResults[1]['is_error'], isTrue);
      expect(toolResults[2], <String, dynamic>{
        'type': 'text',
        'text': agentToolBudgetExhaustedPrompt(1),
      });
    });
  });

  group('GeminiGenerator', () {
    test('sends the API key in a header, never in the URL', () async {
      final requests = mockDio(<MockReply>[
        MockReply.json(_geminiReply(<Map<String, dynamic>>[_text('feat: X')])),
      ]);

      await GeminiGenerator('secret-key').generateCommitMessage(
        'diff',
        Language.english,
      );

      final request = requests.single;
      expect(request.headers['x-goog-api-key'], 'secret-key');
      expect(request.uri.queryParameters, isNot(contains('key')));
      expect(request.uri.toString(), isNot(contains('secret-key')));
      expect(
        request.uri.path,
        endsWith('/models/${ModelVariants.geminiDefault}:generateContent'),
      );
    });

    test('retries when thinking used up the limit before any text', () async {
      final requests = mockDio(<MockReply>[
        const MockReply.json(<String, dynamic>{
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'content': <String, dynamic>{'role': 'model'},
              'finishReason': 'MAX_TOKENS',
            },
          ],
        }),
        MockReply.json(
          _geminiReply(<Map<String, dynamic>>[_text('feat: Add Gemini')]),
        ),
      ]);
      final generator = GeminiGenerator('test-key');

      final message = await generator.generateCommitMessage(
        'diff',
        Language.english,
      );

      expect(message, 'feat: Add Gemini');
      expect(
        (bodyOf(requests[1])['generationConfig']
            as Map<String, dynamic>)['maxOutputTokens'],
        generator.truncationRetryMaxTokens,
      );
    });

    test('names the finish reason when a candidate has no text', () async {
      mockDio(<MockReply>[
        const MockReply.json(<String, dynamic>{
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{'finishReason': 'SAFETY'},
          ],
        }),
      ]);

      await expectLater(
        GeminiGenerator('test-key').generateCommitMessage(
          'diff',
          Language.english,
        ),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            'Gemini returned no text (finishReason: SAFETY).',
          ),
        ),
      );
    });

    test('reports a blocked prompt instead of throwing a RangeError', () async {
      mockDio(<MockReply>[
        const MockReply.json(<String, dynamic>{
          'promptFeedback': <String, dynamic>{'blockReason': 'OTHER'},
        }),
      ]);

      await expectLater(
        GeminiGenerator('test-key').analyzeChanges('diff', Language.english),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            contains('blockReason: OTHER'),
          ),
        ),
      );
    });

    test('disables function calling once the budget is used', () async {
      final tools = FakeAgentTools();
      final requests = mockDio(<MockReply>[
        MockReply.json(
          _geminiReply(<Map<String, dynamic>>[
            _functionCall('list_staged_files'),
            _functionCall('get_diff_stat'),
          ]),
        ),
        MockReply.json(
          _geminiReply(<Map<String, dynamic>>[_text('feat: Add budget')]),
        ),
      ]);

      final message = await GeminiGenerator('test-key')
          .generateAgentCommitMessage(_agentRequest(tools: tools));

      expect(message, 'feat: Add budget');
      expect(tools.calls, <String>['list_staged_files']);

      final finalBody = bodyOf(requests[1]);
      expect(
        finalBody['toolConfig'],
        <String, dynamic>{
          'functionCallingConfig': <String, dynamic>{'mode': 'NONE'},
        },
      );
      expect(
        finalBody['systemInstruction'].toString(),
        contains(agentToolBudgetExhaustedPrompt(1)),
      );
      expect(
        finalBody['contents'].toString(),
        contains(agentToolBudgetSkippedResult),
      );
    });
  });

  group('OllamaGenerator', () {
    test('limits output with options.num_predict', () async {
      final requests = mockDio(<MockReply>[
        _ollamaGenerateReply('feat: Add Ollama limits'),
        _ollamaGenerateReply('Analysis'),
      ]);
      final generator = OllamaGenerator('http://localhost:11434/', null);

      await generator.generateCommitMessage('diff', Language.english);
      await generator.analyzeChanges('diff', Language.english);

      for (final (index, limit) in <int>[
        generator.maxTokens,
        generator.maxAnalysisTokens,
      ].indexed) {
        final request = requests[index];
        expect(request.uri.toString(), 'http://localhost:11434/api/generate');
        final body = bodyOf(request);
        expect(body, isNot(contains('max_tokens')));
        expect(body['options'], <String, dynamic>{'num_predict': limit});
      }
    });

    test('waits longer than hosted providers for local models', () async {
      final requests = mockDio(<MockReply>[
        _ollamaGenerateReply('feat: Add a timeout'),
      ]);

      await OllamaGenerator('http://localhost:11434', null)
          .generateCommitMessage('diff', Language.english);

      expect(requests.single.receiveTimeout, OllamaGenerator.receiveTimeout);
    });

    test('retries when generation stops at the length limit', () async {
      final requests = mockDio(<MockReply>[
        _ollamaGenerateReply('feat: Add', doneReason: 'length'),
        _ollamaGenerateReply('feat: Add retries'),
      ]);
      final generator = OllamaGenerator('http://localhost:11434', null);

      final message = await generator.generateCommitMessage(
        'diff',
        Language.english,
      );

      expect(message, 'feat: Add retries');
      expect(bodyOf(requests[1])['options'], <String, dynamic>{
        'num_predict': generator.truncationRetryMaxTokens,
      });
    });

    test('names Ollama when the response has no text', () async {
      mockDio(<MockReply>[
        const MockReply.json(<String, dynamic>{'done': true}),
      ]);

      await expectLater(
        OllamaGenerator('http://localhost:11434', null)
            .generateCommitMessage('diff', Language.english),
        throwsA(
          isA<InvalidResponseException>().having(
            (e) => e.message,
            'message',
            'Ollama response did not include generated text.',
          ),
        ),
      );
    });

    for (final scenario in <({String label, Object body})>[
      (
        label: 'a JSON error',
        body: <String, dynamic>{
          'error': 'registry.ollama.ai/library/gemma3:latest does not '
              'support tools',
        },
      ),
      (
        label: 'a JSON error sent as text',
        body: '{"error":"registry.ollama.ai/library/gemma3:latest does not '
            'support tools"}',
      ),
    ]) {
      test('keeps "does not support tools" from ${scenario.label}', () async {
        mockDio(<MockReply>[MockReply(scenario.body, statusCode: 400)]);

        await expectLater(
          OllamaGenerator('http://localhost:11434', null)
              .generateAgentCommitMessage(_agentRequest()),
          throwsA(
            isA<InvalidRequestException>().having(
              (e) => e.message,
              'message',
              contains('does not support tools'),
            ),
          ),
        );
      });
    }

    test('drops the tools once the budget is used', () async {
      final tools = FakeAgentTools();
      final requests = mockDio(<MockReply>[
        const MockReply.json(<String, dynamic>{
          'message': <String, dynamic>{
            'role': 'assistant',
            'content': '',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'function': <String, dynamic>{
                  'name': 'list_staged_files',
                  'arguments': <String, dynamic>{},
                },
              },
              <String, dynamic>{
                'function': <String, dynamic>{
                  'name': 'get_diff_stat',
                  'arguments': <String, dynamic>{},
                },
              },
            ],
          },
        }),
        const MockReply.json(<String, dynamic>{
          'message': <String, dynamic>{
            'role': 'assistant',
            'content': 'feat: Add budget',
          },
        }),
      ]);

      final message = await OllamaGenerator('http://localhost:11434', null)
          .generateAgentCommitMessage(_agentRequest(tools: tools));

      expect(message, 'feat: Add budget');
      expect(tools.calls, <String>['list_staged_files']);
      expect(bodyOf(requests[0]), contains('tools'));

      final finalBody = bodyOf(requests[1]);
      expect(finalBody, isNot(contains('tools')));
      final messages = finalBody['messages'] as List<dynamic>;
      expect(
        (messages.last as Map<String, dynamic>)['content'],
        agentToolBudgetExhaustedPrompt(1),
      );
      expect(messages.toString(), contains(agentToolBudgetSkippedResult));
    });
  });
}

AgentCommitRequest _agentRequest({FakeAgentTools? tools}) {
  return AgentCommitRequest(
    tools: tools ?? FakeAgentTools(),
    language: Language.english,
    maxToolCalls: 1,
  );
}

Map<String, dynamic> _text(String text) =>
    <String, dynamic>{'type': 'text', 'text': text};

Map<String, dynamic> _toolUse(String id, String name) => <String, dynamic>{
      'type': 'tool_use',
      'id': id,
      'name': name,
      'input': <String, dynamic>{},
    };

Map<String, dynamic> _claudeReply(
  List<Map<String, dynamic>> content, {
  String stopReason = 'end_turn',
}) {
  return <String, dynamic>{'content': content, 'stop_reason': stopReason};
}

Map<String, dynamic> _functionCall(String name) => <String, dynamic>{
      'functionCall': <String, dynamic>{
        'name': name,
        'args': <String, dynamic>{},
      },
    };

Map<String, dynamic> _geminiReply(
  List<Map<String, dynamic>> parts, {
  String finishReason = 'STOP',
}) {
  return <String, dynamic>{
    'candidates': <Map<String, dynamic>>[
      <String, dynamic>{
        'content': <String, dynamic>{'role': 'model', 'parts': parts},
        'finishReason': finishReason,
      },
    ],
  };
}

MockReply _ollamaGenerateReply(String text, {String doneReason = 'stop'}) {
  return MockReply.json(<String, dynamic>{
    'response': text,
    'done': true,
    'done_reason': doneReason,
  });
}

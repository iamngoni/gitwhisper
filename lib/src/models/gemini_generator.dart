//
//  gitwhisper
//  gemini_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../agent/agent_commit_generator.dart';
import '../agent/git_agent_tools.dart';
import '../agent/openai_compatible_agent_runner.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

/// One Gemini candidate: its parts, and why generation stopped.
typedef _GeminiTurn = ({
  List<Map<String, dynamic>> parts,
  String? finishReason,
});

class GeminiGenerator extends CommitGenerator implements AgentCommitGenerator {
  GeminiGenerator(super.apiKey, {super.variant});

  /// Finish reasons that mean the output was cut off at the token limit.
  static const Set<String> _truncatedFinishReasons = <String>{
    'MAX_TOKENS',
    'CONTINUATION',
  };

  /// Finish reasons for a candidate that ended normally.
  static const Set<String> _normalFinishReasons = <String>{
    'STOP',
    ..._truncatedFinishReasons,
  };

  @override
  String get modelName => 'gemini';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  String get _endpoint => 'https://generativelanguage.googleapis.com/v1beta/'
      'models/$actualVariant:generateContent';

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) {
    final prompt = getCommitPrompt(
      diff,
      language,
      prefix: prefix,
      withEmoji: withEmoji,
    );

    return requestCommitMessage('Gemini', (limit) => _complete(prompt, limit));
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    final prompt = getAnalysisPrompt(diff, language);

    return requestAnalysis('Gemini', (limit) => _complete(prompt, limit));
  }

  @override
  Future<String> generateAgentCommitMessage(
    AgentCommitRequest request,
  ) async {
    final contents = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{
            'text': getAgentCommitPrompt(
              request.language,
              prefix: request.prefix,
              withEmoji: request.withEmoji,
              additionalContext: request.additionalContext,
            ),
          },
        ],
      },
    ];

    var toolCallCount = 0;
    var toolsEnabled = request.maxToolCalls > 0;

    while (true) {
      final turn = await _requestAgentTurn(
        contents,
        toolsEnabled: toolsEnabled,
        maxToolCalls: request.maxToolCalls,
      );
      final functionCalls = _extractGeminiFunctionCalls(turn.parts);

      if (functionCalls.isEmpty || !toolsEnabled) {
        final text = _extractGeminiText(turn.parts);
        if (text.isNotEmpty) return text;
        throw _emptyResponseError(
          turn.finishReason,
          functionCalls.isEmpty
              ? 'Gemini returned an empty commit message'
              : 'Gemini kept requesting tools after they were disabled and '
                  'returned no commit message',
        );
      }

      final functionResponses = <Map<String, dynamic>>[];
      for (final functionCall in functionCalls) {
        if (toolCallCount < request.maxToolCalls) {
          toolCallCount++;
          functionResponses.add(
            await _executeGeminiFunctionCall(request.tools, functionCall),
          );
        } else {
          functionResponses.add(
            _geminiFunctionResponse(
              functionCall['name']?.toString() ?? 'unknown_tool',
              agentToolBudgetSkippedResult,
            ),
          );
        }
      }

      contents
        ..add(<String, dynamic>{
          'role': 'model',
          'parts': turn.parts,
        })
        ..add(<String, dynamic>{
          'role': 'user',
          'parts': functionResponses,
        });

      // Out of tool calls: ask for the message instead of failing after
      // every call has already been paid for.
      if (toolCallCount >= request.maxToolCalls) toolsEnabled = false;
    }
  }

  Future<GeneratedText> _complete(String prompt, int maxTokens) async {
    final turn = await _generateContent(<String, dynamic>{
      'contents': <Map<String, dynamic>>[
        <String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{'text': prompt},
          ],
        },
      ],
      'generationConfig': <String, dynamic>{
        'maxOutputTokens': maxTokens,
      },
    });

    final text = _extractGeminiText(turn.parts);
    final truncated = _truncatedFinishReasons.contains(turn.finishReason);
    if (text.isEmpty && !truncated) {
      throw _emptyResponseError(turn.finishReason, 'Gemini returned no text');
    }
    return (text: text, truncated: truncated);
  }

  Future<_GeminiTurn> _requestAgentTurn(
    List<Map<String, dynamic>> contents, {
    required bool toolsEnabled,
    required int maxToolCalls,
  }) async {
    final String? mode;
    if (!toolsEnabled) {
      mode = 'NONE';
    } else if (contents.length == 1) {
      mode = 'ANY';
    } else {
      mode = null;
    }

    Future<_GeminiTurn> send(int maxTokens) {
      return _generateContent(<String, dynamic>{
        'contents': List<Map<String, dynamic>>.of(contents),
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'functionDeclarations': _geminiFunctionDeclarations(),
          },
        ],
        if (mode != null)
          'toolConfig': <String, dynamic>{
            'functionCallingConfig': <String, dynamic>{'mode': mode},
          },
        if (!toolsEnabled)
          'systemInstruction': <String, dynamic>{
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'text': agentToolBudgetExhaustedPrompt(maxToolCalls),
              },
            ],
          },
        'generationConfig': <String, dynamic>{
          'maxOutputTokens': maxTokens,
        },
      });
    }

    final turn = await send(agentTurnMaxTokens);
    if (!_truncatedFinishReasons.contains(turn.finishReason)) return turn;

    // Cut off mid-message or mid-call: ask again with more room.
    final retry = await send(truncationRetryMaxTokens);
    if (_truncatedFinishReasons.contains(retry.finishReason) &&
        _extractGeminiFunctionCalls(retry.parts).isEmpty) {
      throw ResponseTruncatedException(
        message: 'Gemini stopped at the $truncationRetryMaxTokens-token output '
            'limit before finishing the commit message.',
      );
    }
    return retry;
  }

  Future<_GeminiTurn> _generateContent(Map<String, dynamic> body) async {
    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        _endpoint,
        options: Options(
          headers: <String, String>{
            'Content-Type': 'application/json',
            // Sent as a header so the key never appears in URLs or logs.
            if (apiKey != null && apiKey!.isNotEmpty) 'x-goog-api-key': apiKey!,
          },
        ),
        data: body,
      );

      if (response.statusCode != 200) {
        throw ServerException(
          message: 'Unexpected response from Gemini API',
          statusCode: response.statusCode ?? 500,
        );
      }

      return _parseGeminiCandidate(response.data);
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('gemini', e);
    }
  }

  ApiException _emptyResponseError(String? finishReason, String message) {
    if (finishReason == null || _normalFinishReasons.contains(finishReason)) {
      return InvalidResponseException(message: '$message.');
    }
    return InvalidResponseException(
      message: '$message (finishReason: $finishReason).',
      errorType: finishReason,
    );
  }

  List<Map<String, dynamic>> _geminiFunctionDeclarations() {
    return GitAgentTools.openAiToolDefinitions.map((tool) {
      final function = tool['function'] as Map<String, dynamic>;
      return <String, dynamic>{
        'name': function['name'],
        'description': function['description'],
        'parameters': _geminiSchema(function['parameters']),
      };
    }).toList();
  }

  Map<String, dynamic> _geminiSchema(Object? value) {
    if (value is! Map) return <String, dynamic>{};
    final schema = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (key == 'additionalProperties') continue;
      final child = entry.value;
      schema[key] = switch (child) {
        Map() => _geminiSchema(child),
        List() => child
            .map((item) => item is Map ? _geminiSchema(item) : item)
            .toList(),
        _ => child,
      };
    }
    return schema;
  }

  _GeminiTurn _parseGeminiCandidate(Map<String, dynamic>? data) {
    final candidates = data?['candidates'];
    if (candidates is! List<dynamic> || candidates.isEmpty) {
      final feedback = data?['promptFeedback'];
      final blockReason =
          feedback is Map<dynamic, dynamic> ? feedback['blockReason'] : null;
      throw InvalidResponseException(
        message: blockReason != null
            ? 'Gemini blocked the prompt (blockReason: $blockReason).'
            : 'Gemini response did not include any candidates.',
        errorType: blockReason?.toString(),
      );
    }

    final firstCandidate = candidates.first;
    if (firstCandidate is! Map<dynamic, dynamic>) {
      throw const InvalidResponseException(
        message: 'Gemini response candidate had an unexpected shape.',
      );
    }

    // A candidate cut off by the token limit can come back without parts.
    final content = firstCandidate['content'];
    final rawParts = content is Map<dynamic, dynamic> ? content['parts'] : null;
    final parts = rawParts is List<dynamic>
        ? rawParts
            .whereType<Map<dynamic, dynamic>>()
            .map(Map<String, dynamic>.from)
            .toList()
        : <Map<String, dynamic>>[];

    return (
      parts: parts,
      finishReason: firstCandidate['finishReason']?.toString(),
    );
  }

  List<Map<String, dynamic>> _extractGeminiFunctionCalls(
    List<Map<String, dynamic>> parts,
  ) {
    return parts
        .map((part) => part['functionCall'])
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  String _extractGeminiText(List<Map<String, dynamic>> parts) {
    return parts
        .where((part) => part['thought'] != true)
        .map((part) => part['text'])
        .whereType<String>()
        .where((text) => text.trim().isNotEmpty)
        .join('\n')
        .trim();
  }

  Future<Map<String, dynamic>> _executeGeminiFunctionCall(
    GitAgentTools tools,
    Map<String, dynamic> functionCall,
  ) async {
    final name = functionCall['name'];
    if (name is! String || name.isEmpty) {
      return _geminiFunctionResponse(
        'unknown_tool',
        'ERROR: Function call did not include a name.',
      );
    }

    try {
      final output = await tools.execute(
        name,
        _decodeGeminiArguments(functionCall['args']),
      );
      return _geminiFunctionResponse(name, output);
    } on Object catch (error) {
      return _geminiFunctionResponse(name, 'ERROR: $error');
    }
  }

  Map<String, dynamic> _geminiFunctionResponse(String name, String output) {
    return <String, dynamic>{
      'functionResponse': <String, dynamic>{
        'name': name,
        'response': <String, dynamic>{
          'result': output,
        },
      },
    };
  }

  Map<String, dynamic> _decodeGeminiArguments(Object? args) {
    if (args is Map<String, dynamic>) return args;
    if (args is Map<dynamic, dynamic>) return Map<String, dynamic>.from(args);
    return <String, dynamic>{};
  }
}

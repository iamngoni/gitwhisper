//
//  gitwhisper
//  ollama_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/07/05.
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

class OllamaGenerator extends CommitGenerator implements AgentCommitGenerator {
  OllamaGenerator(this.baseUrl, super.apiKey, {super.variant});

  final String baseUrl;

  /// How long to wait for a response. Local models can take minutes to load
  /// and generate, far longer than hosted APIs.
  static const Duration receiveTimeout = Duration(minutes: 30);

  @override
  String get modelName => 'ollama';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  String get _baseUrl => baseUrl.replaceFirst(RegExp(r'/+$'), '');

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

    return requestCommitMessage('Ollama', (limit) => _generate(prompt, limit));
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    final prompt = getAnalysisPrompt(diff, language);

    return requestAnalysis('Ollama', (limit) => _generate(prompt, limit));
  }

  @override
  Future<String> generateAgentCommitMessage(
    AgentCommitRequest request,
  ) async {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': getAgentCommitPrompt(
          request.language,
          prefix: request.prefix,
          withEmoji: request.withEmoji,
          additionalContext: request.additionalContext,
        ),
      },
    ];

    var toolCallCount = 0;
    var toolsEnabled = request.maxToolCalls > 0;

    while (true) {
      final data = await _post('/api/chat', <String, dynamic>{
        'model': actualVariant,
        'messages': List<Map<String, dynamic>>.of(messages),
        // Leaving the tools out is how Ollama disables them.
        if (toolsEnabled) 'tools': GitAgentTools.openAiToolDefinitions,
        'stream': false,
      });

      final message = _extractOllamaMessage(data);
      final toolCalls = _extractOllamaToolCalls(message);

      if (toolCalls.isEmpty || !toolsEnabled) {
        final text = (message['content'] ?? '').toString().trim();
        if (_isTruncated(data)) {
          throw const ResponseTruncatedException(
            message: 'Ollama stopped at its output limit before finishing '
                'the commit message.',
          );
        }
        if (text.isNotEmpty) return text;
        throw InvalidResponseException(
          message: toolCalls.isEmpty
              ? 'Ollama returned an empty commit message.'
              : 'Ollama kept requesting tools after they were disabled and '
                  'returned no commit message.',
        );
      }

      messages.add(message);
      for (final toolCall in toolCalls) {
        final rawFunction = toolCall['function'];
        final functionName = rawFunction is Map<dynamic, dynamic>
            ? rawFunction['name']?.toString()
            : null;
        final withinBudget = toolCallCount < request.maxToolCalls;
        if (withinBudget) toolCallCount++;
        messages.add(<String, dynamic>{
          'role': 'tool',
          if (functionName != null && functionName.isNotEmpty)
            'name': functionName,
          'content': withinBudget
              ? await OpenAiCompatibleAgentRunner.executeToolCall(
                  request.tools,
                  toolCall,
                )
              : agentToolBudgetSkippedResult,
        });
      }

      if (toolCallCount >= request.maxToolCalls) {
        // Out of tool calls: ask for the message instead of failing after
        // every call has already run.
        toolsEnabled = false;
        messages.add(<String, dynamic>{
          'role': 'user',
          'content': agentToolBudgetExhaustedPrompt(request.maxToolCalls),
        });
      }
    }
  }

  Future<GeneratedText> _generate(String prompt, int maxTokens) async {
    final data = await _post('/api/generate', <String, dynamic>{
      'model': actualVariant,
      'prompt': prompt,
      'stream': false,
      'options': <String, dynamic>{
        // Ollama ignores OpenAI's max_tokens; num_predict is its limit.
        'num_predict': maxTokens,
      },
    });

    final response = data?['response'];
    if (response is! String) {
      throw const InvalidResponseException(
        message: 'Ollama response did not include generated text.',
      );
    }
    return (text: response, truncated: _isTruncated(data));
  }

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        '$_baseUrl$path',
        options: Options(
          headers: <String, String>{
            'Content-Type': 'application/json',
          },
          receiveTimeout: receiveTimeout,
        ),
        data: body,
      );

      if (response.statusCode != 200) {
        throw ServerException(
          message: 'Unexpected response from Ollama API',
          statusCode: response.statusCode ?? 500,
        );
      }

      return response.data;
    } on DioException catch (e) {
      // Keeps Ollama's own text, e.g. "<model> does not support tools".
      throw ErrorParser.parseProviderError('ollama', e);
    }
  }

  bool _isTruncated(Map<String, dynamic>? data) =>
      data?['done_reason'] == 'length';

  Map<String, dynamic> _extractOllamaMessage(Map<String, dynamic>? data) {
    final message = data?['message'];
    if (message is! Map<dynamic, dynamic>) {
      throw const InvalidResponseException(
        message: 'Ollama response did not include a message.',
      );
    }

    return Map<String, dynamic>.from(message);
  }

  List<Map<String, dynamic>> _extractOllamaToolCalls(
    Map<String, dynamic> message,
  ) {
    final rawToolCalls = message['tool_calls'];
    if (rawToolCalls is! List<dynamic>) return <Map<String, dynamic>>[];

    return rawToolCalls
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }
}

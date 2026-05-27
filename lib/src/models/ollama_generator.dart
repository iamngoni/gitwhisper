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

  @override
  String get modelName => 'ollama';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) async {
    final prompt = getCommitPrompt(
      diff,
      language,
      prefix: prefix,
      withEmoji: withEmoji,
    );

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        '$baseUrl/api/generate',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': actualVariant,
          'prompt': prompt,
          'stream': false,
          'max_tokens': maxTokens,
        },
      );

      if (response.statusCode == 200) {
        return response.data!['response'].toString().trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from OpenAI API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('ollama', e);
    }
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        '$baseUrl/api/generate',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': actualVariant,
          'prompt': prompt,
          'stream': false,
          'max_tokens': maxTokens,
        },
      );

      if (response.statusCode == 200) {
        return response.data!['response'].toString().trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from OpenAI API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('ollama', e);
    }
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
        ),
      },
    ];

    var toolCallCount = 0;

    while (true) {
      try {
        final Response<Map<String, dynamic>> response = await $dio.post(
          '$baseUrl/api/chat',
          options: Options(
            headers: <String, String>{
              'Content-Type': 'application/json',
            },
          ),
          data: <String, dynamic>{
            'model': actualVariant,
            'messages': messages,
            'tools': GitAgentTools.openAiToolDefinitions,
            'stream': false,
          },
        );

        if (response.statusCode != 200) {
          throw ServerException(
            message: 'Unexpected response from Ollama API',
            statusCode: response.statusCode ?? 500,
          );
        }

        final message = _extractOllamaMessage(response.data);
        final toolCalls = _extractOllamaToolCalls(message);

        if (toolCalls.isEmpty) {
          return (message['content'] ?? '').toString().trim();
        }

        toolCallCount += toolCalls.length;
        if (toolCallCount > request.maxToolCalls) {
          throw StateError(
            'Agent mode exceeded ${request.maxToolCalls} tool calls.',
          );
        }

        messages.add(message);
        for (final toolCall in toolCalls) {
          final rawFunction = toolCall['function'];
          final functionName = rawFunction is Map<dynamic, dynamic>
              ? rawFunction['name']?.toString()
              : null;
          final output = await OpenAiCompatibleAgentRunner.executeToolCall(
            request.tools,
            toolCall,
          );
          messages.add(<String, dynamic>{
            'role': 'tool',
            if (functionName != null && functionName.isNotEmpty)
              'name': functionName,
            'content': output,
          });
        }
      } on DioException catch (e) {
        throw ErrorParser.parseProviderError('ollama', e);
      }
    }
  }

  Map<String, dynamic> _extractOllamaMessage(Map<String, dynamic>? data) {
    final message = data?['message'];
    if (message is! Map<dynamic, dynamic>) {
      throw const FormatException('Ollama response did not include a message.');
    }

    return Map<String, dynamic>.from(message);
  }

  List<Map<String, dynamic>> _extractOllamaToolCalls(
    Map<String, dynamic> message,
  ) {
    final rawToolCalls = message['tool_calls'];
    if (rawToolCalls is! List<dynamic>) return <Map<String, dynamic>>[];

    final toolCalls = <Map<String, dynamic>>[];
    for (final rawToolCall in rawToolCalls) {
      if (rawToolCall is Map<dynamic, dynamic>) {
        toolCalls.add(Map<String, dynamic>.from(rawToolCall));
      }
    }

    return toolCalls;
  }
}

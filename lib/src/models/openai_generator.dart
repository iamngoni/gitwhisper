//
//  gitwhisper
//  openai_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:convert';

import 'package:dio/dio.dart';

import '../agent/agent_commit_generator.dart';
import '../agent/git_agent_tools.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

class OpenAIGenerator extends CommitGenerator implements AgentCommitGenerator {
  OpenAIGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'openai';

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
        'https://api.openai.com/v1/chat/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
        ),
        data: {
          'model': actualVariant,
          'store': true,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'max_completion_tokens': maxTokens,
        },
      );

      if (response.statusCode == 200) {
        return response.data!['choices'][0]['message']['content']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from OpenAI API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('openai', e);
    }
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        'https://api.openai.com/v1/chat/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
        ),
        data: {
          'model': actualVariant,
          'store': true,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'max_completion_tokens': maxAnalysisTokens,
        },
      );

      if (response.statusCode == 200) {
        return response.data!['choices'][0]['message']['content']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from OpenAI API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('openai', e);
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
          'https://api.openai.com/v1/chat/completions',
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
          ),
          data: {
            'model': actualVariant,
            'store': true,
            'messages': messages,
            'tools': GitAgentTools.openAiToolDefinitions,
            'tool_choice': 'auto',
            'max_completion_tokens': 1000,
          },
        );

        if (response.statusCode != 200) {
          throw ServerException(
            message: 'Unexpected response from OpenAI API',
            statusCode: response.statusCode ?? 500,
          );
        }

        final message = _extractOpenAiMessage(response.data);
        final toolCalls = _extractOpenAiToolCalls(message);

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
          final output = await _executeOpenAiToolCall(request.tools, toolCall);
          messages.add(<String, dynamic>{
            'role': 'tool',
            'tool_call_id': toolCall['id'],
            'content': output,
          });
        }
      } on DioException catch (e) {
        throw ErrorParser.parseProviderError('openai', e);
      }
    }
  }

  Map<String, dynamic> _extractOpenAiMessage(Map<String, dynamic>? data) {
    final choices = data?['choices'];
    if (choices is! List<dynamic> || choices.isEmpty) {
      throw const FormatException('OpenAI response did not include choices.');
    }

    final firstChoice = choices.first;
    if (firstChoice is! Map<dynamic, dynamic>) {
      throw const FormatException('OpenAI choice had an unexpected shape.');
    }

    final message = firstChoice['message'];
    if (message is! Map<dynamic, dynamic>) {
      throw const FormatException('OpenAI choice did not include a message.');
    }

    return Map<String, dynamic>.from(message);
  }

  List<Map<String, dynamic>> _extractOpenAiToolCalls(
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

  Future<String> _executeOpenAiToolCall(
    GitAgentTools tools,
    Map<String, dynamic> toolCall,
  ) async {
    try {
      final rawFunction = toolCall['function'];
      if (rawFunction is! Map<dynamic, dynamic>) {
        throw const FormatException('Tool call did not include a function.');
      }

      final function = Map<String, dynamic>.from(rawFunction);
      final name = function['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('Tool call did not include a name.');
      }

      return await tools.execute(
        name,
        _decodeToolArguments(function['arguments']),
      );
    } catch (error) {
      return 'ERROR: $error';
    }
  }

  Map<String, dynamic> _decodeToolArguments(Object? arguments) {
    if (arguments is! String || arguments.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(arguments);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(decoded);
    }

    return <String, dynamic>{};
  }
}

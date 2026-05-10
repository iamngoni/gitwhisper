//
//  gitwhisper
//  claude_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../agent/agent_commit_generator.dart';
import '../agent/git_agent_tools.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

class ClaudeGenerator extends CommitGenerator implements AgentCommitGenerator {
  ClaudeGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'claude';

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
        'https://api.anthropic.com/v1/messages',
        options: Options(
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
        ),
        data: {
          'model': actualVariant,
          'max_tokens': maxTokens,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            },
          ],
        },
      );

      if (response.statusCode == 200) {
        return response.data!['content'][0]['text'].toString().trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Claude API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('claude', e);
    }
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        'https://api.anthropic.com/v1/messages',
        options: Options(
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
        ),
        data: {
          'model': actualVariant,
          'max_tokens': maxAnalysisTokens,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            },
          ],
        },
      );

      if (response.statusCode == 200) {
        return response.data!['content'][0]['text'].toString().trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Claude API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('claude', e);
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
          'https://api.anthropic.com/v1/messages',
          options: Options(
            headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
          ),
          data: {
            'model': actualVariant,
            'max_tokens': 1000,
            'messages': messages,
            'tools': GitAgentTools.claudeToolDefinitions,
          },
        );

        if (response.statusCode != 200) {
          throw ServerException(
            message: 'Unexpected response from Claude API',
            statusCode: response.statusCode ?? 500,
          );
        }

        final content = _extractClaudeContent(response.data);
        final toolUses = _extractClaudeToolUses(content);

        if (toolUses.isEmpty) {
          return _extractClaudeText(content).trim();
        }

        toolCallCount += toolUses.length;
        if (toolCallCount > request.maxToolCalls) {
          throw StateError(
            'Agent mode exceeded ${request.maxToolCalls} tool calls.',
          );
        }

        messages.add(<String, dynamic>{
          'role': 'assistant',
          'content': content,
        });

        final toolResults = <Map<String, dynamic>>[];
        for (final toolUse in toolUses) {
          toolResults.add(
            await _executeClaudeToolUse(request.tools, toolUse),
          );
        }

        messages.add(<String, dynamic>{
          'role': 'user',
          'content': toolResults,
        });
      } on DioException catch (e) {
        throw ErrorParser.parseProviderError('claude', e);
      }
    }
  }

  List<Map<String, dynamic>> _extractClaudeContent(
    Map<String, dynamic>? data,
  ) {
    final rawContent = data?['content'];
    if (rawContent is! List<dynamic>) {
      throw const FormatException('Claude response did not include content.');
    }

    final content = <Map<String, dynamic>>[];
    for (final rawBlock in rawContent) {
      if (rawBlock is Map<dynamic, dynamic>) {
        content.add(Map<String, dynamic>.from(rawBlock));
      }
    }

    return content;
  }

  List<Map<String, dynamic>> _extractClaudeToolUses(
    List<Map<String, dynamic>> content,
  ) {
    return content
        .where((block) => block['type'] == 'tool_use')
        .map(Map<String, dynamic>.from)
        .toList();
  }

  String _extractClaudeText(List<Map<String, dynamic>> content) {
    return content
        .where((block) => block['type'] == 'text')
        .map((block) => (block['text'] ?? '').toString())
        .where((text) => text.trim().isNotEmpty)
        .join('\n')
        .trim();
  }

  Future<Map<String, dynamic>> _executeClaudeToolUse(
    GitAgentTools tools,
    Map<String, dynamic> toolUse,
  ) async {
    final id = toolUse['id']?.toString() ?? '';

    try {
      final name = toolUse['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('Tool use did not include a name.');
      }

      final output = await tools.execute(
        name,
        _decodeClaudeToolInput(toolUse['input']),
      );

      return <String, dynamic>{
        'type': 'tool_result',
        'tool_use_id': id,
        'content': output,
      };
    } catch (error) {
      return <String, dynamic>{
        'type': 'tool_result',
        'tool_use_id': id,
        'content': 'ERROR: $error',
        'is_error': true,
      };
    }
  }

  Map<String, dynamic> _decodeClaudeToolInput(Object? input) {
    if (input is Map<String, dynamic>) return input;
    if (input is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(input);
    }

    return <String, dynamic>{};
  }
}

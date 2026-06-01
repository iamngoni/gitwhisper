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
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

class GeminiGenerator extends CommitGenerator implements AgentCommitGenerator {
  GeminiGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'gemini';

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
        'https://generativelanguage.googleapis.com/v1beta/models/$actualVariant:generateContent?key=$apiKey',
        data: {
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            }
          ],
          'generationConfig': {
            'maxOutputTokens': maxTokens,
          },
        },
      );

      if (response.statusCode == 200) {
        return response.data!['candidates'][0]['content']['parts'][0]['text']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Gemini API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('gemini', e);
    }
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        'https://generativelanguage.googleapis.com/v1beta/models/$actualVariant:generateContent?key=$apiKey',
        data: {
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            }
          ],
          'generationConfig': {
            'maxOutputTokens': maxAnalysisTokens,
          },
        },
      );

      if (response.statusCode == 200) {
        return response.data!['candidates'][0]['content']['parts'][0]['text']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Gemini API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('gemini', e);
    }
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
            ),
          },
        ],
      },
    ];

    var toolCallCount = 0;

    while (true) {
      try {
        final Response<Map<String, dynamic>> response = await $dio.post(
          'https://generativelanguage.googleapis.com/v1beta/models/$actualVariant:generateContent?key=$apiKey',
          data: <String, dynamic>{
            'contents': contents,
            'tools': <Map<String, dynamic>>[
              <String, dynamic>{
                'functionDeclarations': _geminiFunctionDeclarations(),
              },
            ],
            if (contents.length == 1)
              'toolConfig': <String, dynamic>{
                'functionCallingConfig': <String, dynamic>{
                  'mode': 'ANY',
                },
              },
            'generationConfig': <String, dynamic>{
              'maxOutputTokens': 1000,
            },
          },
        );

        if (response.statusCode != 200) {
          throw ServerException(
            message: 'Unexpected response from Gemini API',
            statusCode: response.statusCode ?? 500,
          );
        }

        final parts = _extractGeminiParts(response.data);
        final functionCalls = _extractGeminiFunctionCalls(parts);

        if (functionCalls.isEmpty) {
          return _extractGeminiText(parts).trim();
        }

        toolCallCount += functionCalls.length;
        if (toolCallCount > request.maxToolCalls) {
          throw StateError(
            'Agent mode exceeded ${request.maxToolCalls} tool calls.',
          );
        }

        contents.add(<String, dynamic>{
          'role': 'model',
          'parts': parts,
        });
        contents.add(<String, dynamic>{
          'role': 'user',
          'parts': <Map<String, dynamic>>[
            for (final functionCall in functionCalls)
              await _executeGeminiFunctionCall(request.tools, functionCall),
          ],
        });
      } on DioException catch (e) {
        throw ErrorParser.parseProviderError('gemini', e);
      }
    }
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

  List<Map<String, dynamic>> _extractGeminiParts(
    Map<String, dynamic>? data,
  ) {
    final candidates = data?['candidates'];
    if (candidates is! List<dynamic> || candidates.isEmpty) {
      throw const FormatException(
          'Gemini response did not include candidates.');
    }

    final firstCandidate = candidates.first;
    if (firstCandidate is! Map<dynamic, dynamic>) {
      throw const FormatException('Gemini candidate had an unexpected shape.');
    }

    final content = firstCandidate['content'];
    if (content is! Map<dynamic, dynamic>) {
      throw const FormatException('Gemini candidate did not include content.');
    }

    final parts = content['parts'];
    if (parts is! List<dynamic>) {
      throw const FormatException('Gemini content did not include parts.');
    }

    return parts
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
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

//
//  gitwhisper
//  claude_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

class ClaudeGenerator extends CommitGenerator {
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
  }) async {
    final prompt = getCommitPrompt(diff, language, prefix: prefix);

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
}

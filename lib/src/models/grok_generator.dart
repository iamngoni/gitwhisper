//
//  gitwhisper
//  grok_generator.dart
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

class GrokGenerator extends CommitGenerator {
  GrokGenerator(super.apiKey, {super.variant});

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  String get modelName => 'grok';

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
        'https://api.x.ai/v1/chat/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
        ),
        data: {
          'model': actualVariant,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'max_tokens': maxTokens,
        },
      );

      if (response.statusCode == 200) {
        // Adjust the parsing logic based on actual Grok API response structure
        return response.data!['choices'][0]['message']['content']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Grok API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('grok', e);
    }
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        'https://api.x.ai/v1/chat/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
        ),
        data: {
          'model': actualVariant,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'max_tokens': maxAnalysisTokens,
        },
      );

      if (response.statusCode == 200) {
        // Adjust the parsing logic based on actual Grok API response structure
        return response.data!['choices'][0]['message']['content']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Grok API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('grok', e);
    }
  }
}

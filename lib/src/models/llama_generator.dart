//
//  gitwhisper
//  llama_generator.dart
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

class LlamaGenerator extends CommitGenerator {
  LlamaGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'llama';

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
        'https://api.llama.api/v1/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
        ),
        data: {
          'model': actualVariant,
          'prompt': prompt,
          'max_tokens': maxTokens,
        },
      );

      if (response.statusCode == 200) {
        // Adjust the parsing logic based on actual Llama API response structure
        return response.data!['choices'][0]['text'].toString().trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Llama API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('llama', e);
    }
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        'https://api.llama.api/v1/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
        ),
        data: {
          'model': actualVariant,
          'prompt': prompt,
          'max_tokens': maxAnalysisTokens,
        },
      );

      if (response.statusCode == 200) {
        // Adjust the parsing logic based on actual Llama API response structure
        return response.data!['choices'][0]['text'].toString().trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from Llama API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('llama', e);
    }
  }
}

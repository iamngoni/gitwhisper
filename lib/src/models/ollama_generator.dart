//
//  gitwhisper
//  ollama_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/07/05.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

class OllamaGenerator extends CommitGenerator {
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
  }) async {
    final prompt = getCommitPrompt(diff, language, prefix: prefix);

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
}

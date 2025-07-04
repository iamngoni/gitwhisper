//
//  gitwhisper
//  gemini_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'model_variants.dart';

class GeminiGenerator extends CommitGenerator {
  GeminiGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'gemini';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  Future<String> generateCommitMessage(String diff, {String? prefix}) async {
    final prompt = getCommitPrompt(diff, prefix: prefix);

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
  Future<String> analyzeChanges(String diff) async {
    final prompt = getAnalysisPrompt(diff);

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
}

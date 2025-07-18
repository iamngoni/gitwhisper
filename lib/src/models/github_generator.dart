//
//  gitwhisper
//  github_generator.dart
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

class GithubGenerator extends CommitGenerator {
  GithubGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'github';

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
        'https://models.inference.ai.azure.com/chat/completions',
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
          'max_tokens': maxTokens,
        },
      );

      if (response.statusCode == 200) {
        return response.data!['choices'][0]['message']['content']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from GitHub API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('github', e);
    }
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        'https://models.inference.ai.azure.com/chat/completions',
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
          'max_tokens': maxAnalysisTokens,
        },
      );

      if (response.statusCode == 200) {
        return response.data!['choices'][0]['message']['content']
            .toString()
            .trim();
      } else {
        throw ServerException(
          message: 'Unexpected response from GitHub API',
          statusCode: response.statusCode ?? 500,
        );
      }
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('github', e);
    }
  }
}

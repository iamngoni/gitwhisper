//
//  gitwhisper
//  openai_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../commit_utils.dart';
import '../constants.dart';
import 'commit_generator.dart';
import 'model_variants.dart';

class DeepseekGenerator extends CommitGenerator {
  DeepseekGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'deepseek';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  Future<String> generateCommitMessage(String diff, {String? prefix}) async {
    final prompt = getCommitPrompt(diff, prefix: prefix);

    final Response<Map<String, dynamic>> response = await $dio.post(
      'https://api.deepseek.com/v1/chat/completions',
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
      throw Exception(
        'API request failed with status: ${response.statusCode}, data: ${response.data}',
      );
    }
  }

  @override
  Future<String> analyzeChanges(String diff) async {
    final prompt = getAnalysisPrompt(diff);

    final Response<Map<String, dynamic>> response = await $dio.post(
      'https://api.deepseek.com/v1/chat/completions',
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
      throw Exception(
        'API request failed with status: ${response.statusCode}, data: ${response.data}',
      );
    }
  }
}

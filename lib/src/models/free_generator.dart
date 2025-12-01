//
//  gitwhisper
//  free_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/12/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../commit_utils.dart';
import '../constants.dart';
import 'commit_generator.dart';
import 'language.dart';

/// A free generator that uses LLM7.io's free API.
/// No API key required - completely free to use.
///
/// Anonymous tier limits:
/// - 8k chars per request
/// - 60 requests per hour
/// - 10 requests per minute
/// - 1 request per second
class FreeGenerator extends CommitGenerator {
  FreeGenerator() : super(null);

  static const String _baseUrl = 'https://api.llm7.io/v1';

  @override
  String get modelName => 'free';

  @override
  String get defaultVariant => 'default';

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

    final Response<Map<String, dynamic>> response = await $dio.post(
      '$_baseUrl/chat/completions',
      options: Options(
        headers: {
          'Content-Type': 'application/json',
        },
      ),
      data: {
        'model': 'default',
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
  Future<String> analyzeChanges(String diff, Language language) async {
    final prompt = getAnalysisPrompt(diff, language);

    final Response<Map<String, dynamic>> response = await $dio.post(
      '$_baseUrl/chat/completions',
      options: Options(
        headers: {
          'Content-Type': 'application/json',
        },
      ),
      data: {
        'model': 'default',
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

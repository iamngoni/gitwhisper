//
//  gitwhisper
//  gemini_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../constants.dart';
import 'commit_generator.dart';

class GeminiGenerator extends CommitGenerator {
  GeminiGenerator(super.apiKey);

  @override
  String get modelName => 'gemini';

  @override
  Future<String> generateCommitMessage(String diff) async {
    $logger.progress(
      'Gemini :: generateCommitMessage -> generating commit message from diff',
    );

    final prompt = '''
    You are an assistant that generates git commit messages. 
    Based on the following diff of staged changes, generate a concise and descriptive commit message.
    Follow the conventional commit format: <type>(<scope>): <description>
    
    Common types: feat, fix, docs, style, refactor, test, chore
    
    Here's the diff:
    $diff
    
    Generate only the commit message, nothing else.
    ''';

    final Response<Map<String, dynamic>> response = await $dio.post(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=$apiKey',
      data: {
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          }
        ],
        'generationConfig': {
          'maxOutputTokens': 300,
        },
      },
    );

    if (response.statusCode == 200) {
      return response.data!['candidates'][0]['content']['parts'][0]['text']
          .toString()
          .trim();
    } else {
      throw Exception(
        'API request failed with status: ${response.statusCode}, data: ${response.data}',
      );
    }
  }
}

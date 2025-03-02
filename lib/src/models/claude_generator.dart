//
//  gitwhisper
//  claude_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../constants.dart';
import 'commit_generator.dart';
import 'model_variants.dart';

class ClaudeGenerator extends CommitGenerator {
  ClaudeGenerator(super.apiKey, {super.variant});

  @override
  String get modelName => 'claude';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  Future<String> generateCommitMessage(String diff) async {
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
      'https://api.anthropic.com/v1/messages',
      options: Options(
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
      ),
      data: {
        'model': actualVariant,
        'max_tokens': 300,
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
      throw Exception(
        'API request failed with status: ${response.statusCode}, data: ${response.data}',
      );
    }
  }
}

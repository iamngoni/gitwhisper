//
//  gitwhisper
//  commit_generator_factory.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'claude_generator.dart';
import 'commit_generator.dart';
import 'gemini_generator.dart';
import 'grok_generator.dart';
import 'llama_generator.dart';
import 'openai_generator.dart';

/// Factory for creating appropriate commit generators
class CommitGeneratorFactory {
  static CommitGenerator create(String model, String apiKey) {
    switch (model.toLowerCase()) {
      case 'claude':
        return ClaudeGenerator(apiKey);
      case 'openai':
        return OpenAIGenerator(apiKey);
      case 'gemini':
        return GeminiGenerator(apiKey);
      case 'grok':
        return GrokGenerator(apiKey);
      case 'llama':
        return LlamaGenerator(apiKey);
      default:
        throw ArgumentError('Unsupported model: $model');
    }
  }
}

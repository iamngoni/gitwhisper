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
  static CommitGenerator create(
    String model,
    String apiKey, {
    String? variant,
  }) {
    switch (model.toLowerCase()) {
      case 'claude':
        return ClaudeGenerator(
          apiKey,
          variant: variant,
        );
      case 'openai':
        return OpenAIGenerator(
          apiKey,
          variant: variant,
        );
      case 'gemini':
        return GeminiGenerator(
          apiKey,
          variant: variant,
        );
      case 'grok':
        return GrokGenerator(
          apiKey,
          variant: variant,
        );
      case 'llama':
        return LlamaGenerator(
          apiKey,
          variant: variant,
        );
      default:
        throw ArgumentError('Unsupported model: $model');
    }
  }
}

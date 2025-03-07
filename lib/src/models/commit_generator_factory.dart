//
//  gitwhisper
//  commit_generator_factory.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'claude_generator.dart';
import 'commit_generator.dart';
import 'deepseek_generator.dart';
import 'gemini_generator.dart';
import 'github_generator.dart';
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
    return switch (model.toLowerCase()) {
      'claude' => ClaudeGenerator(
          apiKey,
          variant: variant,
        ),
      'openai' => OpenAIGenerator(
          apiKey,
          variant: variant,
        ),
      'gemini' => GeminiGenerator(
          apiKey,
          variant: variant,
        ),
      'grok' => GrokGenerator(
          apiKey,
          variant: variant,
        ),
      'llama' => LlamaGenerator(
          apiKey,
          variant: variant,
        ),
      'deepseek' => DeepseekGenerator(
          apiKey,
          variant: variant,
        ),
      'github' => GithubGenerator(
          apiKey,
          variant: variant,
        ),
      _ => throw ArgumentError('Unsupported model: $model'),
    };
  }
}

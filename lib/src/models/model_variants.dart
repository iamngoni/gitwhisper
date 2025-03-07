//
//  gitwhisper
//  model_variants.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/02.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

/// Default model variants for each AI model provider
class ModelVariants {
  /// Default OpenAI model variant
  static const String openaiDefault = 'gpt-4o';

  /// Default Claude model variant
  static const String claudeDefault = 'claude-3-5-sonnet-20240620';

  /// Default Gemini model variant
  static const String geminiDefault = 'gemini-1.0-pro';

  /// Default Grok model variant
  static const String grokDefault = 'grok-2-latest';

  /// Default Llama model variant
  static const String llamaDefault = 'llama-3-70b-instruct';

  /// Default Deekseek model variant
  static const String deepseekDefault = 'deepseek-chat';

  /// Default Github model variant
  static const String githubDefault = 'gpt-4o';

  /// Get the default model variant for a given model
  static String getDefault(String model) {
    return switch (model.toLowerCase()) {
      'openai' => openaiDefault,
      'claude' => claudeDefault,
      'gemini' => geminiDefault,
      'grok' => grokDefault,
      'llama' => llamaDefault,
      'deepseek' => deepseekDefault,
      'github' => githubDefault,
      _ => throw ArgumentError('Unknown model: $model'),
    };
  }
}

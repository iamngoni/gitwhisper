//
//  gitwhisper
//  model_variants.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/02.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

/// Default model variants for each AI model provider
class ModelVariants {
  /// Default OpenAI model variant.
  ///
  /// GPT-6 Sol and Luna can't call tools over Chat Completions with default
  /// settings, so agent mode needs a GPT-5.6 model there.
  static const String openaiDefault = 'gpt-5.6-terra';

  /// Default Claude model variant
  static const String claudeDefault = 'claude-sonnet-5-5';

  /// Default Claude Code model variant for the direct Anthropic harness.
  static const String claudeCodeDefault = 'claude-sonnet-5-5';

  /// Default Codex model variant for the direct Responses API harness.
  static const String codexDefault = 'gpt-5.5';

  /// Default Gemini model variant
  static const String geminiDefault = 'gemini-3.6-flash';

  /// Default Grok model variant
  static const String grokDefault = 'grok-4.3';

  /// Default model variant for the `llama` provider (Meta Model API)
  static const String llamaDefault = 'muse-spark-1.3';

  /// Default DeepSeek model variant
  static const String deepseekDefault = 'deepseek-flash';

  /// Default GitHub Models variant. GitHub retired the service on
  /// July 30, 2026.
  static const String githubDefault = 'gpt-4o';

  /// Default Ollama model variant
  static const String ollamaDefault = 'llama3.2:latest';

  /// Get the default model variant for a given model
  static String getDefault(String model) {
    return switch (model.toLowerCase()) {
      'openai' => openaiDefault,
      'claude' => claudeDefault,
      'claude-code' => claudeCodeDefault,
      'codex' => codexDefault,
      'gemini' => geminiDefault,
      'grok' => grokDefault,
      'llama' => llamaDefault,
      'deepseek' => deepseekDefault,
      'github' => githubDefault,
      'ollama' => ollamaDefault,
      _ => throw ArgumentError('Unknown model: $model'),
    };
  }
}

//
//  gitwhisper
//  llama_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'openai_compatible_generator.dart';

/// Generator for Meta's hosted model API.
///
/// Meta's documentation now covers the Meta Model API, which serves
/// OpenAI-compatible chat completions for its Muse models, in place of the
/// Llama API preview.
class LlamaGenerator extends OpenAiCompatibleGenerator {
  LlamaGenerator(super.apiKey, {super.variant})
      : super(
          provider: const OpenAiCompatibleProvider(
            name: 'llama',
            displayName: 'Meta Model API',
            endpoint: 'https://api.meta.ai/v1/chat/completions',
            maxTokensKey: 'max_completion_tokens',
            // Only `tool_choice: auto` is accepted; `required` and `none`
            // return HTTP 400.
            forceFirstToolCall: false,
            supportsToolChoiceNone: false,
          ),
        );
}

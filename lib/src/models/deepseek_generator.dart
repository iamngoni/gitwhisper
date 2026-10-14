//
//  gitwhisper
//  deepseek_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'openai_compatible_generator.dart';

class DeepseekGenerator extends OpenAiCompatibleGenerator {
  DeepseekGenerator(super.apiKey, {super.variant})
      : super(
          provider: const OpenAiCompatibleProvider(
            name: 'deepseek',
            displayName: 'DeepSeek',
            endpoint: 'https://api.deepseek.com/chat/completions',
            // DeepSeek models think by default, and thinking mode rejects a
            // required tool choice.
            forceFirstToolCall: false,
          ),
        );
}

//
//  gitwhisper
//  openai_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'openai_compatible_generator.dart';

class OpenAIGenerator extends OpenAiCompatibleGenerator {
  OpenAIGenerator(super.apiKey, {super.variant})
      : super(
          provider: const OpenAiCompatibleProvider(
            name: 'openai',
            displayName: 'OpenAI',
            endpoint: 'https://api.openai.com/v1/chat/completions',
            maxTokensKey: 'max_completion_tokens',
          ),
        );
}

//
//  gitwhisper
//  grok_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'openai_compatible_generator.dart';

class GrokGenerator extends OpenAiCompatibleGenerator {
  GrokGenerator(super.apiKey, {super.variant})
      : super(
          provider: const OpenAiCompatibleProvider(
            name: 'grok',
            displayName: 'Grok',
            endpoint: 'https://api.x.ai/v1/chat/completions',
          ),
        );
}

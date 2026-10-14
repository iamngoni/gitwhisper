//
//  gitwhisper
//  github_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import '../agent/agent_commit_generator.dart';
import '../exceptions/exceptions.dart';
import 'language.dart';
import 'openai_compatible_generator.dart';

/// Generator for GitHub Models, which GitHub retired on July 30, 2026.
///
/// Requests fail fast with a [ProviderRetiredException] instead of calling
/// an inference API that no longer serves requests.
class GithubGenerator extends OpenAiCompatibleGenerator {
  GithubGenerator(super.apiKey, {super.variant})
      : super(
          provider: const OpenAiCompatibleProvider(
            name: 'github',
            displayName: 'GitHub Models',
            endpoint: 'https://models.github.ai/inference/chat/completions',
          ),
        );

  static const ProviderRetiredException retiredError = ProviderRetiredException(
    message: 'GitHub Models was retired on July 30, 2026, and its inference '
        'API no longer accepts requests.',
  );

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) {
    return Future<String>.error(retiredError);
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    return Future<String>.error(retiredError);
  }

  @override
  Future<String> generateAgentCommitMessage(AgentCommitRequest request) {
    return Future<String>.error(retiredError);
  }
}

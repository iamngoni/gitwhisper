import 'package:dio/dio.dart';

import '../agent/agent_commit_generator.dart';
import '../agent/openai_compatible_agent_runner.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

/// Connection details for a provider that serves OpenAI-compatible chat
/// completions.
class OpenAiCompatibleProvider {
  const OpenAiCompatibleProvider({
    required this.name,
    required this.displayName,
    required this.endpoint,
    this.maxTokensKey = 'max_tokens',
    this.headers = const <String, String>{},
    this.forceFirstToolCall = true,
    this.supportsToolChoiceNone = true,
  });

  /// Model name used for defaults and error parsing, e.g. `grok`.
  final String name;

  /// Provider name shown in messages, e.g. `Grok`.
  final String displayName;

  /// Chat completions URL.
  final String endpoint;

  /// Request field that carries the output token limit.
  final String maxTokensKey;

  /// Extra headers sent with every request.
  final Map<String, String> headers;

  /// Whether agent mode may send `tool_choice: required` on its first
  /// request.
  final bool forceFirstToolCall;

  /// Whether the provider accepts `tool_choice: none`.
  final bool supportsToolChoiceNone;
}

/// Commit generator for any provider with an OpenAI-compatible chat
/// completions API. Providers differ only in their [provider] details.
class OpenAiCompatibleGenerator extends CommitGenerator
    implements AgentCommitGenerator {
  OpenAiCompatibleGenerator(
    super.apiKey, {
    required this.provider,
    super.variant,
  });

  final OpenAiCompatibleProvider provider;

  @override
  String get modelName => provider.name;

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) {
    final prompt = getCommitPrompt(
      diff,
      language,
      prefix: prefix,
      withEmoji: withEmoji,
    );

    return requestCommitMessage(
      provider.displayName,
      (limit) => _complete(prompt, limit),
    );
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    final prompt = getAnalysisPrompt(diff, language);

    return requestAnalysis(
      provider.displayName,
      (limit) => _complete(prompt, limit),
    );
  }

  @override
  Future<String> generateAgentCommitMessage(
    AgentCommitRequest request,
  ) {
    return OpenAiCompatibleAgentRunner(
      providerName: provider.name,
      displayName: provider.displayName,
      endpoint: provider.endpoint,
      model: actualVariant,
      apiKey: apiKey,
      maxTokensKey: provider.maxTokensKey,
      turnMaxTokens: agentTurnMaxTokens,
      retryMaxTokens: truncationRetryMaxTokens,
      headers: provider.headers,
      forceFirstToolCall: provider.forceFirstToolCall,
      supportsToolChoiceNone: provider.supportsToolChoiceNone,
    ).generate(request);
  }

  Future<GeneratedText> _complete(String prompt, int maxTokens) async {
    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        provider.endpoint,
        options: Options(
          headers: OpenAiCompatibleAgentRunner.requestHeaders(
            apiKey,
            provider.headers,
          ),
        ),
        data: <String, dynamic>{
          'model': actualVariant,
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': prompt},
          ],
          provider.maxTokensKey: maxTokens,
        },
      );

      if (response.statusCode != 200) {
        throw ServerException(
          message: 'Unexpected response from ${provider.displayName} API',
          statusCode: response.statusCode ?? 500,
        );
      }

      final choice = OpenAiChatChoice.fromResponse(
        response.data,
        provider: provider.displayName,
      );
      return (text: choice.content, truncated: choice.truncated);
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError(provider.name, e);
    }
  }
}

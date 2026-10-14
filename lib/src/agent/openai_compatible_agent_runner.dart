import 'dart:convert';

import 'package:dio/dio.dart';

import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'agent_commit_generator.dart';
import 'git_agent_tools.dart';

/// Tool result sent for calls requested after the agent tool budget ran out.
const String agentToolBudgetSkippedResult =
    'ERROR: Not run. The tool call budget for this commit is used up.';

/// Instruction sent with the final agent request, once the tool budget is
/// used up and tools are disabled.
String agentToolBudgetExhaustedPrompt(int maxToolCalls) =>
    'You have used all $maxToolCalls tool calls, so tools are now disabled. '
    'Using only what you have already inspected, reply with the final '
    'commit message(s) and nothing else.';

/// The first choice of an OpenAI-compatible chat completion.
class OpenAiChatChoice {
  const OpenAiChatChoice({required this.message, this.finishReason});

  /// Parses the first choice of a chat completion response body.
  ///
  /// Throws [InvalidResponseException] naming [provider] when the body has
  /// no usable message, or when the model refused to answer.
  factory OpenAiChatChoice.fromResponse(
    Map<String, dynamic>? data, {
    required String provider,
  }) {
    final choices = data?['choices'];
    if (choices is! List<dynamic> || choices.isEmpty) {
      throw InvalidResponseException(
        message: '$provider response did not include any choices.',
      );
    }

    final firstChoice = choices.first;
    if (firstChoice is! Map<dynamic, dynamic>) {
      throw InvalidResponseException(
        message: '$provider response choice had an unexpected shape.',
      );
    }

    final message = firstChoice['message'];
    if (message is! Map<dynamic, dynamic>) {
      throw InvalidResponseException(
        message: '$provider response choice did not include a message.',
      );
    }

    final finishReason = firstChoice['finish_reason'];
    final choice = OpenAiChatChoice(
      message: Map<String, dynamic>.from(message),
      finishReason: finishReason is String ? finishReason : null,
    );

    final refusal = message['refusal'];
    if (choice.content.trim().isEmpty &&
        refusal is String &&
        refusal.trim().isNotEmpty) {
      throw InvalidResponseException(
        message: '$provider declined the request: ${refusal.trim()}',
        errorType: 'refusal',
      );
    }

    return choice;
  }

  /// The assistant message, as returned by the provider.
  final Map<String, dynamic> message;

  /// Why the provider stopped generating, e.g. `stop` or `length`.
  final String? finishReason;

  /// Whether the provider stopped at the output token limit.
  bool get truncated => finishReason == 'length';

  /// The message text, or an empty string when there is none.
  ///
  /// Accepts plain string content and lists of text parts.
  String get content {
    final content = message['content'];
    if (content is String) return content;
    if (content is List<dynamic>) {
      return content
          .whereType<Map<dynamic, dynamic>>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
    }
    return '';
  }

  /// The tool calls the model requested, skipping malformed entries.
  List<Map<String, dynamic>> get toolCalls {
    final rawToolCalls = message['tool_calls'];
    if (rawToolCalls is! List<dynamic>) return <Map<String, dynamic>>[];

    return rawToolCalls
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }
}

class OpenAiCompatibleAgentRunner {
  const OpenAiCompatibleAgentRunner({
    required this.providerName,
    required this.endpoint,
    required this.model,
    required this.apiKey,
    String? displayName,
    this.maxTokensKey = 'max_tokens',
    this.turnMaxTokens = 4096,
    this.retryMaxTokens = 8192,
    this.headers = const <String, String>{},
    this.forceFirstToolCall = true,
    this.supportsToolChoiceNone = true,
  }) : displayName = displayName ?? providerName;

  final String providerName;
  final String endpoint;
  final String model;
  final String? apiKey;

  /// Provider name shown in error messages.
  final String displayName;
  final String maxTokensKey;

  /// Output token limit for each request.
  final int turnMaxTokens;

  /// Output token limit for one retry after a response is cut off.
  final int retryMaxTokens;

  /// Extra headers sent with every request.
  final Map<String, String> headers;

  /// Whether to send `tool_choice: required` on the first request so the
  /// model inspects the changes before answering. Some providers reject it.
  final bool forceFirstToolCall;

  /// Whether the provider accepts `tool_choice: none`. When it doesn't, the
  /// final request omits the tools instead.
  final bool supportsToolChoiceNone;

  Future<String> generate(AgentCommitRequest request) async {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': getAgentCommitPrompt(
          request.language,
          prefix: request.prefix,
          withEmoji: request.withEmoji,
          additionalContext: request.additionalContext,
        ),
      },
    ];

    var toolCallCount = 0;
    var toolsEnabled = request.maxToolCalls > 0;

    while (true) {
      final choice = await _requestTurn(messages, toolsEnabled: toolsEnabled);
      final toolCalls = choice.toolCalls;

      if (toolCalls.isEmpty || !toolsEnabled) {
        return _finalMessage(choice);
      }

      messages.add(choice.message);
      for (final toolCall in toolCalls) {
        final withinBudget = toolCallCount < request.maxToolCalls;
        if (withinBudget) toolCallCount++;
        messages.add(<String, dynamic>{
          'role': 'tool',
          'tool_call_id': toolCall['id'],
          'content': withinBudget
              ? await executeToolCall(request.tools, toolCall)
              : agentToolBudgetSkippedResult,
        });
      }

      if (toolCallCount >= request.maxToolCalls) {
        // Out of tool calls: ask for the message instead of failing after
        // every call has already been paid for.
        toolsEnabled = false;
        messages.add(<String, dynamic>{
          'role': 'user',
          'content': agentToolBudgetExhaustedPrompt(request.maxToolCalls),
        });
      }
    }
  }

  String _finalMessage(OpenAiChatChoice choice) {
    final text = choice.content.trim();
    if (text.isNotEmpty) return text;

    throw InvalidResponseException(
      message: choice.toolCalls.isEmpty
          ? '$displayName returned an empty commit message.'
          : '$displayName kept requesting tools after they were disabled '
              'and returned no commit message.',
    );
  }

  Future<OpenAiChatChoice> _requestTurn(
    List<Map<String, dynamic>> messages, {
    required bool toolsEnabled,
  }) async {
    // A null tool choice sends no tools at all.
    final String? toolChoice;
    if (toolsEnabled) {
      toolChoice =
          messages.length == 1 && forceFirstToolCall ? 'required' : 'auto';
    } else {
      toolChoice = supportsToolChoiceNone ? 'none' : null;
    }

    final choice = await _post(messages, toolChoice, turnMaxTokens);
    if (!choice.truncated) return choice;

    // Cut off mid-message or mid-tool-call: ask again with more room.
    final retry = await _post(messages, toolChoice, retryMaxTokens);
    if (retry.truncated && retry.toolCalls.isEmpty) {
      throw ResponseTruncatedException(
        message: '$displayName stopped at the $retryMaxTokens-token output '
            'limit before finishing the commit message.',
      );
    }
    return retry;
  }

  Future<OpenAiChatChoice> _post(
    List<Map<String, dynamic>> messages,
    String? toolChoice,
    int maxTokens,
  ) async {
    try {
      final Response<Map<String, dynamic>> response = await $dio.post(
        endpoint,
        options: Options(headers: requestHeaders(apiKey, headers)),
        data: <String, dynamic>{
          'model': model,
          'messages': List<Map<String, dynamic>>.of(messages),
          if (toolChoice != null) ...<String, dynamic>{
            'tools': GitAgentTools.openAiToolDefinitions,
            'tool_choice': toolChoice,
          },
          maxTokensKey: maxTokens,
        },
      );

      if (response.statusCode != 200) {
        throw ServerException(
          message: 'Unexpected response from $displayName API',
          statusCode: response.statusCode ?? 500,
        );
      }

      return OpenAiChatChoice.fromResponse(
        response.data,
        provider: displayName,
      );
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError(providerName, e);
    }
  }

  /// Headers for an OpenAI-compatible request, with bearer auth when an
  /// [apiKey] is set.
  static Map<String, String> requestHeaders(
    String? apiKey, [
    Map<String, String> extraHeaders = const <String, String>{},
  ]) {
    return <String, String>{
      'Content-Type': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
      ...extraHeaders,
    };
  }

  static Future<String> executeToolCall(
    GitAgentTools tools,
    Map<String, dynamic> toolCall,
  ) async {
    try {
      final rawFunction = toolCall['function'];
      if (rawFunction is! Map<dynamic, dynamic>) {
        throw const FormatException('Tool call did not include a function.');
      }

      final function = Map<String, dynamic>.from(rawFunction);
      final name = function['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('Tool call did not include a name.');
      }

      return await tools.execute(
        name,
        decodeToolArguments(function['arguments']),
      );
    } on Object catch (error) {
      return 'ERROR: $error';
    }
  }

  static Map<String, dynamic> decodeToolArguments(Object? arguments) {
    if (arguments is Map<String, dynamic>) return arguments;
    if (arguments is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(arguments);
    }
    if (arguments is! String || arguments.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(arguments);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(decoded);
    }

    return <String, dynamic>{};
  }
}

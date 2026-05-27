import 'dart:convert';

import 'package:dio/dio.dart';

import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'agent_commit_generator.dart';
import 'git_agent_tools.dart';

class OpenAiCompatibleAgentRunner {
  const OpenAiCompatibleAgentRunner({
    required this.providerName,
    required this.endpoint,
    required this.model,
    required this.apiKey,
    this.maxTokensKey = 'max_tokens',
    this.includeStore = false,
  });

  final String providerName;
  final String endpoint;
  final String model;
  final String? apiKey;
  final String maxTokensKey;
  final bool includeStore;

  Future<String> generate(AgentCommitRequest request) async {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': getAgentCommitPrompt(
          request.language,
          prefix: request.prefix,
          withEmoji: request.withEmoji,
        ),
      },
    ];

    var toolCallCount = 0;

    while (true) {
      try {
        final Response<Map<String, dynamic>> response = await $dio.post(
          endpoint,
          options: Options(headers: _headers),
          data: <String, dynamic>{
            'model': model,
            if (includeStore) 'store': true,
            'messages': messages,
            'tools': GitAgentTools.openAiToolDefinitions,
            'tool_choice': messages.length == 1 ? 'required' : 'auto',
            maxTokensKey: 1000,
          },
        );

        if (response.statusCode != 200) {
          throw ServerException(
            message: 'Unexpected response from $providerName API',
            statusCode: response.statusCode ?? 500,
          );
        }

        final message = _extractMessage(response.data);
        final toolCalls = _extractToolCalls(message);

        if (toolCalls.isEmpty) {
          return (message['content'] ?? '').toString().trim();
        }

        toolCallCount += toolCalls.length;
        if (toolCallCount > request.maxToolCalls) {
          throw StateError(
            'Agent mode exceeded ${request.maxToolCalls} tool calls.',
          );
        }

        messages.add(message);
        for (final toolCall in toolCalls) {
          final output = await executeToolCall(request.tools, toolCall);
          messages.add(<String, dynamic>{
            'role': 'tool',
            'tool_call_id': toolCall['id'],
            'content': output,
          });
        }
      } on DioException catch (e) {
        throw ErrorParser.parseProviderError(providerName, e);
      }
    }
  }

  Map<String, String> get _headers {
    return <String, String>{
      'Content-Type': 'application/json',
      if (apiKey != null && apiKey!.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
    };
  }

  Map<String, dynamic> _extractMessage(Map<String, dynamic>? data) {
    final choices = data?['choices'];
    if (choices is! List<dynamic> || choices.isEmpty) {
      throw FormatException('$providerName response did not include choices.');
    }

    final firstChoice = choices.first;
    if (firstChoice is! Map<dynamic, dynamic>) {
      throw FormatException('$providerName choice had an unexpected shape.');
    }

    final message = firstChoice['message'];
    if (message is! Map<dynamic, dynamic>) {
      throw FormatException('$providerName choice did not include a message.');
    }

    return Map<String, dynamic>.from(message);
  }

  List<Map<String, dynamic>> _extractToolCalls(Map<String, dynamic> message) {
    final rawToolCalls = message['tool_calls'];
    if (rawToolCalls is! List<dynamic>) return <Map<String, dynamic>>[];

    final toolCalls = <Map<String, dynamic>>[];
    for (final rawToolCall in rawToolCalls) {
      if (rawToolCall is Map<dynamic, dynamic>) {
        toolCalls.add(Map<String, dynamic>.from(rawToolCall));
      }
    }

    return toolCalls;
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

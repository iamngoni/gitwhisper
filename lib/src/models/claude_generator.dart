//
//  gitwhisper
//  claude_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import '../agent/agent_commit_generator.dart';
import '../agent/git_agent_tools.dart';
import '../agent/openai_compatible_agent_runner.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'commit_generator.dart';
import 'language.dart';
import 'model_variants.dart';

/// One Claude Messages API response: its content blocks, and whether it was
/// cut off at the output token limit.
typedef _ClaudeTurn = ({List<Map<String, dynamic>> content, bool truncated});

class ClaudeGenerator extends CommitGenerator implements AgentCommitGenerator {
  ClaudeGenerator(super.apiKey, {super.variant, String? baseUrl})
      : baseUrl = baseUrl ?? 'https://api.anthropic.com';

  final String baseUrl;

  String get messagesEndpoint =>
      '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/v1/messages';

  Future<Map<String, String>> resolveHeaders() async {
    return <String, String>{
      if (apiKey != null && apiKey!.isNotEmpty) 'x-api-key': apiKey!,
      'anthropic-version': '2023-06-01',
    };
  }

  @override
  String get modelName => 'claude';

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

    return requestCommitMessage('Claude', (limit) => _complete(prompt, limit));
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    final prompt = getAnalysisPrompt(diff, language);

    return requestAnalysis('Claude', (limit) => _complete(prompt, limit));
  }

  @override
  Future<String> generateAgentCommitMessage(
    AgentCommitRequest request,
  ) async {
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
      final turn = await _requestAgentTurn(
        messages,
        toolsEnabled: toolsEnabled,
      );
      final toolUses = _extractClaudeToolUses(turn.content);

      if (toolUses.isEmpty || !toolsEnabled) {
        final text = _extractClaudeText(turn.content);
        if (text.isNotEmpty) return text;
        throw InvalidResponseException(
          message: toolUses.isEmpty
              ? 'Claude returned an empty commit message.'
              : 'Claude kept requesting tools after they were disabled and '
                  'returned no commit message.',
        );
      }

      messages.add(<String, dynamic>{
        'role': 'assistant',
        'content': turn.content,
      });

      final userContent = <Map<String, dynamic>>[];
      for (final toolUse in toolUses) {
        if (toolCallCount < request.maxToolCalls) {
          toolCallCount++;
          userContent.add(await _executeClaudeToolUse(request.tools, toolUse));
        } else {
          userContent.add(<String, dynamic>{
            'type': 'tool_result',
            'tool_use_id': toolUse['id']?.toString() ?? '',
            'content': agentToolBudgetSkippedResult,
            'is_error': true,
          });
        }
      }

      if (toolCallCount >= request.maxToolCalls) {
        // Out of tool calls: ask for the message instead of failing after
        // every call has already been paid for.
        toolsEnabled = false;
        userContent.add(<String, dynamic>{
          'type': 'text',
          'text': agentToolBudgetExhaustedPrompt(request.maxToolCalls),
        });
      }

      messages.add(<String, dynamic>{
        'role': 'user',
        'content': userContent,
      });
    }
  }

  Future<GeneratedText> _complete(String prompt, int maxTokens) async {
    final turn = await _postMessages(<String, dynamic>{
      'model': actualVariant,
      'max_tokens': maxTokens,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': prompt,
        },
      ],
    });

    return (text: _extractClaudeText(turn.content), truncated: turn.truncated);
  }

  Future<_ClaudeTurn> _requestAgentTurn(
    List<Map<String, dynamic>> messages, {
    required bool toolsEnabled,
  }) async {
    // Newer models reject forced tool use (`any`), so the first request
    // relies on the prompt, which tells the model to inspect the changes.
    Future<_ClaudeTurn> send(int maxTokens) {
      return _postMessages(<String, dynamic>{
        'model': actualVariant,
        'max_tokens': maxTokens,
        'messages': List<Map<String, dynamic>>.of(messages),
        'tools': GitAgentTools.claudeToolDefinitions,
        'tool_choice': <String, dynamic>{
          'type': toolsEnabled ? 'auto' : 'none',
        },
      });
    }

    final turn = await send(agentTurnMaxTokens);
    if (!turn.truncated) return turn;

    // Cut off mid-message or mid-tool-call: ask again with more room.
    final retry = await send(truncationRetryMaxTokens);
    if (retry.truncated && _extractClaudeToolUses(retry.content).isEmpty) {
      throw ResponseTruncatedException(
        message: 'Claude stopped at the $truncationRetryMaxTokens-token output '
            'limit before finishing the commit message.',
      );
    }
    return retry;
  }

  Future<_ClaudeTurn> _postMessages(Map<String, dynamic> body) async {
    try {
      final headers = await resolveHeaders();
      final Response<Map<String, dynamic>> response = await $dio.post(
        messagesEndpoint,
        options: Options(
          headers: headers,
        ),
        data: body,
      );

      if (response.statusCode != 200) {
        throw ServerException(
          message: 'Unexpected response from Claude API',
          statusCode: response.statusCode ?? 500,
        );
      }

      final data = response.data;
      final stopReason = data?['stop_reason'];
      if (stopReason == 'refusal') {
        throw const InvalidResponseException(
          message: 'Claude declined the request (stop_reason: refusal).',
          errorType: 'refusal',
        );
      }

      return (
        content: _extractClaudeContent(data),
        truncated: stopReason == 'max_tokens' ||
            stopReason == 'model_context_window_exceeded',
      );
    } on DioException catch (e) {
      throw ErrorParser.parseProviderError('claude', e);
    }
  }

  List<Map<String, dynamic>> _extractClaudeContent(
    Map<String, dynamic>? data,
  ) {
    final rawContent = data?['content'];
    if (rawContent is! List<dynamic>) {
      throw const InvalidResponseException(
        message: 'Claude response did not include content.',
      );
    }

    return rawContent
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  List<Map<String, dynamic>> _extractClaudeToolUses(
    List<Map<String, dynamic>> content,
  ) {
    return content
        .where((block) => block['type'] == 'tool_use')
        .map(Map<String, dynamic>.from)
        .toList();
  }

  String _extractClaudeText(List<Map<String, dynamic>> content) {
    return content
        .where((block) => block['type'] == 'text')
        .map((block) => (block['text'] ?? '').toString())
        .where((text) => text.trim().isNotEmpty)
        .join('\n')
        .trim();
  }

  Future<Map<String, dynamic>> _executeClaudeToolUse(
    GitAgentTools tools,
    Map<String, dynamic> toolUse,
  ) async {
    final id = toolUse['id']?.toString() ?? '';

    try {
      final name = toolUse['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('Tool use did not include a name.');
      }

      final output = await tools.execute(
        name,
        _decodeClaudeToolInput(toolUse['input']),
      );

      return <String, dynamic>{
        'type': 'tool_result',
        'tool_use_id': id,
        'content': output,
      };
    } on Object catch (error) {
      return <String, dynamic>{
        'type': 'tool_result',
        'tool_use_id': id,
        'content': 'ERROR: $error',
        'is_error': true,
      };
    }
  }

  Map<String, dynamic> _decodeClaudeToolInput(Object? input) {
    if (input is Map<String, dynamic>) return input;
    if (input is Map<dynamic, dynamic>) {
      return Map<String, dynamic>.from(input);
    }

    return <String, dynamic>{};
  }
}

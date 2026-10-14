import '../models/language.dart';
import 'git_agent_tools.dart';

class AgentCommitRequest {
  const AgentCommitRequest({
    required this.tools,
    required this.language,
    this.prefix,
    this.withEmoji = true,
    this.maxToolCalls = 32,
    this.additionalContext,
  });

  final GitAgentTools tools;
  final Language language;
  final String? prefix;
  final bool withEmoji;
  final int maxToolCalls;

  /// Extra guidance from the user, e.g. entered via "add context" when
  /// regenerating a message.
  final String? additionalContext;
}

// This marker keeps provider capability checks explicit at the command layer.
// ignore: one_member_abstracts
abstract interface class AgentCommitGenerator {
  Future<String> generateAgentCommitMessage(AgentCommitRequest request);
}

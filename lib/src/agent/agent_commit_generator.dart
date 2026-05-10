import '../models/language.dart';
import 'git_agent_tools.dart';

class AgentCommitRequest {
  const AgentCommitRequest({
    required this.tools,
    required this.language,
    this.prefix,
    this.withEmoji = true,
    this.maxToolCalls = 8,
  });

  final GitAgentTools tools;
  final Language language;
  final String? prefix;
  final bool withEmoji;
  final int maxToolCalls;
}

abstract interface class AgentCommitGenerator {
  Future<String> generateAgentCommitMessage(AgentCommitRequest request);
}

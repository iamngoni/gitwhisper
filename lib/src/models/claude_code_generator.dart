import 'acp_local_agent_generator.dart';

class ClaudeCodeGenerator extends AcpLocalAgentGenerator {
  ClaudeCodeGenerator({
    super.variant,
    super.environment,
    super.workingDirectory,
    super.timeout,
    super.registryLoader,
    super.startProcess,
  }) : super(
          model: 'claude-code',
          registryQuery: 'claude-code',
        );
}

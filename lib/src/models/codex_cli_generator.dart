import 'acp_local_agent_generator.dart';

class CodexCliGenerator extends AcpLocalAgentGenerator {
  CodexCliGenerator({
    super.variant,
    super.environment,
    super.workingDirectory,
    super.timeout,
    super.registryLoader,
    super.startProcess,
  }) : super(
          model: 'codex',
          registryQuery: 'codex',
        );
}

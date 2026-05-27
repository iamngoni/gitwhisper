import 'dart:io';

import '../acp/acp_client.dart';
import '../acp/acp_registry.dart';
import '../agent/agent_commit_generator.dart';
import '../commit_utils.dart';
import 'commit_generator.dart';
import 'language.dart';

class AcpLocalAgentGenerator extends CommitGenerator
    implements AgentCommitGenerator {
  AcpLocalAgentGenerator({
    required this.model,
    required this.registryQuery,
    this.registryLoader,
    this.workingDirectory,
    this.environment,
    this.startProcess,
    this.timeout = const Duration(minutes: 5),
    super.variant,
  }) : super(null);

  final String model;
  final String registryQuery;
  final AcpRegistryLoader? registryLoader;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final AcpProcessStarter? startProcess;
  final Duration timeout;

  @override
  String get modelName => model;

  @override
  String get defaultVariant => '';

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) {
    return _runPrompt(
      getCommitPrompt(
        diff,
        language,
        prefix: prefix,
        withEmoji: withEmoji,
      ),
    );
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    return _runPrompt(getAnalysisPrompt(diff, language));
  }

  @override
  Future<String> generateAgentCommitMessage(AgentCommitRequest request) {
    final prompt = '''
You are running as a local ACP coding agent inside GitWhisper.

Inspect staged git changes in the current repository and generate the final commit message.

Constraints:
- Inspect staged changes only.
- Do not modify files.
- Do not stage, unstage, commit, tag, push, or run destructive commands.
- Return only the final commit message or messages.

${getAgentCommitPrompt(
      request.language,
      prefix: request.prefix,
      withEmoji: request.withEmoji,
    )}
''';

    return _runPrompt(prompt);
  }

  Future<String> _runPrompt(String prompt) async {
    final registry = await (registryLoader ?? AcpRegistryLoader()).load();
    final agent = registry.resolve(registryQuery);
    final launch = agent.toLaunchCommand();

    final mergedEnvironment = <String, String>{
      ...launch.environment,
      if (environment != null) ...environment!,
    };

    return AcpClient(
      executable: launch.executable,
      arguments: launch.arguments,
      environment: mergedEnvironment.isEmpty ? null : mergedEnvironment,
      workingDirectory: workingDirectory,
      timeout: timeout,
      startProcess: startProcess,
    ).prompt(
      cwd: workingDirectory ?? Directory.current.path,
      text: prompt,
    );
  }
}

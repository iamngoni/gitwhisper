import 'dart:io';

import '../acp/acp_client.dart';
import '../acp/acp_launcher.dart';
import '../acp/acp_registry.dart';
import '../agent/agent_commit_generator.dart';
import '../commit_utils.dart';
import '../constants.dart';
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
    this.agentLauncher,
    this.timeout = const Duration(minutes: 5),
    super.variant,
  }) : super(null);

  final String model;
  final String registryQuery;
  final AcpRegistryLoader? registryLoader;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final AcpProcessStarter? startProcess;
  final AcpAgentLauncher? agentLauncher;
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
    final launcher = agentLauncher ?? AcpAgentLauncher();
    final launch = await launcher.launchCommandFor(agent);

    final mergedEnvironment = <String, String>{
      ...launch.environment,
      if (environment != null) ...environment!,
    };

    try {
      return await _prompt(launch, mergedEnvironment, prompt);
    } on AcpAuthenticationRequiredException catch (error) {
      await _authenticate(agent, launcher, error.authMethods);
      return _prompt(launch, mergedEnvironment, prompt);
    }
  }

  Future<String> _prompt(
    AcpLaunchCommand launch,
    Map<String, String> mergedEnvironment,
    String prompt,
  ) {
    return AcpClient(
      executable: launch.executable,
      arguments: launch.arguments,
      environment: mergedEnvironment.isEmpty ? null : mergedEnvironment,
      workingDirectory: launch.workingDirectory ?? workingDirectory,
      timeout: timeout,
      startProcess: startProcess,
    ).prompt(
      cwd: workingDirectory ?? Directory.current.path,
      text: prompt,
    );
  }

  Future<void> _authenticate(
    AcpAgentDefinition agent,
    AcpAgentLauncher launcher,
    List<AcpAuthMethod> methods,
  ) async {
    final terminalMethod =
        methods.where((method) => method.isTerminal).firstOrNull;
    if (terminalMethod != null) {
      await _runTerminalAuth(agent, launcher, terminalMethod);
      return;
    }

    final agentMethod = methods.where((method) => method.isAgent).firstOrNull;
    if (agentMethod != null) {
      await _runAgentAuth(agent, launcher, agentMethod);
      return;
    }

    throw const AcpException(
      'Authentication is required, but this ACP agent did not provide an auth '
      'method GitWhisper can run.',
    );
  }

  Future<void> _runTerminalAuth(
    AcpAgentDefinition agent,
    AcpAgentLauncher launcher,
    AcpAuthMethod method,
  ) async {
    final authLaunch = await launcher.authLaunchCommandFor(agent, method);
    final authEnvironment = <String, String>{
      ...authLaunch.environment,
      if (environment != null) ...environment!,
    };

    final label = method.name.isNotEmpty ? method.name : method.id;
    $logger.info('Authentication required. Starting $label...');

    final process = await Process.start(
      authLaunch.executable,
      authLaunch.arguments,
      workingDirectory: authLaunch.workingDirectory ?? workingDirectory,
      environment: authEnvironment.isEmpty ? null : authEnvironment,
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw AcpException(
        'ACP authentication failed for ${agent.id} with exit code $exitCode.',
      );
    }
    $logger.success('Authentication complete. Retrying ${agent.id}...');
  }

  Future<void> _runAgentAuth(
    AcpAgentDefinition agent,
    AcpAgentLauncher launcher,
    AcpAuthMethod method,
  ) async {
    final launch = await launcher.launchCommandFor(agent);
    final mergedEnvironment = <String, String>{
      ...launch.environment,
      if (environment != null) ...environment!,
    };

    final label = method.name.isNotEmpty ? method.name : method.id;
    $logger.info('Authentication required. Starting $label...');
    await AcpClient(
      executable: launch.executable,
      arguments: launch.arguments,
      environment: mergedEnvironment.isEmpty ? null : mergedEnvironment,
      workingDirectory: launch.workingDirectory ?? workingDirectory,
      timeout: timeout,
      startProcess: startProcess,
    ).authenticate(methodId: method.id);
    $logger.success('Authentication complete. Retrying ${agent.id}...');
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

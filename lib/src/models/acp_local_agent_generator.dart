import 'dart:io';

import '../acp/acp_client.dart';
import '../acp/acp_launcher.dart';
import '../acp/acp_registry.dart';
import '../agent/agent_commit_generator.dart';
import '../commit_utils.dart';
import '../constants.dart';
import '../git_utils.dart';
import '../mcp/git_tools_mcp_config.dart';
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

  static const _commitRetryPrompt =
      'You stopped before returning the final commit message. Using the '
      'staged-change context you already inspected, return only the final '
      'conventional commit message now. No explanation, no planning text, no '
      'Markdown.';

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

    return _runPrompt(prompt, requireConventionalCommit: true);
  }

  Future<String> _runPrompt(
    String prompt, {
    bool requireConventionalCommit = false,
  }) async {
    final registry = await (registryLoader ?? AcpRegistryLoader()).load();
    final agent = registry.resolveSupported(registryQuery);
    final launcher = agentLauncher ?? AcpAgentLauncher();
    final logFile = _createLogFile(agent.id);
    final launchProgress = $logger.progress('Preparing ACP agent ${agent.id}');

    late final AcpLaunchCommand launch;
    try {
      launch = await launcher.launchCommandFor(
        agent,
        onStatus: launchProgress.update,
      );
      launchProgress.complete('Ready to launch ${agent.id}');
    } on Object {
      launchProgress.fail('Failed to prepare ${agent.id}');
      rethrow;
    }

    final mergedEnvironment = <String, String>{
      ...launch.environment,
      if (environment != null) ...environment!,
    };

    try {
      return _validateAgentText(
        await _prompt(
          launch,
          mergedEnvironment,
          prompt,
          logFile,
          requireConventionalCommit: requireConventionalCommit,
        ),
      );
    } on AcpAuthenticationRequiredException catch (error) {
      await _authenticate(agent, launcher, error.authMethods);
      return _validateAgentText(
        await _prompt(
          launch,
          mergedEnvironment,
          prompt,
          logFile,
          requireConventionalCommit: requireConventionalCommit,
        ),
      );
    }
  }

  String _validateAgentText(String text) {
    final normalized = text.trim().toLowerCase();
    if (normalized.isEmpty) {
      throw const AcpException(
        'ACP agent returned no final text. It may have stopped before '
        'generating a commit message.',
      );
    }
    if (normalized == 'upgrade your plan to continue' ||
        normalized.contains('upgrade your plan to continue') ||
        normalized.contains('payment required') ||
        normalized.contains('paid credits') ||
        normalized.contains('out of credits') ||
        normalized.contains('quota exceeded') ||
        normalized.contains('rate limit')) {
      throw AcpException(
        'ACP agent could not generate a commit message because its provider '
        'requires a plan upgrade, credits, or available quota.',
        details: text,
      );
    }
    if (normalized.startsWith('error:') ||
        normalized.contains('no snowflake connection available')) {
      if (normalized.contains('not authorized') ||
          normalized.contains('policy to be enabled')) {
        throw AcpException(
          'ACP agent is not authorized for this account or organization.',
          details: text,
        );
      }
      throw AcpException(
        'ACP agent failed before generating a commit message.',
        details: text,
      );
    }
    return text;
  }

  Future<String> _prompt(
    AcpLaunchCommand launch,
    Map<String, String> mergedEnvironment,
    String prompt,
    File logFile, {
    bool requireConventionalCommit = false,
  }) {
    return AcpClient(
      executable: launch.executable,
      arguments: launch.arguments,
      environment: mergedEnvironment.isEmpty ? null : mergedEnvironment,
      workingDirectory: launch.workingDirectory ?? workingDirectory,
      mcpServers: <Map<String, dynamic>>[
        GitToolsMcpConfig.forCwd(workingDirectory ?? Directory.current.path),
      ],
      logFile: logFile,
      timeout: timeout,
      startProcess: startProcess,
    ).prompt(
      cwd: workingDirectory ?? Directory.current.path,
      text: prompt,
      retryPrompts: requireConventionalCommit
          ? const <String>[_commitRetryPrompt]
          : const <String>[],
      shouldRetry: requireConventionalCommit
          ? (text, turn) => _shouldRetryForCommitMessage(text)
          : null,
    );
  }

  bool _shouldRetryForCommitMessage(String text) {
    final normalized = text.trim().toLowerCase();
    if (normalized.isEmpty ||
        normalized.contains('upgrade your plan to continue') ||
        normalized.contains('payment required') ||
        normalized.contains('paid credits') ||
        normalized.contains('out of credits') ||
        normalized.contains('quota exceeded') ||
        normalized.contains('rate limit') ||
        normalized.startsWith('error:')) {
      return false;
    }
    return GitUtils.sanitizeGeneratedCommitMessage(
      text,
      requireConventionalCommit: true,
    ).trim().isEmpty;
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
      final authenticateMethodId = terminalMethod.authenticateMethodId;
      if (authenticateMethodId != null && authenticateMethodId.isNotEmpty) {
        await _runAgentAuth(
          agent,
          launcher,
          AcpAuthMethod(
            id: authenticateMethodId,
            name: authenticateMethodId,
            description: terminalMethod.description,
            type: 'agent',
          ),
        );
      }
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
    final authLaunch = await launcher.authLaunchCommandFor(
      agent,
      method,
      onStatus: $logger.info,
    );
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
    final launch = await launcher.launchCommandFor(
      agent,
      onStatus: $logger.info,
    );
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
      logFile: _createLogFile('${agent.id}-auth'),
      timeout: timeout,
      startProcess: startProcess,
    ).authenticate(methodId: method.id);
    $logger.success('Authentication complete. Retrying ${agent.id}...');
  }

  File _createLogFile(String agentId) {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    final safeAgent = agentId.replaceAll(RegExp('[^a-zA-Z0-9_.-]+'), '-');
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(
      '$home/.gitwhisper/acp/logs/$safeAgent-$timestamp.jsonl',
    );
    AcpDebugLog.lastLogPath = file.path;
    return file;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class AcpDebugLog {
  static String? lastLogPath;
}

import 'dart:io';

import 'package:mason_logger/mason_logger.dart';

import '../acp/acp_client.dart';
import '../acp/acp_consent.dart';
import '../acp/acp_debug_log.dart';
import '../acp/acp_launcher.dart';
import '../acp/acp_registry.dart';
import '../agent/agent_commit_generator.dart';
import '../agent/agent_tool_activity_formatter.dart';
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
    this.debugLogs,
    this.prompter,
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

  /// ACP debug logs. Off unless `GITWHISPER_ACP_DEBUG=1`.
  final AcpDebugLogs? debugLogs;

  /// Asks before running an agent's terminal login command.
  final AcpConsentPrompter? prompter;

  late final AcpDebugLogs _debugLogs = debugLogs ?? AcpDebugLogs();
  Progress? _acpStatusProgress;
  String? _acpStatusProgressTitle;

  static const _activityFormatter = AgentToolActivityFormatter();

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
      additionalContext: request.additionalContext,
    )}
''';

    return _runPrompt(
      prompt,
      requireConventionalCommit: true,
      repoPath: request.tools.folderPath,
    );
  }

  /// Runs [prompt] through the ACP agent. [repoPath] is the repository the
  /// agent and its git tools work in; it defaults to [workingDirectory] or the
  /// current directory.
  Future<String> _runPrompt(
    String prompt, {
    bool requireConventionalCommit = false,
    String? repoPath,
  }) async {
    AcpDebugLog.lastLogPath = null;
    await _pruneDebugLogs();

    final registry = await (registryLoader ?? AcpRegistryLoader()).load();
    final agent = registry.resolveSupported(registryQuery);
    final launcher = agentLauncher ?? AcpAgentLauncher();
    // Ask before the first launch of this agent version, before any spinner
    // starts, so the prompt is readable.
    await launcher.ensureLaunchApproved(agent);
    final logFile = await _createLogFile(agent.id);
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
          repoPath: repoPath,
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
          repoPath: repoPath,
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
    File? logFile, {
    bool requireConventionalCommit = false,
    String? repoPath,
  }) {
    final repoDirectory =
        repoPath ?? workingDirectory ?? Directory.current.path;
    return AcpClient(
      executable: launch.executable,
      arguments: launch.arguments,
      environment: mergedEnvironment.isEmpty ? null : mergedEnvironment,
      workingDirectory: launch.workingDirectory ?? repoPath ?? workingDirectory,
      mcpServers: <Map<String, dynamic>>[
        GitToolsMcpConfig.forCwd(repoDirectory),
      ],
      logFile: logFile,
      timeout: timeout,
      onActivity: _logActivity,
      onStatus: _logStatus,
      startProcess: startProcess,
    ).prompt(
      cwd: repoDirectory,
      text: prompt,
      retryPrompts: requireConventionalCommit
          ? const <String>[_commitRetryPrompt]
          : const <String>[],
      shouldRetry: requireConventionalCommit
          ? (text, turn) => _shouldRetryForCommitMessage(text)
          : null,
    );
  }

  void _logActivity(AcpToolActivity activity) {
    $logger.info(
      _activityFormatter.formatAcp(
        activity.title,
        path: activity.path,
        hunkIndex: activity.hunkIndex,
      ),
    );
  }

  void _logStatus(AcpStatusEvent status) {
    switch (status.phase) {
      case AcpStatusPhase.started:
        _acpStatusProgress?.cancel();
        _acpStatusProgress = $logger.progress(status.title);
        _acpStatusProgressTitle = status.title;
      case AcpStatusPhase.completed:
        final progress = _takeStatusProgress(status.title);
        if (progress != null) {
          progress.complete(status.title);
        } else {
          $logger.success('${status.title} ${_formatDuration(status.elapsed)}');
        }
      case AcpStatusPhase.failed:
        final progress = _takeStatusProgress(status.title);
        if (progress != null) {
          progress.fail(status.title);
        } else {
          $logger
              .err('${status.title} failed ${_formatDuration(status.elapsed)}');
        }
    }
  }

  Progress? _takeStatusProgress(String title) {
    if (_acpStatusProgressTitle != title) return null;
    final progress = _acpStatusProgress;
    _acpStatusProgress = null;
    _acpStatusProgressTitle = null;
    return progress;
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '';
    final milliseconds = duration.inMilliseconds;
    if (milliseconds < 100) return '(${milliseconds}ms)';
    return '(${(milliseconds / 1000).toStringAsFixed(1)}s)';
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
    final commandLine = formatCommandLine(
      <String>[authLaunch.executable, ...authLaunch.arguments],
    );
    final authWorkingDirectory =
        authLaunch.workingDirectory ?? workingDirectory;

    // The login command can come from the agent's own error text, so show
    // exactly what will run and ask first. Without a terminal, do not run it.
    final consent = prompter ?? AcpConsentPrompter();
    final approved = consent.ask(
      'Run this login command now?',
      details: <String>[
        'ACP agent ${agent.id} needs you to sign in ($label).',
        'GitWhisper will run:',
        '  $commandLine',
        if (authWorkingDirectory != null) '  in $authWorkingDirectory',
        if (authLaunch.environment.isNotEmpty)
          '  with ${authLaunch.environment.entries.map(
                (entry) => '${entry.key}=${entry.value}',
              ).join(' ')}',
      ],
    );
    if (!approved) {
      final reason = consent.canPrompt
          ? 'you declined to run its login command'
          : 'there is no interactive terminal to confirm its login command';
      throw AcpException(
        'ACP agent ${agent.id} requires authentication, but $reason. Sign in '
        'by running this yourself, then retry:\n  $commandLine',
      );
    }

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
      logFile: await _createLogFile('${agent.id}-auth'),
      timeout: timeout,
      onStatus: _logStatus,
      startProcess: startProcess,
    ).authenticate(methodId: method.id);
    $logger.success('Authentication complete. Retrying ${agent.id}...');
  }

  /// Creates this run's debug log when `GITWHISPER_ACP_DEBUG` is on.
  Future<File?> _createLogFile(String agentId) async {
    final file = await _debugLogs.createLogFile(agentId);
    if (file != null) AcpDebugLog.lastLogPath = file.path;
    return file;
  }

  Future<void> _pruneDebugLogs() async {
    try {
      await _debugLogs.prune();
    } on Object {
      // Pruning is housekeeping; never fail a commit over it.
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class AcpDebugLog {
  /// Path of the debug log written by the most recent ACP run, or null when
  /// debug logging is off.
  static String? lastLogPath;
}

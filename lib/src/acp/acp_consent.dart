import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as path;

import '../constants.dart';
import '../private_files.dart';
import 'acp_client.dart';
import 'acp_registry.dart';

/// Asks a yes/no question and returns the answer.
typedef AcpConfirm = bool Function(String question);

/// Formats [command] as a shell-style command line so users see exactly
/// what will run. Arguments with spaces or shell metacharacters are quoted.
String formatCommandLine(List<String> command) {
  return command.map(_quoteArgument).join(' ');
}

String _quoteArgument(String value) {
  if (value.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value)) return value;
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Asks the user before GitWhisper runs something on their behalf, such as
/// a newly seen ACP agent or an agent's login command.
///
/// Without an interactive terminal (CI, hooks, piped input) it never asks,
/// and callers fail closed.
class AcpConsentPrompter {
  AcpConsentPrompter({
    Logger? logger,
    AcpConfirm? confirm,
    bool Function()? isInteractive,
  })  : _logger = logger,
        _confirm = confirm,
        _isInteractive = isInteractive;

  final Logger? _logger;
  final AcpConfirm? _confirm;
  final bool Function()? _isInteractive;

  Logger get _log => _logger ?? $logger;

  /// Whether a person can answer a prompt right now.
  bool get canPrompt => (_isInteractive ?? _hasTerminal)();

  /// Shows [details], then asks [question] with "no" as the default. Returns
  /// false without asking when [canPrompt] is false.
  bool ask(String question, {List<String> details = const <String>[]}) {
    if (!canPrompt) return false;
    details.forEach(_log.info);
    final confirm = _confirm ?? (question) => _log.confirm(question);
    return confirm(question);
  }

  static bool _hasTerminal() {
    try {
      return stdin.hasTerminal && stdout.hasTerminal;
    } on Object {
      return false;
    }
  }
}

/// Exactly what GitWhisper runs for an ACP agent: an npm package through
/// npx, or a downloaded binary.
class AcpLaunchSource {
  const AcpLaunchSource({required this.fingerprint, required this.details});

  /// Stable description of what runs, recorded with an approval. If the
  /// registry later points the same agent version at a different package,
  /// archive, checksum, command or environment, the old approval no longer
  /// applies.
  final String fingerprint;

  /// Human-readable lines shown before the first launch.
  final List<String> details;
}

/// Thrown when an ACP agent has not been approved to run.
class AcpLaunchNotApprovedException extends AcpException {
  const AcpLaunchNotApprovedException(super.message);
}

/// ACP agent launches the user has approved, persisted in GitWhisper's agent
/// cache.
///
/// Approval is per agent id and version, and bound to exactly what runs
/// ([AcpLaunchSource.fingerprint]). `gw acp install <agent>` counts as
/// approval. Otherwise the first launch shows what will run and asks.
/// Without an interactive terminal it fails closed.
class AcpAgentApprovals {
  AcpAgentApprovals({required this.file, AcpConsentPrompter? prompter})
      : _prompter = prompter ?? AcpConsentPrompter();

  /// Approvals stored next to the agents GitWhisper installs.
  factory AcpAgentApprovals.inCacheDirectory(
    Directory cacheDirectory, {
    AcpConsentPrompter? prompter,
  }) {
    return AcpAgentApprovals(
      file: File(path.join(cacheDirectory.path, '.approved-agents.json')),
      prompter: prompter,
    );
  }

  final File file;
  final AcpConsentPrompter _prompter;

  /// Approvals granted during this run, so a failed write never re-prompts.
  final _session = <String, String>{};

  bool isApproved(AcpAgentDefinition agent, AcpLaunchSource source) {
    final key = _key(agent);
    if (_session[key] == source.fingerprint) return true;
    final entry = _read()[key];
    return entry is Map<String, dynamic> &&
        entry['source'] == source.fingerprint;
  }

  /// Records that the user approved running [agent] from [source].
  Future<void> approve(AcpAgentDefinition agent, AcpLaunchSource source) async {
    final key = _key(agent);
    _session[key] = source.fingerprint;
    final approvals = _read()
      ..[key] = <String, dynamic>{
        'source': source.fingerprint,
        'approvedAt': DateTime.now().toUtc().toIso8601String(),
      };
    // Atomic, so a crash never leaves a half-written approvals file.
    await writePrivateFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(
        <String, dynamic>{'version': 1, 'approved': approvals},
      ),
    );
  }

  /// Returns when [agent] may run from [source]. Asks first if needed, and
  /// throws [AcpLaunchNotApprovedException] when it may not.
  Future<void> ensureApproved(
    AcpAgentDefinition agent,
    AcpLaunchSource source,
  ) async {
    if (isApproved(agent, source)) return;

    final label = '"${agent.id}" (${agent.name}) v${agent.version}';
    final details = <String>[
      'GitWhisper has not run ACP agent $label on this machine before.',
      'It will run:',
      for (final line in source.details) '  $line',
    ];

    if (!_prompter.canPrompt) {
      const noTerminal = 'GitWhisper cannot ask for approval without an '
          'interactive terminal, so it did not run the agent.';
      final howToApprove = 'To approve it, run `gw acp install ${agent.id}` '
          '(or rerun this command in an interactive terminal).';
      throw AcpLaunchNotApprovedException(
        <String>[...details, noTerminal, howToApprove].join('\n'),
      );
    }

    final approved = _prompter.ask(
      'Run ACP agent ${agent.id} v${agent.version}?',
      details: details,
    );
    if (!approved) {
      throw AcpLaunchNotApprovedException(
        'Did not run ACP agent ${agent.id}: approval declined. Run '
        '`gw acp install ${agent.id}` to approve it later.',
      );
    }

    await approve(agent, source);
  }

  String _key(AcpAgentDefinition agent) => '${agent.id}@${agent.version}';

  Map<String, dynamic> _read() {
    try {
      if (!file.existsSync()) return <String, dynamic>{};
      final decoded = jsonDecode(file.readAsStringSync());
      final approved =
          decoded is Map<String, dynamic> ? decoded['approved'] : null;
      return approved is Map<String, dynamic>
          ? Map<String, dynamic>.of(approved)
          : <String, dynamic>{};
    } on Object {
      // Unreadable or corrupt approvals fail closed: ask again.
      return <String, dynamic>{};
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../private_files.dart';
import '../user_home.dart';
import 'acp_client.dart';
import 'acp_consent.dart';

/// Repository files and directories that coding agents, or the npm tooling
/// around them, load as configuration that can run commands, start MCP
/// servers or approve tools without asking GitWhisper. Paths are relative to
/// a directory the agent works in and use `/` separators.
///
/// Plain instruction files (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`) are not
/// listed: agents read them as text and they cannot run anything themselves.
const acpRepoAgentConfigPaths = <String, String>{
  '.claude': 'Claude Code settings (hooks, permissions, MCP servers)',
  '.mcp.json': 'MCP servers for Claude Code and other agents',
  '.gemini': 'Gemini CLI settings (MCP servers, hooks, extensions)',
  '.qwen': 'Qwen Code settings (MCP servers, hooks)',
  '.codex': 'Codex project config (MCP servers, commands)',
  '.cursor': 'Cursor settings (MCP servers, hooks)',
  '.qoder': 'Qoder settings (MCP servers, hooks)',
  '.factory': 'Factory Droid settings (MCP servers, hooks)',
  '.kiro': 'Kiro settings (MCP servers, hooks)',
  '.junie': 'Junie settings (MCP servers)',
  '.augment': 'Augment settings (MCP servers, hooks)',
  '.opencode': 'OpenCode settings (plugins, MCP servers)',
  'opencode.json': 'OpenCode config (plugins, MCP servers)',
  '.github/hooks': 'GitHub Copilot hooks',
  '.vscode/mcp.json': 'MCP servers for GitHub Copilot and other agents',
  '.npmrc': 'npm config (node options, registry) for npm and npx',
  'node_modules': 'npm packages that npx and node can run',
};

/// Agent configuration found in a repository.
class AcpRepoAgentConfig {
  const AcpRepoAgentConfig({
    required this.relativePath,
    required this.description,
    required this.isDirectory,
  });

  /// Path relative to the repository root, with `/` separators.
  final String relativePath;
  final String description;
  final bool isDirectory;

  /// [relativePath] with a trailing `/` for directories.
  String get displayPath => isDirectory ? '$relativePath/' : relativePath;
}

/// What a repository contains that an ACP agent working in it could load.
class AcpRepoScan {
  const AcpRepoScan({required this.root, required this.agentConfig});

  /// Real path of the repository root: the nearest directory with a `.git`
  /// entry, or the scanned directory itself outside a git repository.
  final String root;

  final List<AcpRepoAgentConfig> agentConfig;
}

/// Thrown when GitWhisper will not run an ACP agent in an untrusted
/// repository that contains agent configuration.
class AcpRepoNotTrustedException extends AcpException {
  const AcpRepoNotTrustedException(super.message);
}

/// Repositories the user trusts to supply agent configuration, stored as an
/// owner-only JSON file (`~/.gitwhisper/acp/trusted-repos.json`).
///
/// ACP agents receive the repository as their session directory and load
/// its agent configuration (see [acpRepoAgentConfigPaths]), which can run
/// commands or approve tools without asking GitWhisper. Before an agent runs
/// in a repository with such configuration, GitWhisper asks once per
/// repository. Without an interactive terminal it fails closed and explains
/// `gw acp trust`.
class AcpTrustedRepos {
  AcpTrustedRepos({File? file, AcpConsentPrompter? prompter})
      : _fileOverride = file,
        _prompter = prompter ?? AcpConsentPrompter();

  final File? _fileOverride;
  final AcpConsentPrompter _prompter;

  /// Where trust is stored. Resolved on first use, so creating
  /// [AcpTrustedRepos] never needs a home directory. Throws
  /// [UserHomeException] when the home directory is unknown.
  late final File file = _fileOverride ??
      File(
        path.join(
          userHomeDirectory(),
          '.gitwhisper',
          'acp',
          'trusted-repos.json',
        ),
      );

  /// Trust granted during this run, so a failed write never re-prompts.
  final _session = <String>{};

  /// Finds the agent configuration an ACP agent working in [directory] could
  /// load: in [directory] and each parent up to the repository root.
  static AcpRepoScan scan(String directory) {
    final start = _realPath(directory);
    final searched = <String>[];
    String? root;
    for (var current = start;; current = path.dirname(current)) {
      searched.add(current);
      if (_exists(path.join(current, '.git'))) {
        root = current;
        break;
      }
      if (path.dirname(current) == current) break;
    }
    if (root == null) {
      // Not in a git repository: only the directory itself is in play.
      root = start;
      searched
        ..clear()
        ..add(start);
    }

    final found = <AcpRepoAgentConfig>[];
    for (final directory in searched.reversed) {
      for (final entry in acpRepoAgentConfigPaths.entries) {
        final candidate = path.joinAll(<String>[
          directory,
          ...entry.key.split('/'),
        ]);
        final type = FileSystemEntity.typeSync(candidate, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        found.add(
          AcpRepoAgentConfig(
            relativePath: path.posix.joinAll(
              path.split(path.relative(candidate, from: root)),
            ),
            description: entry.value,
            isDirectory: type == FileSystemEntityType.directory,
          ),
        );
      }
    }
    return AcpRepoScan(root: root, agentConfig: found);
  }

  bool isTrusted(String repoRoot) {
    if (_session.contains(repoRoot)) return true;
    return _read().containsKey(repoRoot);
  }

  /// Records that the user trusts the repository at [repoRoot] (a real path,
  /// see [AcpRepoScan.root]).
  Future<void> trust(String repoRoot) async {
    _session.add(repoRoot);
    final trusted = _read()
      ..[repoRoot] = <String, dynamic>{
        'trustedAt': DateTime.now().toUtc().toIso8601String(),
      };
    await _write(trusted);
  }

  /// Removes trust for [repoRoot]. Returns false when it was not trusted.
  Future<bool> untrust(String repoRoot) async {
    _session.remove(repoRoot);
    final trusted = _read();
    if (trusted.remove(repoRoot) == null) return false;
    await _write(trusted);
    return true;
  }

  /// Returns when ACP agent [agentId] may work in [directory]: it contains no
  /// agent configuration, or the repository is trusted. Otherwise shows what
  /// was found and asks. Throws [AcpRepoNotTrustedException] when it may not.
  Future<void> ensureTrusted(
    String directory, {
    required String agentId,
  }) async {
    final scan = AcpTrustedRepos.scan(directory);
    if (scan.agentConfig.isEmpty || isTrusted(scan.root)) return;

    final trustCommand = formatCommandLine(
      <String>['gw', 'acp', 'trust', scan.root],
    );
    final found = 'ACP agent $agentId would work in ${scan.root}, which '
        'contains agent configuration:';
    const risk = 'Coding agents load these files from the repository they '
        'work in. They can run commands, start MCP servers or approve tools '
        'without asking GitWhisper. Only trust repositories whose contents '
        'you trust.';
    final details = <String>[
      found,
      for (final config in scan.agentConfig)
        '  ${config.displayPath}  ${config.description}',
      risk,
    ];

    if (!_prompter.canPrompt) {
      const noTerminal = 'GitWhisper cannot ask without an interactive '
          'terminal, so it did not run the agent.';
      final howToTrust =
          'If you trust this repository, run `$trustCommand` and retry.';
      throw AcpRepoNotTrustedException(
        <String>[...details, noTerminal, howToTrust].join('\n'),
      );
    }

    final trusted = _prompter.ask(
      'Trust ${scan.root} and let ACP agents use its agent configuration?',
      details: details,
    );
    if (!trusted) {
      throw AcpRepoNotTrustedException(
        'Did not run ACP agent $agentId: ${scan.root} is not trusted. Run '
        '`$trustCommand` to trust it later.',
      );
    }

    await trust(scan.root);
  }

  Map<String, dynamic> _read() {
    try {
      if (!file.existsSync()) return <String, dynamic>{};
      final decoded = jsonDecode(file.readAsStringSync());
      final trusted =
          decoded is Map<String, dynamic> ? decoded['trusted'] : null;
      return trusted is Map<String, dynamic>
          ? Map<String, dynamic>.of(trusted)
          : <String, dynamic>{};
    } on FileSystemException {
      // Unreadable trust fails closed: ask again.
      return <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  Future<void> _write(Map<String, dynamic> trusted) {
    // Atomic, so a crash never leaves a half-written trust file.
    return writePrivateFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(
        <String, dynamic>{'version': 1, 'trusted': trusted},
      ),
    );
  }

  static bool _exists(String entityPath) {
    return FileSystemEntity.typeSync(entityPath, followLinks: false) !=
        FileSystemEntityType.notFound;
  }

  static String _realPath(String directory) {
    try {
      return Directory(directory).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path.normalize(path.absolute(directory));
    }
  }
}

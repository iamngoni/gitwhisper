import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

const acpRegistryUrl =
    'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json';
const acpSupportIssueUrl = 'https://github.com/iamngoni/gitwhisper/issues/new';

class AcpRegistryException implements Exception {
  const AcpRegistryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AcpAgentDefinition {
  const AcpAgentDefinition({
    required this.id,
    required this.name,
    required this.version,
    this.npxPackage,
    this.npxArgs = const <String>[],
    this.npxEnv = const <String, String>{},
    this.binaryDistributions = const <String, AcpBinaryDistribution>{},
  });

  factory AcpAgentDefinition.fromJson(Map<String, dynamic> json) {
    final distribution = json['distribution'];
    final npx =
        distribution is Map<String, dynamic> ? distribution['npx'] : null;
    final npxMap = npx is Map<String, dynamic> ? npx : null;
    final binary =
        distribution is Map<String, dynamic> ? distribution['binary'] : null;
    final binaryMap = binary is Map<String, dynamic> ? binary : null;
    final rawArgs = npxMap?['args'];
    final rawEnv = npxMap?['env'];

    return AcpAgentDefinition(
      id: json['id'].toString(),
      name: json['name'].toString(),
      version: json['version'].toString(),
      npxPackage: npxMap?['package']?.toString(),
      npxArgs: rawArgs is List<dynamic>
          ? rawArgs.map((arg) => arg.toString()).toList()
          : const <String>[],
      npxEnv: rawEnv is Map<dynamic, dynamic>
          ? rawEnv.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const <String, String>{},
      binaryDistributions: binaryMap == null
          ? const <String, AcpBinaryDistribution>{}
          : binaryMap.map(
              (platform, value) => MapEntry(
                platform,
                AcpBinaryDistribution.fromJson(
                  value as Map<String, dynamic>,
                ),
              ),
            ),
    );
  }
  final String id;
  final String name;
  final String version;
  final String? npxPackage;
  final List<String> npxArgs;
  final Map<String, String> npxEnv;
  final Map<String, AcpBinaryDistribution> binaryDistributions;

  bool get isSupportedCommitAgent {
    return !AcpRegistry.unsupportedCommitAgentIds.contains(id);
  }

  AcpLaunchCommand toLaunchCommand() {
    final package = npxPackage;
    if (package == null || package.isEmpty) {
      throw AcpRegistryException(
        'ACP agent "$id" does not have an npx distribution GitWhisper can '
        'launch yet. File an issue if you want this agent supported: '
        '$acpSupportIssueUrl',
      );
    }

    return AcpLaunchCommand(
      executable: 'npx',
      arguments: <String>['-y', package, ...npxArgs],
      environment: npxEnv,
    );
  }
}

class AcpBinaryDistribution {
  const AcpBinaryDistribution({
    required this.archive,
    required this.command,
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
  });

  factory AcpBinaryDistribution.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['args'];
    final rawEnv = json['env'];

    return AcpBinaryDistribution(
      archive: json['archive'].toString(),
      command: json['cmd'].toString(),
      arguments: rawArgs is List<dynamic>
          ? rawArgs.map((arg) => arg.toString()).toList()
          : const <String>[],
      environment: rawEnv is Map<dynamic, dynamic>
          ? rawEnv.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const <String, String>{},
    );
  }

  final String archive;
  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
}

class AcpLaunchCommand {
  const AcpLaunchCommand({
    required this.executable,
    required this.arguments,
    this.environment = const <String, String>{},
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;
}

class AcpRegistry {
  const AcpRegistry(this.agents);

  factory AcpRegistry.fromJson(Map<String, dynamic> json) {
    final rawAgents = json['agents'];
    if (rawAgents is! List<dynamic>) {
      throw const FormatException('ACP registry did not include agents.');
    }

    return AcpRegistry(
      rawAgents
          .whereType<Map<String, dynamic>>()
          .map(AcpAgentDefinition.fromJson)
          .toList(),
    );
  }

  final List<AcpAgentDefinition> agents;

  List<AcpAgentDefinition> get supportedCommitAgents {
    return agents.where((agent) => agent.isSupportedCommitAgent).toList();
  }

  AcpAgentDefinition resolve(String query) {
    return _resolveFrom(query, agents, includeUnsupportedMessage: false);
  }

  AcpAgentDefinition resolveSupported(String query) {
    return _resolveFrom(query, supportedCommitAgents);
  }

  AcpAgentDefinition _resolveFrom(
    String query,
    List<AcpAgentDefinition> candidates, {
    bool includeUnsupportedMessage = true,
  }) {
    final normalizedQuery = _normalize(query);
    final alias = _knownAliases[normalizedQuery];
    if (alias != null) {
      return _findExact(alias, candidates) ??
          (throw AcpRegistryException(
            'ACP registry did not include "$alias" for "$query". File an '
            'issue if this agent should be supported: $acpSupportIssueUrl',
          ));
    }

    final exact = _findExact(query, candidates);
    if (exact != null) return exact;

    final matches = candidates.where((agent) {
      final id = _normalize(agent.id);
      final name = _normalize(agent.name);
      return id.contains(normalizedQuery) || name.contains(normalizedQuery);
    }).toList();

    if (matches.length == 1) return matches.single;

    if (matches.length > 1) {
      final choices = matches.map((agent) => agent.id).join(', ');
      throw AcpRegistryException(
        'Found multiple ACP agents matching "$query": $choices. Use the exact '
        'agent id, or file an issue if GitWhisper should support an alias: '
        '$acpSupportIssueUrl',
      );
    }

    if (includeUnsupportedMessage) {
      final unsupportedMatches = agents.where((agent) {
        if (agent.isSupportedCommitAgent) return false;
        final id = _normalize(agent.id);
        final name = _normalize(agent.name);
        return id.contains(normalizedQuery) || name.contains(normalizedQuery);
      }).toList();
      if (unsupportedMatches.isNotEmpty) {
        final choices = unsupportedMatches.map((agent) => agent.id).join(', ');
        throw AcpRegistryException(
          'Found "$query" in the ACP registry, but GitWhisper does not target '
          'generic or unsupported ACP entries for commit generation: $choices. '
          'Use a first-party/product-backed agent, or file an issue if this '
          'agent should be supported: $acpSupportIssueUrl',
        );
      }
    }

    throw AcpRegistryException(
      'Could not find an ACP agent matching "$query". File an issue if this '
      'agent should be supported: $acpSupportIssueUrl',
    );
  }

  AcpAgentDefinition? _findExact(
    String query,
    List<AcpAgentDefinition> candidates,
  ) {
    final normalizedQuery = _normalize(query);
    for (final agent in candidates) {
      if (_normalize(agent.id) == normalizedQuery ||
          _normalize(agent.name) == normalizedQuery) {
        return agent;
      }
    }
    return null;
  }

  static String _normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');
  }

  static const _knownAliases = <String, String>{
    'codex': 'codex-acp',
    'claudecode': 'claude-acp',
    'claudeagent': 'claude-acp',
  };

  /// ACP registry ids that GitWhisper does not target for commit generation.
  ///
  /// GitWhisper only drives **first-party, product-backed coding agents** — ones
  /// that ship as a branded product with their own authentication and a managed
  /// model (Codex, Claude Code, Gemini CLI, Cursor, Copilot, etc.). Their commit
  /// output is predictable and something we can support.
  ///
  /// The entries below are excluded because they are not that:
  /// - Marketplaces / pay-per-call brokers: `agoragentic-acp`.
  /// - Agent frameworks / SDKs (build-your-own-agent, not a product):
  ///   `deepagents`, `fast-agent`.
  /// - Generic / open-source / bring-your-own-provider coding agents and ACP
  ///   adapters, whose model and output quality vary by user setup:
  ///   `corust-agent`, `crow-cli`, `glm-acp-agent`, `goose`, `minion-code`,
  ///   `opencode`, `pi-acp`, `sigit`, `vtcode`.
  ///
  /// They remain visible via `gw acp list --all` (marked "not used for
  /// commits"). To support one, remove it here and file an issue.
  static const unsupportedCommitAgentIds = <String>{
    'agoragentic-acp',
    'corust-agent',
    'crow-cli',
    'deepagents',
    'fast-agent',
    'glm-acp-agent',
    'goose',
    'minion-code',
    'opencode',
    'pi-acp',
    'sigit',
    'vtcode',
  };
}

class AcpRegistryLoader {
  AcpRegistryLoader({
    Dio? dio,
    File? cacheFile,
    this.registryUrl = acpRegistryUrl,
    this.cacheTtl = const Duration(hours: 6),
  })  : _dio = dio ?? Dio(),
        _cacheFile = cacheFile ?? _defaultCacheFile();

  final Dio _dio;
  final File _cacheFile;
  final String registryUrl;

  /// How long a cached registry is considered fresh before a network refresh
  /// is attempted. A fresh cache is used immediately, keeping the commit hot
  /// path off the network.
  final Duration cacheTtl;

  File get cacheFile => _cacheFile;

  /// Loads the registry, preferring a fresh on-disk cache.
  ///
  /// When the cache is missing or older than [cacheTtl] (or [forceRefresh] is
  /// set), the latest registry is fetched from [registryUrl] and the cache is
  /// updated. Network failures fall back to any existing cache so commits keep
  /// working offline.
  Future<AcpRegistry> load({bool forceRefresh = false}) async {
    if (!forceRefresh && _isCacheFresh()) {
      final cached = _readCache();
      if (cached != null) return cached;
    }

    try {
      final response = await _dio.get<String>(registryUrl);
      final body = response.data;
      if (response.statusCode == 200 && body != null && body.isNotEmpty) {
        await _cacheFile.parent.create(recursive: true);
        await _cacheFile.writeAsString(body);
        return AcpRegistry.fromJson(jsonDecode(body) as Map<String, dynamic>);
      }
    } on Object {
      // Fall through to cache.
    }

    final cached = _readCache();
    if (cached != null) return cached;

    throw AcpRegistryException(
      'Could not load the ACP registry from $registryUrl and no cached '
      'registry exists at ${_cacheFile.path}. Check your connection and try '
      'again. If your agent is missing from the registry, file an issue: '
      '$acpSupportIssueUrl',
    );
  }

  bool _isCacheFresh() {
    if (!_cacheFile.existsSync()) return false;
    final age = DateTime.now().difference(_cacheFile.statSync().modified);
    return age >= Duration.zero && age < cacheTtl;
  }

  AcpRegistry? _readCache() {
    if (!_cacheFile.existsSync()) return null;
    final body = _cacheFile.readAsStringSync();
    if (body.trim().isEmpty) return null;
    return AcpRegistry.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  static File _defaultCacheFile() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return File(
      path.join(home, '.gitwhisper', 'acp', 'registry.json'),
    );
  }
}

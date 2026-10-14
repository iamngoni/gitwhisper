import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as path;

import '../acp/acp_launcher.dart';
import '../acp/acp_registry.dart';
import '../acp/acp_repo_trust.dart';
import '../user_home.dart';

class AcpCommand extends Command<int> {
  AcpCommand({
    required Logger logger,
    AcpRegistryLoader? registryLoader,
    AcpAgentLauncher? agentLauncher,
    AcpTrustedRepos? trustedRepos,
  }) {
    final loader = registryLoader ?? AcpRegistryLoader();
    final launcher = agentLauncher ?? AcpAgentLauncher();
    final trusted = trustedRepos ?? AcpTrustedRepos();

    addSubcommand(
      AcpListCommand(
        logger: logger,
        registryLoader: loader,
        agentLauncher: launcher,
      ),
    );
    addSubcommand(
      AcpInfoCommand(
        logger: logger,
        registryLoader: loader,
        agentLauncher: launcher,
      ),
    );
    addSubcommand(
      AcpResolveCommand(
        logger: logger,
        registryLoader: loader,
        agentLauncher: launcher,
      ),
    );
    addSubcommand(
      AcpInstallCommand(
        logger: logger,
        registryLoader: loader,
        agentLauncher: launcher,
      ),
    );
    addSubcommand(
      AcpCacheCommand(
        logger: logger,
        registryLoader: loader,
        agentLauncher: launcher,
        trustedRepos: trusted,
      ),
    );
    addSubcommand(AcpTrustCommand(logger: logger, trustedRepos: trusted));
    addSubcommand(AcpUntrustCommand(logger: logger, trustedRepos: trusted));
  }

  @override
  String get description => 'Manage ACP local agents';

  @override
  String get name => 'acp';
}

class AcpListCommand extends Command<int> {
  AcpListCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
    required AcpAgentLauncher agentLauncher,
  })  : _logger = logger,
        _registryLoader = registryLoader,
        _agentLauncher = agentLauncher {
    argParser.addFlag(
      'all',
      help: 'Show every registry entry, including agents GitWhisper does not '
          'target for commit generation.',
      negatable: false,
    );
  }

  final Logger _logger;
  final AcpRegistryLoader _registryLoader;
  final AcpAgentLauncher _agentLauncher;

  @override
  String get description => 'List ACP agents from the registry';

  @override
  String get name => 'list';

  @override
  Future<int> run() async {
    try {
      final registry = await _registryLoader.load();
      final showAll = argResults?['all'] == true;
      final agents = [
        ...(showAll ? registry.agents : registry.supportedCommitAgents),
      ]..sort((a, b) => a.id.compareTo(b.id));

      _logger.info(showAll ? 'ACP agents:' : 'ACP commit agents:');
      for (final agent in agents) {
        final supportNote =
            agent.isSupportedCommitAgent ? '' : ' (not used for commits)';
        _logger
          ..info(
            '  - ${agent.id} (${agent.name}) v${agent.version}$supportNote',
          )
          ..info(
            '    Launcher: ${_agentLauncher.describeLaunchSupport(agent)}',
          );
      }

      return ExitCode.success.code;
    } on AcpRegistryException catch (error) {
      _logger.err(error.message);
      return ExitCode.software.code;
    } on FormatException catch (error) {
      _logger.err('ACP registry is not valid: ${error.message}');
      return ExitCode.software.code;
    } on UserHomeException catch (error) {
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

class AcpInfoCommand extends Command<int> {
  AcpInfoCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
    required AcpAgentLauncher agentLauncher,
  })  : _logger = logger,
        _registryLoader = registryLoader,
        _agentLauncher = agentLauncher;

  final Logger _logger;
  final AcpRegistryLoader _registryLoader;
  final AcpAgentLauncher _agentLauncher;

  @override
  String get description => 'Show ACP agent details';

  @override
  String get name => 'info';

  @override
  Future<int> run() async {
    final query = argResults?.rest.firstOrNull;
    if (query == null) {
      _logger.err('Usage: gitwhisper acp info <agent>');
      return ExitCode.usage.code;
    }

    try {
      final agent = (await _registryLoader.load()).resolve(query);
      _printAgentInfo(_logger, _agentLauncher, agent);
      return ExitCode.success.code;
    } on AcpRegistryException catch (error) {
      _logger.err(error.message);
      return ExitCode.software.code;
    } on UserHomeException catch (error) {
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

class AcpResolveCommand extends Command<int> {
  AcpResolveCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
    required AcpAgentLauncher agentLauncher,
  })  : _logger = logger,
        _registryLoader = registryLoader,
        _agentLauncher = agentLauncher;

  final Logger _logger;
  final AcpRegistryLoader _registryLoader;
  final AcpAgentLauncher _agentLauncher;

  @override
  String get description => 'Resolve an ACP alias or agent name';

  @override
  String get name => 'resolve';

  @override
  Future<int> run() async {
    final query = argResults?.rest.firstOrNull;
    if (query == null) {
      _logger.err('Usage: gitwhisper acp resolve <agent>');
      return ExitCode.usage.code;
    }

    try {
      final agent = (await _registryLoader.load()).resolveSupported(query);
      _logger
        ..info('$query -> ${agent.id}')
        ..info('Launcher: ${_agentLauncher.describeLaunchSupport(agent)}');
      return ExitCode.success.code;
    } on AcpRegistryException catch (error) {
      _logger.err(error.message);
      return ExitCode.software.code;
    } on UserHomeException catch (error) {
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

class AcpInstallCommand extends Command<int> {
  AcpInstallCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
    required AcpAgentLauncher agentLauncher,
  })  : _logger = logger,
        _registryLoader = registryLoader,
        _agentLauncher = agentLauncher;

  final Logger _logger;
  final AcpRegistryLoader _registryLoader;
  final AcpAgentLauncher _agentLauncher;

  @override
  String get description =>
      'Install an ACP agent into the local cache and approve it to run';

  @override
  String get name => 'install';

  @override
  Future<int> run() async {
    final query = argResults?.rest.firstOrNull;
    if (query == null) {
      _logger.err('Usage: gitwhisper acp install <agent>');
      return ExitCode.usage.code;
    }

    final progress = _logger.progress('Resolving ACP agent $query');
    var progressFailed = false;
    try {
      final agent = (await _registryLoader.load()).resolve(query);
      progress
          .update('Installing ${agent.id} for ${_agentLauncher.platformKey}');
      try {
        // Installing is explicit consent: the launcher records the agent as
        // approved to run, bound to exactly what was installed.
        final source = await _agentLauncher.install(
          agent,
          onStatus: progress.update,
        );
        progress.complete(
          'Ready to launch ${agent.id} for ${_agentLauncher.platformKey}',
        );
        _logger.info('Approved ${agent.id} v${agent.version} to run:');
        for (final line in source.details) {
          _logger.info('  $line');
        }
      } on Object {
        progressFailed = true;
        progress.fail('Failed to install ${agent.id}');
        rethrow;
      }
      return ExitCode.success.code;
    } on AcpRegistryException catch (error) {
      if (!progressFailed) progress.fail('Failed to resolve $query');
      _logger.err(error.message);
      return ExitCode.software.code;
    } on UserHomeException catch (error) {
      if (!progressFailed) progress.fail('Failed to resolve $query');
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

class AcpCacheCommand extends Command<int> {
  AcpCacheCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
    required AcpAgentLauncher agentLauncher,
    required AcpTrustedRepos trustedRepos,
  }) {
    addSubcommand(
      AcpCachePathCommand(
        logger: logger,
        registryLoader: registryLoader,
        agentLauncher: agentLauncher,
        trustedRepos: trustedRepos,
      ),
    );
    addSubcommand(
      AcpCacheRefreshCommand(
        logger: logger,
        registryLoader: registryLoader,
      ),
    );
  }

  @override
  String get description => 'Manage the ACP registry and agent cache';

  @override
  String get name => 'cache';
}

class AcpCachePathCommand extends Command<int> {
  AcpCachePathCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
    required AcpAgentLauncher agentLauncher,
    required AcpTrustedRepos trustedRepos,
  })  : _logger = logger,
        _registryLoader = registryLoader,
        _agentLauncher = agentLauncher,
        _trustedRepos = trustedRepos;

  final Logger _logger;
  final AcpRegistryLoader _registryLoader;
  final AcpAgentLauncher _agentLauncher;
  final AcpTrustedRepos _trustedRepos;

  @override
  String get description => 'Show ACP cache paths';

  @override
  String get name => 'path';

  @override
  Future<int> run() async {
    try {
      _logger
        ..info('Registry cache: ${_registryLoader.cacheFile.path}')
        ..info('Agent cache: ${_agentLauncher.cacheDirectory.path}')
        ..info('Approved agents: ${_agentLauncher.approvals.file.path}')
        ..info('Trusted repositories: ${_trustedRepos.file.path}');
      return ExitCode.success.code;
    } on UserHomeException catch (error) {
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

class AcpCacheRefreshCommand extends Command<int> {
  AcpCacheRefreshCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
  })  : _logger = logger,
        _registryLoader = registryLoader;

  final Logger _logger;
  final AcpRegistryLoader _registryLoader;

  @override
  String get description => 'Refresh the ACP registry cache';

  @override
  String get name => 'refresh';

  @override
  Future<int> run() async {
    try {
      final registry = await _registryLoader.load(forceRefresh: true);
      _logger.success(
        'Refreshed ACP registry cache with ${registry.agents.length} agents.',
      );
      return ExitCode.success.code;
    } on AcpRegistryException catch (error) {
      _logger.err(error.message);
      return ExitCode.software.code;
    } on UserHomeException catch (error) {
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

class AcpTrustCommand extends Command<int> {
  AcpTrustCommand({
    required Logger logger,
    required AcpTrustedRepos trustedRepos,
  })  : _logger = logger,
        _trustedRepos = trustedRepos;

  final Logger _logger;
  final AcpTrustedRepos _trustedRepos;

  @override
  String get description =>
      "Let ACP agents use a repository's agent configuration (hooks, MCP "
      'servers, npm config). Defaults to the current directory.';

  @override
  String get name => 'trust';

  @override
  String get invocation => 'gitwhisper acp trust [path]';

  @override
  Future<int> run() async {
    final target = argResults?.rest.firstOrNull ?? Directory.current.path;
    if (!Directory(target).existsSync()) {
      _logger.err('Not a directory: $target');
      return ExitCode.usage.code;
    }

    try {
      final scan = AcpTrustedRepos.scan(target);
      await _trustedRepos.trust(scan.root);
      _logger.success('Trusted ${scan.root} for ACP agents.');
      if (scan.agentConfig.isEmpty) {
        _logger.info('It has no agent configuration GitWhisper checks for.');
      } else {
        _logger.info('ACP agents may run commands from its agent config:');
        for (final config in scan.agentConfig) {
          _logger.info('  ${config.displayPath}  ${config.description}');
        }
      }
      return ExitCode.success.code;
    } on UserHomeException catch (error) {
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

class AcpUntrustCommand extends Command<int> {
  AcpUntrustCommand({
    required Logger logger,
    required AcpTrustedRepos trustedRepos,
  })  : _logger = logger,
        _trustedRepos = trustedRepos;

  final Logger _logger;
  final AcpTrustedRepos _trustedRepos;

  @override
  String get description =>
      'Stop trusting a repository trusted with `gitwhisper acp trust`. '
      'Defaults to the current directory.';

  @override
  String get name => 'untrust';

  @override
  String get invocation => 'gitwhisper acp untrust [path]';

  @override
  Future<int> run() async {
    final target = argResults?.rest.firstOrNull ?? Directory.current.path;
    // A deleted repository can still be untrusted by its old path.
    final root = Directory(target).existsSync()
        ? AcpTrustedRepos.scan(target).root
        : path.normalize(path.absolute(target));

    try {
      if (await _trustedRepos.untrust(root)) {
        _logger.success('No longer trusting $root for ACP agents.');
      } else {
        _logger.info('$root was not trusted.');
      }
      return ExitCode.success.code;
    } on UserHomeException catch (error) {
      _logger.err(error.message);
      return ExitCode.config.code;
    }
  }
}

void _printAgentInfo(
  Logger logger,
  AcpAgentLauncher launcher,
  AcpAgentDefinition agent,
) {
  logger
    ..info('${agent.id} (${agent.name})')
    ..info('Version: ${agent.version}')
    ..info('Launcher: ${launcher.describeLaunchSupport(agent)}')
    ..info('Readiness: not verified');

  if (agent.npxPackage != null) {
    logger.info('NPX: ${agent.npxPackage}');
  }

  if (agent.binaryDistributions.isNotEmpty) {
    logger.info('Binary platforms:');
    for (final entry in agent.binaryDistributions.entries) {
      final binary = entry.value;
      logger
        ..info('  - ${entry.key}: ${binary.command}')
        ..info('    Archive: ${binary.archive}')
        ..info('    SHA-256: ${binary.sha256 ?? 'not published'}');
    }
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

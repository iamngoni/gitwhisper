import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../acp/acp_launcher.dart';
import '../acp/acp_registry.dart';

class AcpCommand extends Command<int> {
  AcpCommand({
    required Logger logger,
    AcpRegistryLoader? registryLoader,
    AcpAgentLauncher? agentLauncher,
  }) {
    final loader = registryLoader ?? AcpRegistryLoader();
    final launcher = agentLauncher ?? AcpAgentLauncher();

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
      ),
    );
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
        _agentLauncher = agentLauncher;

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
      final agents = [...registry.agents]..sort((a, b) => a.id.compareTo(b.id));

      _logger.info('ACP agents:');
      for (final agent in agents) {
        _logger
          ..info('  - ${agent.id} (${agent.name}) v${agent.version}')
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
      final agent = (await _registryLoader.load()).resolve(query);
      _logger
        ..info('$query -> ${agent.id}')
        ..info('Launcher: ${_agentLauncher.describeLaunchSupport(agent)}');
      return ExitCode.success.code;
    } on AcpRegistryException catch (error) {
      _logger.err(error.message);
      return ExitCode.software.code;
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
  String get description => 'Install an ACP binary agent into the local cache';

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
        await _agentLauncher.install(
          agent,
          onStatus: progress.update,
        );
        progress.complete(
          'Ready to launch ${agent.id} for ${_agentLauncher.platformKey}',
        );
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
    }
  }
}

class AcpCacheCommand extends Command<int> {
  AcpCacheCommand({
    required Logger logger,
    required AcpRegistryLoader registryLoader,
    required AcpAgentLauncher agentLauncher,
  }) {
    addSubcommand(
      AcpCachePathCommand(
        logger: logger,
        registryLoader: registryLoader,
        agentLauncher: agentLauncher,
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
  })  : _logger = logger,
        _registryLoader = registryLoader,
        _agentLauncher = agentLauncher;

  final Logger _logger;
  final AcpRegistryLoader _registryLoader;
  final AcpAgentLauncher _agentLauncher;

  @override
  String get description => 'Show ACP cache paths';

  @override
  String get name => 'path';

  @override
  Future<int> run() async {
    _logger
      ..info('Registry cache: ${_registryLoader.cacheFile.path}')
      ..info('Agent cache: ${_agentLauncher.cacheDirectory.path}');
    return ExitCode.success.code;
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
      final registry = await _registryLoader.load();
      _logger.success(
        'Refreshed ACP registry cache with ${registry.agents.length} agents.',
      );
      return ExitCode.success.code;
    } on AcpRegistryException catch (error) {
      _logger.err(error.message);
      return ExitCode.software.code;
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
      logger.info('  - ${entry.key}: ${entry.value.command}');
    }
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

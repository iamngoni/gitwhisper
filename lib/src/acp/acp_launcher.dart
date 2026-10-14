import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import 'acp_client.dart';
import 'acp_consent.dart';
import 'acp_registry.dart';

typedef AcpBinaryInstaller = Future<void> Function(
  AcpBinaryDistribution binary,
  Directory installDirectory,
);

typedef AcpNpmInstaller = Future<void> Function(
  String packageSpec,
  Directory installDirectory,
);

typedef AcpInstallStatusCallback = void Function(String status);

class AcpAgentLauncher {
  AcpAgentLauncher({
    Directory? cacheDirectory,
    String? platformKey,
    Dio? dio,
    AcpBinaryInstaller? installBinary,
    AcpNpmInstaller? installNpm,
    AcpAgentApprovals? approvals,
  })  : _cacheDirectory = cacheDirectory ?? _defaultAgentCacheDirectory(),
        _platformKey = platformKey ?? currentPlatformKey(),
        _dio = dio ?? Dio(),
        _installBinary = installBinary,
        _installNpm = installNpm,
        _approvalsOverride = approvals;

  final Directory _cacheDirectory;
  final String _platformKey;
  final Dio _dio;
  final AcpBinaryInstaller? _installBinary;
  final AcpNpmInstaller? _installNpm;
  final AcpAgentApprovals? _approvalsOverride;

  /// Agent launches the user has approved. By default these are stored in
  /// the agent cache directory.
  late final AcpAgentApprovals approvals =
      _approvalsOverride ?? AcpAgentApprovals.inCacheDirectory(_cacheDirectory);

  Directory get cacheDirectory => _cacheDirectory;

  String get platformKey => _platformKey;

  /// Describes exactly what launching [agent] runs on this platform: the npm
  /// package, or the binary archive, its checksum and the command. Throws
  /// [AcpRegistryException] when the agent cannot be launched here or its
  /// registry entry is unsafe (non-HTTPS download, malformed checksum,
  /// command outside the archive).
  AcpLaunchSource launchSourceFor(AcpAgentDefinition agent) {
    _validatePathSegment(agent.id, 'id', agent);
    _validatePathSegment(agent.version, 'version', agent);

    final package = agent.npxPackage;
    if (package != null && package.isNotEmpty) {
      final command = <String>['npx', '-y', package, ...agent.npxArgs];
      return AcpLaunchSource(
        fingerprint: jsonEncode(<String, dynamic>{
          'npx': package,
          'args': agent.npxArgs,
          'env': agent.npxEnv,
        }),
        details: <String>[
          'npm package: $package',
          'Command: ${formatCommandLine(command)}',
          ..._environmentDetails(agent.npxEnv),
        ],
      );
    }

    final binary = agent.binaryDistributions[_platformKey];
    if (binary == null) {
      final supported = agent.binaryDistributions.keys.join(', ');
      throw AcpRegistryException(
        'ACP agent "${agent.id}" does not publish an npx package or a binary '
        'for $_platformKey. Supported binary platforms: $supported',
      );
    }

    _validateArchiveUrl(agent, binary.archive);
    if (binary.sha256 != null && !binary.hasValidSha256) {
      throw AcpRegistryException(
        'ACP registry entry for "${agent.id}" has a malformed sha256 '
        '("${binary.sha256}"), so its download cannot be verified.',
      );
    }
    _validateCommandPath(agent, binary.command);

    final checksum = binary.sha256 != null
        ? 'SHA-256: ${binary.sha256} (verified after download)'
        : 'SHA-256: not published by the ACP registry, so the download '
            'cannot be verified';
    final command = formatCommandLine(
      <String>[binary.command, ...binary.arguments],
    );
    return AcpLaunchSource(
      fingerprint: jsonEncode(<String, dynamic>{
        'archive': binary.archive,
        'sha256': binary.sha256,
        'cmd': binary.command,
        'args': binary.arguments,
        'env': binary.environment,
      }),
      details: <String>[
        'Download: ${binary.archive}',
        checksum,
        'Command: $command',
        ..._environmentDetails(binary.environment),
      ],
    );
  }

  /// Returns when [agent] may run, asking the user on its first launch.
  /// Throws [AcpLaunchNotApprovedException] when it may not.
  Future<void> ensureLaunchApproved(AcpAgentDefinition agent) {
    return approvals.ensureApproved(agent, launchSourceFor(agent));
  }

  Future<AcpLaunchCommand> launchCommandFor(
    AcpAgentDefinition agent, {
    AcpInstallStatusCallback? onStatus,
  }) async {
    await ensureLaunchApproved(agent);

    final installedNpmCommand = _installedNpmLaunchCommand(agent);
    if (installedNpmCommand != null) {
      onStatus?.call('Using installed npm package ${agent.npxPackage}');
      return installedNpmCommand;
    }

    final npxCommand = _npxLaunchCommand(agent);
    if (npxCommand != null) {
      onStatus?.call('Using npx package ${agent.npxPackage}');
      return npxCommand;
    }

    final binary = agent.binaryDistributions[_platformKey];
    if (binary == null) {
      final supported = agent.binaryDistributions.keys.join(', ');
      throw AcpRegistryException(
        'ACP agent "${agent.id}" does not publish an npx package or a binary '
        'for $_platformKey. Supported binary platforms: $supported',
      );
    }

    final installDirectory = _installDirectoryFor(agent);
    await _installBinaryIfNeeded(
      binary,
      installDirectory,
      onStatus: onStatus,
    );

    final executable = _resolveCommandPath(installDirectory, binary.command);

    return AcpLaunchCommand(
      executable: executable,
      arguments: binary.arguments,
      environment: binary.environment,
      workingDirectory: installDirectory.path,
    );
  }

  /// Resolves the command for an agent's terminal login. The caller must show
  /// the result to the user and ask before running it. A fallback login
  /// command can come from the agent's error text.
  Future<AcpLaunchCommand> authLaunchCommandFor(
    AcpAgentDefinition agent,
    AcpAuthMethod method, {
    AcpInstallStatusCallback? onStatus,
  }) async {
    await ensureLaunchApproved(agent);

    if (method.command.isNotEmpty) {
      final package = agent.npxPackage;
      if (package != null && package.isNotEmpty) {
        final installedNpmCommand = _installedNpmLaunchCommand(
          agent,
          arguments: method.command.skip(1).toList(),
          environment: <String, String>{
            ...agent.npxEnv,
            ...method.environment,
          },
        );
        if (installedNpmCommand != null) {
          onStatus?.call('Using installed npm package $package');
          return installedNpmCommand;
        }

        return AcpLaunchCommand(
          executable: 'npx',
          arguments: <String>['-y', package, ...method.command.skip(1)],
          environment: <String, String>{
            ...agent.npxEnv,
            ...method.environment,
          },
        );
      }

      final binary = agent.binaryDistributions[_platformKey];
      if (binary != null) {
        final installDirectory = _installDirectoryFor(agent);
        await _installBinaryIfNeeded(
          binary,
          installDirectory,
          onStatus: onStatus,
        );
        final executable =
            _resolveCommandPath(installDirectory, binary.command);
        final suggestedExecutable = method.command.first;
        final executableName = path.basename(executable).toLowerCase();
        final normalizedSuggestion = suggestedExecutable.toLowerCase();
        if (executableName == normalizedSuggestion ||
            executableName.startsWith(normalizedSuggestion) ||
            executableName.endsWith('-$normalizedSuggestion')) {
          return AcpLaunchCommand(
            executable: executable,
            arguments: method.command.skip(1).toList(),
            environment: method.environment,
            workingDirectory: installDirectory.path,
          );
        }
      }

      return AcpLaunchCommand(
        executable: method.command.first,
        arguments: method.command.skip(1).toList(),
        environment: method.environment,
      );
    }

    final package = agent.npxPackage;
    if (package != null && package.isNotEmpty) {
      final installedNpmCommand = _installedNpmLaunchCommand(
        agent,
        arguments: method.args,
        environment: <String, String>{
          ...agent.npxEnv,
          ...method.environment,
        },
      );
      if (installedNpmCommand != null) {
        onStatus?.call('Using installed npm package $package');
        return installedNpmCommand;
      }

      return AcpLaunchCommand(
        executable: 'npx',
        arguments: <String>['-y', package, ...method.args],
        environment: <String, String>{
          ...agent.npxEnv,
          ...method.environment,
        },
      );
    }

    final binary = agent.binaryDistributions[_platformKey];
    if (binary == null) {
      await launchCommandFor(agent, onStatus: onStatus);
      throw AcpRegistryException(
        'ACP agent "${agent.id}" cannot be launched for authentication on '
        '$_platformKey.',
      );
    }

    final installDirectory = _installDirectoryFor(agent);
    await _installBinaryIfNeeded(
      binary,
      installDirectory,
      onStatus: onStatus,
    );
    return AcpLaunchCommand(
      executable: _resolveCommandPath(installDirectory, binary.command),
      arguments: method.args,
      environment: method.environment,
      workingDirectory: installDirectory.path,
    );
  }

  String describeLaunchSupport(AcpAgentDefinition agent) {
    if (_installedNpmLaunchCommand(agent) != null) {
      return 'npm package installed for $_platformKey';
    }

    if (_npxLaunchCommand(agent) != null) {
      return 'npx -y ${agent.npxPackage}';
    }

    final binary = agent.binaryDistributions[_platformKey];
    if (binary != null) {
      final installDirectory = _installDirectoryFor(agent);
      final executable = _resolveCommandPath(installDirectory, binary.command);
      if (File(executable).existsSync()) {
        return 'binary installed for $_platformKey';
      }
      return 'binary available for $_platformKey';
    }

    if (agent.binaryDistributions.isNotEmpty) {
      return 'binary unavailable for $_platformKey';
    }

    return 'no launch distribution';
  }

  /// Installs [agent] into the cache. Running `gw acp install` is explicit
  /// consent, so this also records the agent as approved to launch.
  Future<AcpLaunchSource> install(
    AcpAgentDefinition agent, {
    AcpInstallStatusCallback? onStatus,
  }) async {
    final source = launchSourceFor(agent);
    await approvals.approve(agent, source);

    final package = agent.npxPackage;
    if (package != null && package.isNotEmpty) {
      await _installNpmIfNeeded(agent, onStatus: onStatus);
      return source;
    }

    final binary = agent.binaryDistributions[_platformKey]!;
    final installDirectory = _installDirectoryFor(agent);
    await _installBinaryIfNeeded(
      binary,
      installDirectory,
      onStatus: onStatus,
    );
    return source;
  }

  AcpLaunchCommand? _npxLaunchCommand(AcpAgentDefinition agent) {
    final package = agent.npxPackage;
    if (package == null || package.isEmpty) return null;

    return AcpLaunchCommand(
      executable: 'npx',
      arguments: <String>['-y', package, ...agent.npxArgs],
      environment: agent.npxEnv,
    );
  }

  AcpLaunchCommand? _installedNpmLaunchCommand(
    AcpAgentDefinition agent, {
    List<String>? arguments,
    Map<String, String>? environment,
  }) {
    final package = agent.npxPackage;
    if (package == null || package.isEmpty) return null;

    final installDirectory = _npmInstallDirectoryFor(agent);
    final executable = _resolveInstalledNpmExecutable(agent, installDirectory);
    if (executable == null) return null;

    return AcpLaunchCommand(
      executable: executable,
      arguments: arguments ?? agent.npxArgs,
      environment: environment ?? agent.npxEnv,
      workingDirectory: installDirectory.path,
    );
  }

  Directory _installDirectoryFor(AcpAgentDefinition agent) {
    return Directory(
      path.join(
        _cacheDirectory.path,
        agent.id,
        agent.version,
        _platformKey,
      ),
    );
  }

  Directory _npmInstallDirectoryFor(AcpAgentDefinition agent) {
    return Directory(path.join(_installDirectoryFor(agent).path, 'npm'));
  }

  /// Registry ids and versions become cache directory names, so they must be
  /// plain path segments.
  void _validatePathSegment(
    String value,
    String field,
    AcpAgentDefinition agent,
  ) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._@+-]*$').hasMatch(value) ||
        value.contains('..')) {
      throw AcpRegistryException(
        'ACP registry entry "${agent.id}" has an unsafe $field "$value".',
      );
    }
  }

  void _validateArchiveUrl(AcpAgentDefinition agent, String url) {
    if (!_isHttpsUrl(url)) {
      throw AcpRegistryException(
        'ACP agent "${agent.id}" publishes its binary over a non-HTTPS URL '
        '($url). GitWhisper only downloads agents over HTTPS.',
      );
    }
  }

  /// The binary's command must point inside its extracted archive.
  void _validateCommandPath(AcpAgentDefinition agent, String command) {
    final probe = Directory(path.join(_cacheDirectory.path, '.probe'));
    final resolved = path.normalize(_resolveCommandPath(probe, command));
    if (path.isAbsolute(_stripDotSlash(command)) ||
        !path.isWithin(probe.path, resolved)) {
      throw AcpRegistryException(
        'ACP agent "${agent.id}" has a command outside its archive '
        '("$command").',
      );
    }
  }

  static bool _isHttpsUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  static List<String> _environmentDetails(Map<String, String> environment) {
    if (environment.isEmpty) return const <String>[];
    return <String>[
      'Environment: ${environment.entries.map(
            (entry) => '${entry.key}=${entry.value}',
          ).join(' ')}',
    ];
  }

  Future<void> _installNpmIfNeeded(
    AcpAgentDefinition agent, {
    AcpInstallStatusCallback? onStatus,
  }) async {
    final package = agent.npxPackage;
    if (package == null || package.isEmpty) return;

    final installDirectory = _npmInstallDirectoryFor(agent);
    final existing = _resolveInstalledNpmExecutable(agent, installDirectory);
    if (existing != null) {
      onStatus?.call('NPM package already installed');
      return;
    }

    if (installDirectory.existsSync()) {
      await installDirectory.delete(recursive: true);
    }
    await installDirectory.create(recursive: true);

    onStatus?.call('Installing npm package $package');
    final installNpm = _installNpm ?? _installNpmPackage;
    await installNpm(package, installDirectory);

    final executable = _resolveInstalledNpmExecutable(agent, installDirectory);
    if (executable == null) {
      throw AcpRegistryException(
        'Installed ACP npm package "$package", but no executable bin was '
        'found.',
      );
    }
  }

  Future<void> _installBinaryIfNeeded(
    AcpBinaryDistribution binary,
    Directory installDirectory, {
    AcpInstallStatusCallback? onStatus,
  }) async {
    final commandPath = _resolveCommandPath(installDirectory, binary.command);
    if (File(commandPath).existsSync()) {
      onStatus?.call('Binary already installed');
      return;
    }

    if (!_isHttpsUrl(binary.archive)) {
      throw AcpRegistryException(
        'Refusing to download ACP binary archive over a non-HTTPS URL: '
        '${binary.archive}',
      );
    }

    final installBinary = _installBinary;
    if (installBinary != null) {
      onStatus?.call('Installing test binary');
      await installDirectory.create(recursive: true);
      await installBinary(binary, installDirectory);
      return;
    }

    if (installDirectory.existsSync()) {
      await installDirectory.delete(recursive: true);
    }
    await installDirectory.create(recursive: true);

    final archiveFile = File(
      path.join(
        installDirectory.parent.path,
        '${installDirectory.basename}.tmp',
      ),
    );
    try {
      onStatus?.call('Downloading ${path.basename(binary.archive)}');
      await _downloadArchive(
        binary,
        archiveFile,
        onStatus: onStatus,
      );
      onStatus?.call('Extracting archive');
      await _extractArchive(archiveFile, installDirectory);
    } on Object {
      // Never leave a partial install that a later launch would trust.
      if (installDirectory.existsSync()) {
        await installDirectory.delete(recursive: true);
      }
      rethrow;
    } finally {
      await archiveFile.deleteIfExists();
    }

    if (!Platform.isWindows && File(commandPath).existsSync()) {
      onStatus?.call('Marking binary executable');
      await Process.run('chmod', ['+x', commandPath]);
    }
  }

  /// Downloads [binary]'s archive over HTTPS into [destination], verifying
  /// the registry's sha256 when it publishes one. Nothing is written when
  /// verification fails.
  Future<void> _downloadArchive(
    AcpBinaryDistribution binary,
    File destination, {
    AcpInstallStatusCallback? onStatus,
  }) async {
    final url = binary.archive;
    var lastPercent = -1;
    var lastStatusAt = DateTime.fromMillisecondsSinceEpoch(0);

    void updateDownloadStatus(String status, {int? percent}) {
      final now = DateTime.now();
      final elapsed = now.difference(lastStatusAt);
      final percentChangedEnough =
          percent != null && (percent == 100 || percent - lastPercent >= 5);
      final timeElapsed = elapsed.inMilliseconds >= 1000;

      if (lastStatusAt.millisecondsSinceEpoch != 0 &&
          !percentChangedEnough &&
          !timeElapsed) {
        return;
      }

      if (percent != null) lastPercent = percent;
      lastStatusAt = now;
      onStatus?.call(status);
    }

    final response = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: (received, total) {
        if (total <= 0) {
          updateDownloadStatus('Downloading ${_formatBytes(received)}');
          return;
        }
        final percent = (received / total * 100).clamp(0, 100).round();
        updateDownloadStatus(
          'Downloading $percent% '
          '(${_formatBytes(received)}/${_formatBytes(total)})',
          percent: percent,
        );
      },
    );
    final bytes = response.data;
    if (response.statusCode != 200 || bytes == null) {
      throw AcpRegistryException('Failed to download ACP binary archive: $url');
    }

    final finalUrl = response.realUri.toString();
    if (!_isHttpsUrl(finalUrl)) {
      throw AcpRegistryException(
        'ACP binary archive download for $url was redirected to a non-HTTPS '
        'URL ($finalUrl). The download was discarded.',
      );
    }

    final expected = binary.sha256;
    if (expected != null) {
      final actual = crypto.sha256.convert(bytes).toString();
      if (actual != expected) {
        throw AcpRegistryException(
          'Checksum mismatch for ACP binary archive $url: the registry '
          'publishes sha256 $expected but the download is $actual. The '
          'download was discarded.',
        );
      }
    }

    await destination.writeAsBytes(bytes, flush: true);
  }

  Future<void> _installNpmPackage(
    String packageSpec,
    Directory installDirectory,
  ) async {
    final result = await Process.run(
      'npm',
      <String>[
        'install',
        '--prefix',
        installDirectory.path,
        '--no-audit',
        '--no-fund',
        packageSpec,
      ],
    );

    if (result.exitCode != 0) {
      throw AcpRegistryException(
        'Failed to install ACP npm package $packageSpec: ${result.stderr}',
      );
    }
  }

  String? _resolveInstalledNpmExecutable(
    AcpAgentDefinition agent,
    Directory installDirectory,
  ) {
    final package = agent.npxPackage;
    if (package == null || package.isEmpty) return null;

    final packageName = _npmPackageName(package);
    final packageDirectory = Directory(
      path.joinAll(<String>[
        installDirectory.path,
        'node_modules',
        ...packageName.split('/'),
      ]),
    );
    final packageJsonFile =
        File(path.join(packageDirectory.path, 'package.json'));
    if (!packageJsonFile.existsSync()) return null;

    final packageJson = jsonDecode(packageJsonFile.readAsStringSync());
    if (packageJson is! Map<String, dynamic>) return null;

    final binName = _npmBinName(packageName, packageJson['bin']);
    if (binName == null || binName.isEmpty) return null;

    final binaryName = Platform.isWindows ? '$binName.cmd' : binName;
    final binary = File(
      path.join(installDirectory.path, 'node_modules', '.bin', binaryName),
    );
    if (binary.existsSync()) return binary.path;

    if (Platform.isWindows) {
      final ps1Binary = File(
        path.join(
          installDirectory.path,
          'node_modules',
          '.bin',
          '$binName.ps1',
        ),
      );
      if (ps1Binary.existsSync()) return ps1Binary.path;
    }

    return null;
  }

  String _npmPackageName(String packageSpec) {
    if (packageSpec.startsWith('@')) {
      final slashIndex = packageSpec.indexOf('/');
      if (slashIndex == -1) return packageSpec;
      final versionIndex = packageSpec.indexOf('@', slashIndex + 1);
      return versionIndex == -1
          ? packageSpec
          : packageSpec.substring(0, versionIndex);
    }

    final versionIndex = packageSpec.indexOf('@');
    return versionIndex == -1
        ? packageSpec
        : packageSpec.substring(0, versionIndex);
  }

  String? _npmBinName(String packageName, Object? bin) {
    final packageBaseName = packageName.split('/').last;
    if (bin is String && bin.isNotEmpty) return packageBaseName;
    if (bin is! Map) return null;

    if (bin.containsKey(packageBaseName)) return packageBaseName;

    for (final key in bin.keys) {
      final name = key.toString();
      if (name.isNotEmpty) return name;
    }

    return null;
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    final value = size >= 10 || unitIndex == 0
        ? size.toStringAsFixed(0)
        : size.toStringAsFixed(1);
    return '$value ${units[unitIndex]}';
  }

  Future<void> _extractArchive(File archive, Directory destination) async {
    final archivePath = archive.path;
    final result = archivePath.endsWith('.zip')
        ? await Process.run(
            'unzip',
            ['-oq', archivePath, '-d', destination.path],
          )
        : await Process.run(
            'tar',
            ['-xzf', archivePath, '-C', destination.path],
          );

    if (result.exitCode != 0) {
      throw AcpRegistryException(
        'Failed to extract ACP binary archive ${archive.path}: '
        '${result.stderr}',
      );
    }
  }

  String _resolveCommandPath(Directory directory, String command) {
    final normalizedCommand = _stripDotSlash(command);
    if (path.isAbsolute(normalizedCommand)) return normalizedCommand;
    return path.join(directory.path, normalizedCommand);
  }

  static String _stripDotSlash(String command) {
    return command.startsWith('./') || command.startsWith(r'.\')
        ? command.substring(2)
        : command;
  }

  static String currentPlatformKey() {
    final os = switch (Platform.operatingSystem) {
      'macos' => 'darwin',
      'linux' => 'linux',
      'windows' => 'windows',
      final other => other,
    };

    final arch = switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'aarch64',
      Abi.macosX64 || Abi.linuxX64 || Abi.windowsX64 => 'x86_64',
      final abi => abi.toString(),
    };

    return '$os-$arch';
  }

  static Directory _defaultAgentCacheDirectory() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return Directory(path.join(home, '.gitwhisper', 'acp', 'agents'));
  }
}

extension on File {
  Future<void> deleteIfExists() async {
    if (existsSync()) await delete();
  }
}

extension on Directory {
  String get basename => path.basename(this.path);
}

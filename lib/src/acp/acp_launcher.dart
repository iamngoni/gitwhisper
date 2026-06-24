import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import 'acp_client.dart';
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
  })  : _cacheDirectory = cacheDirectory ?? _defaultAgentCacheDirectory(),
        _platformKey = platformKey ?? currentPlatformKey(),
        _dio = dio ?? Dio(),
        _installBinary = installBinary,
        _installNpm = installNpm;

  final Directory _cacheDirectory;
  final String _platformKey;
  final Dio _dio;
  final AcpBinaryInstaller? _installBinary;
  final AcpNpmInstaller? _installNpm;

  Directory get cacheDirectory => _cacheDirectory;

  String get platformKey => _platformKey;

  Future<AcpLaunchCommand> launchCommandFor(
    AcpAgentDefinition agent, {
    AcpInstallStatusCallback? onStatus,
  }) async {
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

  Future<AcpLaunchCommand> authLaunchCommandFor(
    AcpAgentDefinition agent,
    AcpAuthMethod method, {
    AcpInstallStatusCallback? onStatus,
  }) async {
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

  Future<void> install(
    AcpAgentDefinition agent, {
    AcpInstallStatusCallback? onStatus,
  }) async {
    final package = agent.npxPackage;
    if (package != null && package.isNotEmpty) {
      await _installNpmIfNeeded(agent, onStatus: onStatus);
      return;
    }

    final binary = agent.binaryDistributions[_platformKey];
    if (binary == null) {
      await launchCommandFor(agent);
      return;
    }

    final installDirectory = _installDirectoryFor(agent);
    await _installBinaryIfNeeded(
      binary,
      installDirectory,
      onStatus: onStatus,
    );
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
    onStatus?.call('Downloading ${path.basename(binary.archive)}');
    await _downloadArchive(
      binary.archive,
      archiveFile,
      onStatus: onStatus,
    );
    onStatus?.call('Extracting archive');
    await _extractArchive(archiveFile, installDirectory);
    await archiveFile.deleteIfExists();

    if (!Platform.isWindows && File(commandPath).existsSync()) {
      onStatus?.call('Marking binary executable');
      await Process.run('chmod', ['+x', commandPath]);
    }
  }

  Future<void> _downloadArchive(
    String url,
    File destination, {
    AcpInstallStatusCallback? onStatus,
  }) async {
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
    await destination.writeAsBytes(bytes);
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
    final normalizedCommand = command.startsWith('./')
        ? command.substring(2)
        : command.startsWith(r'.\')
            ? command.substring(2)
            : command;
    if (path.isAbsolute(normalizedCommand)) return normalizedCommand;
    return path.join(directory.path, normalizedCommand);
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

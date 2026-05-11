import 'dart:io';

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

enum InstallType {
  dartPub,
  homebrew,
  apt,
  manualUnix,
  manualWindows,
  unknown,
}

class InstallDetection {
  const InstallDetection({
    required this.type,
    this.executablePath,
  });

  final InstallType type;
  final String? executablePath;

  String get label {
    return switch (type) {
      InstallType.dartPub => 'Dart pub global',
      InstallType.homebrew => 'Homebrew',
      InstallType.apt => 'APT',
      InstallType.manualUnix => 'manual Unix',
      InstallType.manualWindows => 'manual Windows',
      InstallType.unknown => 'unknown',
    };
  }

  List<List<String>> get updateCommands {
    return switch (type) {
      InstallType.dartPub => const [
          ['dart', 'pub', 'global', 'activate', 'gitwhisper'],
        ],
      InstallType.homebrew => const [
          ['brew', 'update'],
          ['brew', 'upgrade', 'gitwhisper'],
        ],
      InstallType.apt => const [
          ['sudo', 'apt', 'update'],
          ['sudo', 'apt', 'install', '--only-upgrade', 'gitwhisper', '-y'],
        ],
      InstallType.manualUnix => const [
          [
            'bash',
            '-c',
            'curl -sSL https://raw.githubusercontent.com/iamngoni/gitwhisper/master/install.sh | bash',
          ],
        ],
      InstallType.manualWindows => const [
          [
            'powershell',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            'irm https://raw.githubusercontent.com/iamngoni/gitwhisper/master/install.ps1 | iex',
          ],
        ],
      InstallType.unknown => const [],
    };
  }
}

class InstallUpdateManager {
  InstallUpdateManager({
    ProcessRunner? runProcess,
    String? executablePath,
    bool? isWindows,
    bool? isMacOS,
    bool? isLinux,
  })  : _runProcess = runProcess ?? Process.run,
        _executablePath = executablePath,
        _isWindows = isWindows ?? Platform.isWindows,
        _isMacOS = isMacOS ?? Platform.isMacOS,
        _isLinux = isLinux ?? Platform.isLinux;

  final ProcessRunner _runProcess;
  final String? _executablePath;
  final bool _isWindows;
  final bool _isMacOS;
  final bool _isLinux;

  Future<InstallDetection> detect() async {
    final executablePath = _executablePath ??
        await _resolveCommand('gw') ??
        await _resolveCommand('gitwhisper') ??
        Platform.resolvedExecutable;

    final normalizedPath = executablePath.replaceAll(
      String.fromCharCode(92),
      '/',
    );

    if (normalizedPath.contains('/.pub-cache/bin/')) {
      return InstallDetection(
        type: InstallType.dartPub,
        executablePath: executablePath,
      );
    }

    if (_isMacOS && await _commandSucceeds('brew', ['list', 'gitwhisper'])) {
      return InstallDetection(
        type: InstallType.homebrew,
        executablePath: executablePath,
      );
    }

    if (_isLinux && await _commandSucceeds('dpkg', ['-s', 'gitwhisper'])) {
      return InstallDetection(
        type: InstallType.apt,
        executablePath: executablePath,
      );
    }

    if (_isWindows && normalizedPath.toLowerCase().contains('gitwhisper')) {
      return InstallDetection(
        type: InstallType.manualWindows,
        executablePath: executablePath,
      );
    }

    if (!_isWindows && _looksLikeManualUnixInstall(normalizedPath)) {
      return InstallDetection(
        type: InstallType.manualUnix,
        executablePath: executablePath,
      );
    }

    if (await _dartPubHasGitWhisper()) {
      return InstallDetection(
        type: InstallType.dartPub,
        executablePath: executablePath,
      );
    }

    return InstallDetection(
      type: InstallType.unknown,
      executablePath: executablePath,
    );
  }

  Future<void> runUpdateCommands(InstallDetection detection) async {
    for (final command in detection.updateCommands) {
      if (command.isEmpty) continue;

      final result = await _runProcess(command.first, command.skip(1).toList());
      if (result.exitCode != 0) {
        throw ProcessException(
          command.first,
          command.skip(1).toList(),
          result.stderr.toString(),
          result.exitCode,
        );
      }
    }
  }

  Future<String?> _resolveCommand(String command) async {
    final result = await _safeRun(_isWindows ? 'where' : 'which', [command]);
    if (result == null || result.exitCode != 0) return null;

    final output = result.stdout.toString().trim();
    if (output.isEmpty) return null;

    return output.split('\n').first.trim();
  }

  Future<bool> _commandSucceeds(String executable, List<String> args) async {
    final result = await _safeRun(executable, args);
    return result != null && result.exitCode == 0;
  }

  Future<bool> _dartPubHasGitWhisper() async {
    final result = await _safeRun('dart', ['pub', 'global', 'list']);
    if (result == null || result.exitCode != 0) return false;

    return result.stdout.toString().split('\n').any(
          (line) => line.trim().startsWith('gitwhisper '),
        );
  }

  Future<ProcessResult?> _safeRun(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await _runProcess(executable, arguments);
    } on Object {
      return null;
    }
  }

  bool _looksLikeManualUnixInstall(String executablePath) {
    return executablePath == '/usr/local/bin/gw' ||
        executablePath == '/usr/local/bin/gitwhisper' ||
        executablePath == '/usr/bin/gw' ||
        executablePath == '/usr/bin/gitwhisper';
  }
}

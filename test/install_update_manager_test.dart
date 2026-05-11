import 'dart:io';

import 'package:gitwhisper/src/update/install_update_manager.dart';
import 'package:test/test.dart';

void main() {
  group('InstallUpdateManager', () {
    test('detects Dart pub global installs from pub cache path', () async {
      final manager = InstallUpdateManager(
        executablePath: '/Users/dev/.pub-cache/bin/gw',
        runProcess: emptyRunner,
      );

      final detection = await manager.detect();

      expect(detection.type, InstallType.dartPub);
      expect(detection.updateCommands, [
        ['dart', 'pub', 'global', 'activate', 'gitwhisper'],
      ]);
    });

    test('detects Homebrew installs through brew list', () async {
      final manager = InstallUpdateManager(
        executablePath: '/opt/homebrew/bin/gw',
        isMacOS: true,
        runProcess: (executable, arguments) async {
          if (executable == 'brew' &&
              arguments.length == 2 &&
              arguments[0] == 'list' &&
              arguments[1] == 'gitwhisper') {
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 1, '', '');
        },
      );

      final detection = await manager.detect();

      expect(detection.type, InstallType.homebrew);
      expect(detection.updateCommands, [
        ['brew', 'update'],
        ['brew', 'upgrade', 'gitwhisper'],
      ]);
    });

    test('detects APT installs through dpkg', () async {
      final manager = InstallUpdateManager(
        executablePath: '/usr/bin/gw',
        isLinux: true,
        runProcess: (executable, arguments) async {
          if (executable == 'dpkg' &&
              arguments.length == 2 &&
              arguments[0] == '-s' &&
              arguments[1] == 'gitwhisper') {
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 1, '', '');
        },
      );

      final detection = await manager.detect();

      expect(detection.type, InstallType.apt);
      expect(detection.updateCommands, [
        ['sudo', 'apt', 'update'],
        ['sudo', 'apt', 'install', '--only-upgrade', 'gitwhisper', '-y'],
      ]);
    });

    test('detects manual unix installs from local binary paths', () async {
      final manager = InstallUpdateManager(
        executablePath: '/usr/local/bin/gw',
        isLinux: true,
        runProcess: emptyRunner,
      );

      final detection = await manager.detect();

      expect(detection.type, InstallType.manualUnix);
      expect(detection.updateCommands.single, [
        'bash',
        '-c',
        'curl -sSL https://raw.githubusercontent.com/iamngoni/gitwhisper/master/install.sh | bash',
      ]);
    });

    test('detects manual windows installs from executable path', () async {
      final manager = InstallUpdateManager(
        executablePath: r'C:\Program Files\GitWhisper\gw.exe',
        isWindows: true,
        runProcess: emptyRunner,
      );

      final detection = await manager.detect();

      expect(detection.type, InstallType.manualWindows);
      expect(detection.updateCommands.single, [
        'powershell',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'irm https://raw.githubusercontent.com/iamngoni/gitwhisper/master/install.ps1 | iex',
      ]);
    });
  });
}

Future<ProcessResult> emptyRunner(
  String executable,
  List<String> arguments,
) async {
  return ProcessResult(0, 1, '', '');
}

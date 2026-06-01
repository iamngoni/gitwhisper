import 'dart:io';

import 'package:path/path.dart' as path;

class GitToolsMcpConfig {
  const GitToolsMcpConfig._();

  static Map<String, dynamic> forCwd(String cwd) {
    final command = Platform.resolvedExecutable;
    final args = <String>[];
    final executableName = path.basenameWithoutExtension(command);
    final scriptPath = _scriptPath;

    if (executableName == 'dart' && scriptPath != null) {
      args.add(scriptPath);
    }

    args.addAll(<String>['mcp', 'git-tools', '--cwd', cwd]);

    return <String, dynamic>{
      'name': 'gitwhisper',
      'command': command,
      'args': args,
      'env': <Map<String, String>>[],
    };
  }

  static String? get _scriptPath {
    if (!Platform.script.isScheme('file')) return null;
    final scriptPath = Platform.script.toFilePath();
    if (scriptPath.isEmpty) return null;
    return scriptPath;
  }
}

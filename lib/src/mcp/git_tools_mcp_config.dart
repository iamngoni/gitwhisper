import 'dart:io';

import 'package:path/path.dart' as path;

class GitToolsMcpConfig {
  const GitToolsMcpConfig._();

  /// Name GitWhisper registers its MCP server under. Agents derive tool
  /// identities from it (for example `mcp__gitwhisper__get_file_diff`).
  static const serverName = 'gitwhisper';

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
      'name': serverName,
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

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../mcp/git_tools_mcp_server.dart';

class McpCommand extends Command<int> {
  McpCommand() {
    addSubcommand(McpGitToolsCommand());
  }

  @override
  String get description => 'Run GitWhisper MCP servers';

  @override
  bool get hidden => true;

  @override
  String get name => 'mcp';
}

class McpGitToolsCommand extends Command<int> {
  McpGitToolsCommand() {
    argParser.addOption(
      'cwd',
      help: 'Repository working directory.',
    );
  }

  @override
  String get description => 'Run the read-only staged git tools MCP server';

  @override
  String get name => 'git-tools';

  @override
  Future<int> run() async {
    final cwd = argResults?['cwd']?.toString();
    if (cwd == null || cwd.isEmpty) {
      return ExitCode.usage.code;
    }

    await GitToolsMcpServer(cwd: cwd).serve();
    return ExitCode.success.code;
  }
}

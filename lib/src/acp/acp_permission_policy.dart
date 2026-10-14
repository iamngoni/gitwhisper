import '../agent/git_agent_tools.dart';
import '../mcp/git_tools_mcp_config.dart';

/// What GitWhisper knows about the tool call behind an ACP
/// `session/request_permission` request.
class AcpPermissionSubject {
  const AcpPermissionSubject({
    this.titles = const <String>[],
    this.toolNames = const <String>[],
    this.kinds = const <String>[],
  });

  /// Titles from the permission request itself. The model can influence
  /// these (a shell call's title is often the command), so they only count
  /// on an exact match.
  final List<String> titles;

  /// Tool names the agent reports in metadata, for example Claude Code's
  /// `_meta.claudeCode.toolName`, from the request or earlier tool updates.
  final List<String> toolNames;

  /// ACP tool kinds reported for the call, from the request or earlier tool
  /// updates.
  final List<String> kinds;
}

/// Decides which ACP permission requests GitWhisper approves on the user's
/// behalf.
///
/// Only GitWhisper's own read-only MCP tools are approved, and only on an
/// exact identity match. Substring matching is unsafe because the model
/// controls tool titles and content, and every path in a repository named
/// gitwhisper contains "gitwhisper". Everything else is rejected.
class AcpToolPermissionPolicy {
  AcpToolPermissionPolicy({
    required String serverName,
    required Iterable<String> toolNames,
  }) : _identities = <String, String>{
          for (final tool in toolNames) ...<String, String>{
            // Claude Code (claude-agent-acp) tool names and titles.
            'mcp__${serverName}__$tool': tool,
            // codex-acp tool call titles.
            'Tool: $serverName/$tool': tool,
            // Other agents' fully qualified forms.
            '$serverName/$tool': tool,
            '${serverName}__$tool': tool,
          },
        };

  /// The policy for GitWhisper's own git tools MCP server.
  factory AcpToolPermissionPolicy.gitWhisper() {
    return AcpToolPermissionPolicy(
      serverName: GitToolsMcpConfig.serverName,
      toolNames: GitAgentTools.mcpToolDefinitions
          .map((tool) => tool['name'].toString()),
    );
  }

  /// ACP tool kinds that can be approved. `read` and `search` are read-only.
  /// Agents report GitWhisper's MCP tools as `other` (claude-agent-acp) or
  /// with no kind at all (codex-acp). Kinds with side effects (`edit`,
  /// `delete`, `move`, `execute`, `fetch`, `switch_mode`, `think`) are always
  /// rejected.
  static const approvableKinds = <String>{'read', 'search', 'other'};

  final Map<String, String> _identities;

  /// Returns the GitWhisper tool name for an exact identity such as
  /// `mcp__gitwhisper__get_file_diff`, or null.
  String? toolNameFor(String identity) => _identities[identity];

  /// Returns the GitWhisper tool [subject] refers to when the request may be
  /// approved, or null when it must be rejected.
  String? approvedToolName(AcpPermissionSubject subject) {
    // Agent metadata names the real tool. A GitWhisper-looking title on, say,
    // a Bash call is a spoof.
    for (final toolName in subject.toolNames) {
      if (!_identities.containsKey(toolName)) return null;
    }
    for (final kind in subject.kinds) {
      if (!approvableKinds.contains(kind)) return null;
    }

    String? matched;
    for (final identity in <String>[...subject.toolNames, ...subject.titles]) {
      final tool = _identities[identity];
      if (tool == null) continue;
      if (matched != null && matched != tool) return null;
      matched = tool;
    }
    return matched;
  }
}

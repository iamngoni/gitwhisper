import 'package:mason_logger/mason_logger.dart';

import 'git_agent_tools.dart';

class AgentToolActivityFormatter {
  const AgentToolActivityFormatter();

  static const Map<String, (String, String)> _display =
      <String, (String, String)>{
    'list_staged_files': ('🔎', 'Scanning staged files'),
    'get_diff_stat': ('📊', 'Reading diff summary'),
    'get_file_diff': ('📄', 'Reading diff'),
    'get_file_content': ('📖', 'Reading file context'),
    'get_file_diff_hunks': ('🧩', 'Listing diff hunks'),
    'get_file_diff_hunk': ('🧩', 'Inspecting hunk'),
    'get_file_content_chunk': ('📖', 'Reading file chunk'),
    'search_file_content': ('🔍', 'Searching file'),
    'get_staged_file_summary': ('📝', 'Summarizing changes'),
    'get_related_files': ('🧭', 'Finding related files'),
    'get_blame': ('🕰️', 'Checking blame'),
  };

  String format(AgentToolUse toolUse) {
    final display = _display[toolUse.name] ?? ('•', toolUse.name);
    final pathValue = toolUse.path;
    final hunkText = toolUse.hunkIndex == null ? '' : ' #${toolUse.hunkIndex}';
    final detail = pathValue == null ? '' : '  ${lightCyan.wrap(pathValue)}';
    return '  ${display.$1} ${display.$2.padRight(24)}$detail$hunkText';
  }

  /// Formats a tool call reported by an ACP agent.
  ///
  /// Resolution order: (1) a known GitWhisper MCP tool matched by name (e.g.
  /// claude-code calling `mcp__gitwhisper__get_file_diff`); (2) a read-only git
  /// command an agent runs through its own shell tool (e.g. codex running
  /// `git diff --cached --stat`); (3) the raw title with a neutral icon for any
  /// other tool the agent uses. The same icons/wording (and file detail) are
  /// reused across all sources so the output reads consistently.
  String formatAcp(String title, {String? path, int? hunkIndex}) {
    var icon = '🔧';
    var label = title;
    var detailPath = path;

    final known = _matchKnownTool(title);
    if (known != null) {
      icon = known.$1;
      label = known.$2;
    } else {
      final git = _gitCommandDisplay(title);
      if (git != null) {
        icon = git.$1;
        label = git.$2;
        detailPath ??= git.$3;
      }
    }

    final hunkText = hunkIndex == null ? '' : ' #$hunkIndex';
    final detail = (detailPath == null || detailPath.isEmpty)
        ? ''
        : '  ${lightCyan.wrap(detailPath)}';
    return '  $icon ${label.padRight(24)}$detail$hunkText';
  }

  (String, String)? _matchKnownTool(String title) {
    for (final entry in _display.entries) {
      if (title.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// Recognizes the read-only git commands agents run through their own shell
  /// tool, returning (icon, label, path) so they read the same as GitWhisper's
  /// MCP tools instead of dumping raw command lines. Returns null for anything
  /// that is not a recognized git inspection command.
  (String, String, String?)? _gitCommandDisplay(String command) {
    final normalized = command.trim();
    final lower = normalized.toLowerCase();
    if (!lower.contains('git ')) return null;

    String? pathAfterSeparator() {
      final marker = normalized.indexOf(' -- ');
      if (marker < 0) return null;
      final rest = normalized.substring(marker + 4).trim();
      return rest.isEmpty ? null : rest;
    }

    if (lower.contains('git diff')) {
      if (lower.contains('--stat') ||
          lower.contains('--numstat') ||
          lower.contains('--shortstat')) {
        return ('📊', 'Reading diff summary', null);
      }
      if (lower.contains('--name-only') || lower.contains('--name-status')) {
        return ('🔎', 'Scanning staged files', null);
      }
      return ('📄', 'Reading diff', pathAfterSeparator());
    }
    if (lower.contains('git show')) {
      return ('📖', 'Reading file context', pathAfterSeparator());
    }
    if (lower.contains('git blame')) {
      return ('🕰️', 'Checking blame', pathAfterSeparator());
    }
    if (lower.contains('git log')) {
      return ('🕰️', 'Reading history', pathAfterSeparator());
    }
    if (lower.contains('git status')) {
      return ('🔎', 'Checking status', null);
    }
    if (lower.contains('git ls-files') || lower.contains('git ls-tree')) {
      return ('🔎', 'Scanning staged files', null);
    }
    return null;
  }
}

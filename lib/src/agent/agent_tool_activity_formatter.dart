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
}

import 'package:gitwhisper/src/agent/agent_tool_activity_formatter.dart';
import 'package:test/test.dart';

void main() {
  const formatter = AgentToolActivityFormatter();

  group('formatAcp', () {
    test('maps GitWhisper MCP tool titles to friendly labels', () {
      final line = formatter.formatAcp('mcp__gitwhisper__list_staged_files');
      expect(line, contains('Scanning staged files'));
      expect(line, contains('🔎'));
    });

    test('shows the file detail for path-bearing MCP tools', () {
      final line = formatter.formatAcp(
        'Tool: gitwhisper/get_file_diff',
        path: 'lib/src/foo.dart',
      );
      expect(line, contains('Reading diff'));
      expect(line, contains('lib/src/foo.dart'));
    });

    test('recognizes raw git diff stat commands run by an agent shell', () {
      final line = formatter.formatAcp('git diff --cached --stat');
      expect(line, contains('Reading diff summary'));
      expect(line, contains('📊'));
      expect(line, isNot(contains('git diff')));
    });

    test('recognizes git diff --name-only as a staged-file scan', () {
      final line = formatter.formatAcp('git diff --cached --name-only');
      expect(line, contains('Scanning staged files'));
    });

    test('extracts the file path from a raw git diff command', () {
      final line = formatter.formatAcp(
        'git diff --cached -- lib/src/commands/commit_command.dart',
      );
      expect(line, contains('Reading diff'));
      expect(line, contains('lib/src/commands/commit_command.dart'));
    });

    test('maps git blame and git log to history labels', () {
      expect(
        formatter.formatAcp('git blame -L 1,20 -- lib/foo.dart'),
        contains('Checking blame'),
      );
      expect(
        formatter.formatAcp('git log --oneline -5'),
        contains('Reading history'),
      );
    });

    test('falls back to the raw title for unrelated agent tools', () {
      final line = formatter.formatAcp('ToolSearch');
      expect(line, contains('ToolSearch'));
      expect(line, contains('🔧'));
    });
  });
}

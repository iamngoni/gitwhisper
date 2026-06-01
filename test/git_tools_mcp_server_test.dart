import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/mcp/git_tools_mcp_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('lists and calls GitWhisper staged-change tools over MCP', () async {
    final repo = await Directory.systemTemp.createTemp('gitwhisper_mcp_');
    addTearDown(() => repo.delete(recursive: true));

    await _runGit(repo, <String>['init']);
    await _runGit(repo, <String>['config', 'user.email', 'test@example.com']);
    await _runGit(repo, <String>['config', 'user.name', 'Test User']);
    await File(p.join(repo.path, 'README.md')).writeAsString('Hello\n');
    await _runGit(repo, <String>['add', 'README.md']);

    final input = Stream<List<int>>.fromIterable(<List<int>>[
      utf8.encode(
        [
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': <String, dynamic>{
              'protocolVersion': '2025-06-18',
            },
          }),
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/list',
          }),
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': <String, dynamic>{
              'name': 'list_staged_files',
              'arguments': <String, dynamic>{},
            },
          }),
        ].join('\n'),
      ),
    ]);
    final output = StringBuffer();

    await GitToolsMcpServer(
      cwd: repo.path,
      input: input,
      output: output,
    ).serve();

    final responses = output
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();

    expect(responses, hasLength(3));
    expect(
      responses[0]['result'],
      containsPair('protocolVersion', '2025-06-18'),
    );

    final toolsResult = responses[1]['result'] as Map<String, dynamic>;
    final tools = toolsResult['tools'] as List<dynamic>;
    expect(
      tools.map((tool) => (tool as Map<String, dynamic>)['name']),
      contains('get_file_diff'),
    );

    final callResult = responses[2]['result'] as Map<String, dynamic>;
    final content = callResult['content'] as List<dynamic>;
    final text = (content.single as Map<String, dynamic>)['text'] as String;
    expect(text, contains('README.md'));
  });
}

Future<void> _runGit(Directory repo, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: repo.path);
  if (result.exitCode != 0) {
    throw ProcessException(
      'git',
      args,
      result.stderr.toString(),
      result.exitCode,
    );
  }
}

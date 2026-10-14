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
    for (final tool in tools.cast<Map<String, dynamic>>()) {
      expect(
        (tool['annotations'] as Map<String, dynamic>)['readOnlyHint'],
        isTrue,
        reason: '${tool['name']} is advertised as read-only',
      );
    }

    final callResult = responses[2]['result'] as Map<String, dynamic>;
    final content = callResult['content'] as List<dynamic>;
    final text = (content.single as Map<String, dynamic>)['text'] as String;
    expect(text, contains('README.md'));
  });

  test('a listed non-ASCII path can be read over MCP', () async {
    final root = await Directory.systemTemp.createTemp('gitwhisper_mcp_');
    addTearDown(() => root.delete(recursive: true));
    final repo = await Directory(p.join(root.path, 'repo')).create();
    final hooks = await Directory(p.join(root.path, 'hooks')).create();

    await _runGit(repo, <String>['init']);
    await _runGit(repo, <String>['config', 'user.email', 'test@example.com']);
    await _runGit(repo, <String>['config', 'user.name', 'Test User']);
    await _runGit(repo, <String>['config', 'commit.gpgsign', 'false']);
    await _runGit(repo, <String>['config', 'core.hooksPath', hooks.path]);
    await File(p.join(repo.path, 'café.txt')).writeAsString('Bonjour\n');
    await _runGit(repo, <String>['add', 'café.txt']);

    Future<Map<String, dynamic>> call(
      String name, [
      Map<String, dynamic> arguments = const <String, dynamic>{},
    ]) async {
      final output = StringBuffer();
      await GitToolsMcpServer(
        cwd: repo.path,
        input: Stream<List<int>>.value(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': <String, dynamic>{
                'name': name,
                'arguments': arguments,
              },
            }),
          ),
        ),
        output: output,
      ).serve();
      final response = jsonDecode(output.toString()) as Map<String, dynamic>;
      return response['result'] as Map<String, dynamic>;
    }

    String text(Map<String, dynamic> result) =>
        ((result['content'] as List<dynamic>).single
            as Map<String, dynamic>)['text'] as String;

    final listed = jsonDecode(text(await call('list_staged_files')))
        as Map<String, dynamic>;
    final file =
        (listed['files'] as List<dynamic>).single as Map<String, dynamic>;
    final diff = await call(
      'get_file_diff',
      <String, dynamic>{'path': file['path']},
    );

    expect(file['path'], 'café.txt');
    expect(file['additions'], 1);
    expect(diff['isError'], isFalse, reason: text(diff));
    expect(text(diff), contains('+Bonjour'));
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

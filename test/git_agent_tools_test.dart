import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory repo;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('gw_agent_tools_test_');
    repo = await Directory(p.join(root.path, 'repo')).create();
    await _git(repo, <String>['init']);
    await _git(repo, <String>['config', 'user.email', 'test@example.com']);
    await _git(repo, <String>['config', 'user.name', 'Test User']);
    await _git(repo, <String>['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() => root.delete(recursive: true));

  GitAgentTools tools({int maxOutputCharacters = 30000}) => GitAgentTools(
        folderPath: repo.path,
        maxOutputCharacters: maxOutputCharacters,
        onToolUse: (_) {},
      );

  group('content tools read the index, not the working tree', () {
    test(
      'a staged symlink yields its link text, not the target content',
      () async {
        final secret = File(p.join(root.path, 'id_ed25519'))
          ..writeAsStringSync('-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n');
        Link(p.join(repo.path, 'key')).createSync(secret.path);
        await _git(repo, <String>['add', 'key']);

        final content = await tools().execute(
          'get_file_content',
          <String, dynamic>{'path': 'key'},
        );
        final chunk = await tools().execute(
          'get_file_content_chunk',
          <String, dynamic>{'path': 'key'},
        );
        final search = await tools().execute(
          'search_file_content',
          <String, dynamic>{'path': 'key', 'query': 'PRIVATE KEY'},
        );

        expect(content, secret.path);
        expect(chunk, isNot(contains('PRIVATE KEY')));
        expect(
          (jsonDecode(search) as Map<String, dynamic>)['matches'],
          isEmpty,
        );
      },
      skip: Platform.isWindows ? 'POSIX symlinks only' : null,
    );

    test('unstaged edits are never reported as staged content', () async {
      final file = File(p.join(repo.path, 'a.txt'))
        ..writeAsStringSync('first line\n');
      await _git(repo, <String>['add', 'a.txt']);
      await _git(repo, <String>['commit', '-m', 'init']);
      file.writeAsStringSync('first line\nstaged line\n');
      await _git(repo, <String>['add', 'a.txt']);
      file.writeAsStringSync('first line\nunstaged secret line\n');

      final content = await tools().execute(
        'get_file_content',
        <String, dynamic>{'path': 'a.txt'},
      );
      final chunk = jsonDecode(
        await tools().execute(
          'get_file_content_chunk',
          <String, dynamic>{'path': 'a.txt'},
        ),
      ) as Map<String, dynamic>;
      final search = jsonDecode(
        await tools().execute(
          'search_file_content',
          <String, dynamic>{'path': 'a.txt', 'query': 'unstaged'},
        ),
      ) as Map<String, dynamic>;
      final blame = jsonDecode(
        await tools().execute(
          'get_blame',
          <String, dynamic>{'path': 'a.txt', 'startLine': 1, 'maxLines': 5},
        ),
      ) as Map<String, dynamic>;

      expect(content, contains('staged line'));
      expect(content, isNot(contains('unstaged')));
      expect(chunk['content'], contains('staged line'));
      expect(chunk['content'], isNot(contains('unstaged')));
      expect(search['matches'], isEmpty);
      final blameLines = (blame['lines'] as List<dynamic>).join('\n');
      expect(blameLines, contains('staged line'));
      expect(blameLines, isNot(contains('unstaged')));
      expect(blame['endLine'], 2, reason: 'clamped to staged line count');
    });

    test('decodes non-UTF-8 staged content leniently', () async {
      File(p.join(repo.path, 'latin1.txt'))
          .writeAsBytesSync(<int>[0x63, 0x61, 0x66, 0xE9, 0x0A]);
      await _git(repo, <String>['add', 'latin1.txt']);

      final content = await tools().execute(
        'get_file_content',
        <String, dynamic>{'path': 'latin1.txt'},
      );

      expect(content, startsWith('caf'));
      expect(content, contains('�'));
    });

    test('reports binary and deleted staged files without reading them',
        () async {
      File(p.join(repo.path, 'gone.txt')).writeAsStringSync('bye\n');
      await _git(repo, <String>['add', 'gone.txt']);
      await _git(repo, <String>['commit', '-m', 'init']);
      await _git(repo, <String>['rm', '-q', 'gone.txt']);
      File(p.join(repo.path, 'blob.bin'))
          .writeAsBytesSync(<int>[0x00, 0x01, 0x02, 0x00]);
      await _git(repo, <String>['add', 'blob.bin']);

      expect(
        await tools().execute(
          'get_file_content',
          <String, dynamic>{'path': 'blob.bin'},
        ),
        contains('is binary'),
      );
      expect(
        await tools().execute(
          'get_file_content',
          <String, dynamic>{'path': 'gone.txt'},
        ),
        contains('no staged content'),
      );
    });
  });

  group('tool output is bounded', () {
    test('get_file_content_chunk clamps maxLines', () async {
      File(p.join(repo.path, 'long.txt')).writeAsStringSync(
        List<String>.generate(2000, (i) => 'line $i').join('\n'),
      );
      await _git(repo, <String>['add', 'long.txt']);

      final chunk = jsonDecode(
        await tools().execute(
          'get_file_content_chunk',
          <String, dynamic>{'path': 'long.txt', 'maxLines': 1000000},
        ),
      ) as Map<String, dynamic>;

      expect(chunk['endLine'], GitAgentTools.maxChunkLines);
      expect(chunk['hasMore'], isTrue);
    });

    test('search_file_content caps the length of matching lines', () async {
      final minified = '${'x' * 500000}needle${'y' * 500000}';
      File(p.join(repo.path, 'app.min.js')).writeAsStringSync(minified);
      await _git(repo, <String>['add', 'app.min.js']);

      final result = await tools().execute(
        'search_file_content',
        <String, dynamic>{'path': 'app.min.js', 'query': 'needle'},
      );
      final match = ((jsonDecode(result) as Map<String, dynamic>)['matches']
              as List<dynamic>)
          .single as Map<String, dynamic>;

      expect(result.length, lessThan(2000));
      expect(match['content'], contains('needle'));
      expect(
        (match['content'] as String).length,
        lessThanOrEqualTo(GitAgentTools.maxPreviewLineCharacters + 2),
      );
      expect(match['lineCharacters'], minified.length);
    });

    test('list_staged_files stops at the output budget', () async {
      for (var i = 0; i < 60; i++) {
        File(p.join(repo.path, 'file_$i.txt')).writeAsStringSync('$i\n');
      }
      await _git(repo, <String>['add', '.']);

      final result = await tools(maxOutputCharacters: 1000).execute(
        'list_staged_files',
        <String, dynamic>{},
      );
      final payload = jsonDecode(result) as Map<String, dynamic>;

      expect(payload['truncated'], isTrue);
      expect(payload['totalFiles'], 60);
      expect((payload['files'] as List<dynamic>).length, lessThan(60));
      expect(result.length, lessThan(2000));
    });

    test('get_file_diff_hunks bounds previews and hunk entries', () async {
      final lines = <String>[
        for (var i = 0; i < 400; i++) i.isEven ? 'z' * 100000 : 'keep $i',
      ];
      File(p.join(repo.path, 'big.txt'))
          .writeAsStringSync(List<String>.filled(400, 'old').join('\n'));
      await _git(repo, <String>['add', 'big.txt']);
      await _git(repo, <String>['commit', '-m', 'init']);
      File(p.join(repo.path, 'big.txt')).writeAsStringSync(lines.join('\n'));
      await _git(repo, <String>['add', 'big.txt']);

      final result = await tools(maxOutputCharacters: 4000).execute(
        'get_file_diff_hunks',
        <String, dynamic>{'path': 'big.txt'},
      );

      expect(result.length, lessThanOrEqualTo(4000 * 2 + 2048 + 64));
      expect(() => jsonDecode(result), returnsNormally);
    });
  });

  test('MCP tool definitions are annotated read-only', () {
    for (final tool in GitAgentTools.mcpToolDefinitions) {
      final annotations = tool['annotations'] as Map<String, dynamic>;
      expect(annotations['readOnlyHint'], isTrue, reason: '${tool['name']}');
      expect(annotations['destructiveHint'], isFalse);
    }
  });
}

Future<void> _git(Directory repo, List<String> args) async {
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

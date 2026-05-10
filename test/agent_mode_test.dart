import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/commands/commit_command.dart';
import 'package:gitwhisper/src/constants.dart';
import 'package:gitwhisper/src/models/claude_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:gitwhisper/src/models/openai_generator.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CommitCommand agent flag', () {
    test('supports long-only agent mode without changing auto-push shorthand',
        () {
      final command = CommitCommand(logger: Logger());

      final results = command.argParser.parse(['--agent', '-a']);

      expect(results['agent'], isTrue);
      expect(results['auto-push'], isTrue);
    });
  });

  group('GitAgentTools', () {
    test('exposes staged files and staged file diffs', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(folderPath: repo.path);

      final filesJson = await tools.execute('list_staged_files', {});
      final filesPayload = jsonDecode(filesJson) as Map<String, dynamic>;
      final files = filesPayload['files'] as List<dynamic>;
      final file = files.single as Map<String, dynamic>;
      expect(file['path'], 'lib/a.dart');
      expect(file['status'], 'A');

      final diff = await tools.execute(
        'get_file_diff',
        <String, dynamic>{'path': 'lib/a.dart'},
      );
      expect(diff, contains('diff --git'));
      expect(diff, contains('+final value = 1;'));
    });

    test('rejects paths outside staged changes', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(folderPath: repo.path);

      await expectLater(
        tools.execute(
          'get_file_diff',
          <String, dynamic>{'path': '../pubspec.yaml'},
        ),
        throwsArgumentError,
      );

      await expectLater(
        tools.execute(
          'get_file_diff',
          <String, dynamic>{'path': 'lib/unstaged.dart'},
        ),
        throwsArgumentError,
      );
    });
  });

  group('API agent generators', () {
    test('OpenAI uses tool calls to inspect staged changes', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final capturedRequests = <RequestOptions>[];
      _addQueuedDioResponses(
        capturedRequests,
        <Map<String, dynamic>>[
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'call_1',
                      'type': 'function',
                      'function': <String, dynamic>{
                        'name': 'list_staged_files',
                        'arguments': '{}',
                      },
                    },
                  ],
                },
              },
            ],
          },
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'feat: add agent mode',
                },
              },
            ],
          },
        ],
      );

      final generator = OpenAIGenerator('test-key', variant: 'gpt-test');
      expect(generator, isA<AgentCommitGenerator>());

      final message = await generator.generateAgentCommitMessage(
        AgentCommitRequest(
          tools: GitAgentTools(folderPath: repo.path),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add agent mode');
      expect(capturedRequests, hasLength(2));
      expect(capturedRequests.first.uri.toString(), contains('openai.com'));
      expect(capturedRequests.first.data.toString(), contains('tools'));
      expect(capturedRequests.last.data.toString(), contains('lib/a.dart'));
    });

    test('Claude uses tool_use and tool_result blocks', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final capturedRequests = <RequestOptions>[];
      _addQueuedDioResponses(
        capturedRequests,
        <Map<String, dynamic>>[
          <String, dynamic>{
            'stop_reason': 'tool_use',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'get_file_diff',
                'input': <String, dynamic>{'path': 'lib/a.dart'},
              },
            ],
          },
          <String, dynamic>{
            'stop_reason': 'end_turn',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': 'feat: add agent mode',
              },
            ],
          },
        ],
      );

      final generator = ClaudeGenerator('test-key', variant: 'claude-test');
      expect(generator, isA<AgentCommitGenerator>());

      final message = await generator.generateAgentCommitMessage(
        AgentCommitRequest(
          tools: GitAgentTools(folderPath: repo.path),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add agent mode');
      expect(capturedRequests, hasLength(2));
      expect(capturedRequests.first.uri.toString(), contains('anthropic.com'));
      expect(capturedRequests.first.data.toString(), contains('tools'));
      expect(capturedRequests.last.data.toString(), contains('tool_result'));
      expect(capturedRequests.last.data.toString(), contains('diff --git'));
    });
  });
}

Future<Directory> _createRepoWithStagedFile() async {
  final repo = await Directory.systemTemp.createTemp('gitwhisper_agent_test_');
  final libDir = await Directory(p.join(repo.path, 'lib')).create();
  final file = File(p.join(libDir.path, 'a.dart'));
  await file.writeAsString('final value = 1;\n');
  await _runGit(repo, <String>['init']);
  await _runGit(repo, <String>['add', 'lib/a.dart']);
  return repo;
}

Future<void> _runGit(Directory repo, List<String> args) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: repo.path,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

void _addQueuedDioResponses(
  List<RequestOptions> capturedRequests,
  List<Map<String, dynamic>> responses,
) {
  final interceptor = InterceptorsWrapper(
    onRequest: (options, handler) {
      capturedRequests.add(options);
      handler.resolve(
        Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: 200,
          data: responses.removeAt(0),
        ),
      );
    },
  );
  $dio.interceptors.add(interceptor);
  addTearDown(() => $dio.interceptors.remove(interceptor));
}

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/agent_tool_activity_formatter.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/commands/commit_command.dart';
import 'package:gitwhisper/src/constants.dart';
import 'package:gitwhisper/src/exceptions/error_handler.dart';
import 'package:gitwhisper/src/models/claude_generator.dart';
import 'package:gitwhisper/src/models/deepseek_generator.dart';
import 'package:gitwhisper/src/models/gemini_generator.dart';
import 'package:gitwhisper/src/models/github_generator.dart';
import 'package:gitwhisper/src/models/grok_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:gitwhisper/src/models/llama_generator.dart';
import 'package:gitwhisper/src/models/ollama_generator.dart';
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

    test('formats polished agent tool activity rows', () {
      const formatter = AgentToolActivityFormatter();

      final row = formatter.format(
        const AgentToolUse(
          name: 'get_file_diff_hunk',
          path: 'lib/src/agent/git_agent_tools.dart',
          hunkIndex: 2,
        ),
      );

      expect(row, contains('🧩 Inspecting hunk'));
      expect(row, contains('lib/src/agent/git_agent_tools.dart'));
      expect(row, contains('#2'));
    });

    test('general error handler accepts non-Exception failures', () {
      const void Function(Object, {String? context}) handler =
          ErrorHandler.handleGeneralError;

      expect(handler, isNotNull);
    });

    test('agent requests allow enough tool calls for larger staged changes',
        () {
      expect(
        const AgentCommitRequest(
          tools: GitAgentTools(),
          language: Language.english,
        ).maxToolCalls,
        32,
      );
    });

    test('provider tool schemas expose extended read-only tools', () {
      final openAiNames = GitAgentTools.openAiToolDefinitions
          .map((tool) => tool['function'] as Map<String, dynamic>)
          .map((function) => function['name'])
          .toSet();
      final claudeNames = GitAgentTools.claudeToolDefinitions
          .map((tool) => tool['name'])
          .toSet();
      const expectedTools = <String>{
        'list_staged_files',
        'get_diff_stat',
        'get_file_diff',
        'get_file_content',
        'get_file_diff_hunks',
        'get_file_diff_hunk',
        'get_file_content_chunk',
        'search_file_content',
        'get_staged_file_summary',
        'get_related_files',
        'get_blame',
      };

      expect(openAiNames, containsAll(expectedTools));
      expect(claudeNames, containsAll(expectedTools));
    });

    test('MCP tool schemas avoid provider-specific strict schema fields', () {
      final encoded = jsonEncode(GitAgentTools.mcpToolDefinitions);

      expect(encoded, isNot(contains('additionalProperties')));
    });
  });

  group('GitAgentTools', () {
    test('exposes staged files and staged file diffs', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

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

    test('logs agent tool usage with requested file paths', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final toolUses = <AgentToolUse>[];
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: toolUses.add,
      );

      await tools.execute('list_staged_files', {});
      await tools.execute(
        'get_file_diff',
        <String, dynamic>{'path': 'lib/a.dart'},
      );

      expect(
        toolUses.map((toolUse) => toolUse.message),
        <String>[
          'Agent tool: list_staged_files',
          'Agent tool: get_file_diff(lib/a.dart)',
        ],
      );
    });

    test('rejects paths outside staged changes', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

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

    test('lists staged files with size and change metadata', () async {
      final repo = await _createRepoWithModifiedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

      final filesJson = await tools.execute('list_staged_files', {});
      final payload = jsonDecode(filesJson) as Map<String, dynamic>;
      final file =
          (payload['files'] as List<dynamic>).single as Map<String, dynamic>;

      expect(file['path'], 'lib/a.dart');
      expect(file['additions'], greaterThan(0));
      expect(file['deletions'], greaterThan(0));
      expect(file['diffSize'], greaterThan(0));
      expect(file['isBinary'], isFalse);
      expect(file['isLikelyGenerated'], isFalse);
      expect(file['isLockfile'], isFalse);
    });

    test('returns structured metadata when a file diff is too large', () async {
      final repo = await _createRepoWithModifiedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        maxOutputCharacters: 80,
        onToolUse: (_) {},
      );

      final diffJson = await tools.execute(
        'get_file_diff',
        <String, dynamic>{'path': 'lib/a.dart'},
      );
      final payload = jsonDecode(diffJson) as Map<String, dynamic>;

      expect(payload['path'], 'lib/a.dart');
      expect(payload['truncated'], isTrue);
      expect(payload['originalCharacters'], greaterThan(80));
      expect(payload['nextTools'], contains('get_file_diff_hunks'));
    });

    test('exposes staged file diff hunks and individual hunk lookup', () async {
      final repo = await _createRepoWithModifiedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

      final hunksJson = await tools.execute(
        'get_file_diff_hunks',
        <String, dynamic>{'path': 'lib/a.dart'},
      );
      final hunksPayload = jsonDecode(hunksJson) as Map<String, dynamic>;
      final hunks = hunksPayload['hunks'] as List<dynamic>;
      expect(hunks, isNotEmpty);
      expect(hunks.first, containsPair('index', 0));

      final hunkJson = await tools.execute(
        'get_file_diff_hunk',
        <String, dynamic>{'path': 'lib/a.dart', 'hunkIndex': 0},
      );
      final hunkPayload = jsonDecode(hunkJson) as Map<String, dynamic>;
      expect(hunkPayload['path'], 'lib/a.dart');
      expect(hunkPayload['hunkIndex'], 0);
      expect(hunkPayload['diff'], contains('@@'));
    });

    test('reads bounded file content chunks by line', () async {
      final repo = await _createRepoWithModifiedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

      final chunkJson = await tools.execute(
        'get_file_content_chunk',
        <String, dynamic>{
          'path': 'lib/a.dart',
          'startLine': 2,
          'maxLines': 2,
        },
      );
      final payload = jsonDecode(chunkJson) as Map<String, dynamic>;

      expect(payload['startLine'], 2);
      expect(payload['endLine'], 3);
      expect(payload['content'], contains('updated line 2'));
      expect(payload['hasMore'], isTrue);
    });

    test('searches staged file content', () async {
      final repo = await _createRepoWithModifiedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

      final searchJson = await tools.execute(
        'search_file_content',
        <String, dynamic>{'path': 'lib/a.dart', 'query': 'updated'},
      );
      final payload = jsonDecode(searchJson) as Map<String, dynamic>;
      final matches = payload['matches'] as List<dynamic>;

      expect(matches, isNotEmpty);
      expect(matches.first, containsPair('line', 2));
      expect(matches.first.toString(), contains('updated line 2'));
    });

    test('summarizes staged file changes deterministically', () async {
      final repo = await _createRepoWithModifiedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

      final summaryJson = await tools.execute(
        'get_staged_file_summary',
        <String, dynamic>{'path': 'lib/a.dart'},
      );
      final payload = jsonDecode(summaryJson) as Map<String, dynamic>;

      expect(payload['path'], 'lib/a.dart');
      expect(payload['additions'], greaterThan(0));
      expect(payload['deletions'], greaterThan(0));
      expect(payload['hunkCount'], greaterThan(0));
      expect(payload['previews'].toString(), contains('updated line 2'));
    });

    test('finds related repository files for a staged file', () async {
      final repo = await _createRepoWithRelatedFiles();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

      final relatedJson = await tools.execute(
        'get_related_files',
        <String, dynamic>{'path': 'lib/a.dart'},
      );
      final payload = jsonDecode(relatedJson) as Map<String, dynamic>;
      final related = payload['relatedFiles'] as List<dynamic>;

      expect(related, contains('test/a_test.dart'));
    });

    test('returns git blame for a staged file line range', () async {
      final repo = await _createRepoWithModifiedFile();
      addTearDown(() => repo.delete(recursive: true));
      final tools = GitAgentTools(
        folderPath: repo.path,
        onToolUse: (_) {},
      );

      final blameJson = await tools.execute(
        'get_blame',
        <String, dynamic>{
          'path': 'lib/a.dart',
          'startLine': 1,
          'maxLines': 2,
        },
      );
      final payload = jsonDecode(blameJson) as Map<String, dynamic>;
      final lines = payload['lines'] as List<dynamic>;

      expect(lines, isNotEmpty);
      expect(lines.first.toString(), contains('Test User'));
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
          tools: GitAgentTools(
            folderPath: repo.path,
            onToolUse: (_) {},
          ),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add agent mode');
      expect(capturedRequests, hasLength(2));
      expect(capturedRequests.first.uri.toString(), contains('openai.com'));
      final firstRequestData =
          capturedRequests.first.data as Map<String, dynamic>;
      expect(firstRequestData['tools'], isA<List<dynamic>>());
      expect(firstRequestData['tool_choice'], 'required');
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
          tools: GitAgentTools(
            folderPath: repo.path,
            onToolUse: (_) {},
          ),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add agent mode');
      expect(capturedRequests, hasLength(2));
      expect(capturedRequests.first.uri.toString(), contains('anthropic.com'));
      final firstRequestData =
          capturedRequests.first.data as Map<String, dynamic>;
      expect(firstRequestData['tools'], isA<List<dynamic>>());
      expect(
        firstRequestData['tool_choice'],
        <String, dynamic>{'type': 'any'},
      );
      expect(capturedRequests.last.data.toString(), contains('tool_result'));
      expect(capturedRequests.last.data.toString(), contains('diff --git'));
    });

    test('OpenAI-compatible providers use tool calls', () async {
      for (final scenario in <({
        String label,
        AgentCommitGenerator generator,
        String endpointFragment,
      })>[
        (
          label: 'Grok',
          generator: GrokGenerator('test-key', variant: 'grok-test'),
          endpointFragment: 'api.x.ai',
        ),
        (
          label: 'DeepSeek',
          generator: DeepseekGenerator('test-key', variant: 'deepseek-test'),
          endpointFragment: 'api.deepseek.com',
        ),
        (
          label: 'GitHub',
          generator: GithubGenerator('test-key', variant: 'github-test'),
          endpointFragment: 'models.github.ai',
        ),
        (
          label: 'Llama',
          generator: LlamaGenerator('test-key', variant: 'llama-test'),
          endpointFragment: 'api.llama.api',
        ),
      ]) {
        final repo = await _createRepoWithStagedFile();
        addTearDown(() => repo.delete(recursive: true));
        final capturedRequests = <RequestOptions>[];
        final interceptor = _addQueuedDioResponses(
          capturedRequests,
          _openAiCompatibleToolResponses(),
        );

        try {
          final message = await scenario.generator.generateAgentCommitMessage(
            AgentCommitRequest(
              tools: GitAgentTools(
                folderPath: repo.path,
                onToolUse: (_) {},
              ),
              language: Language.english,
            ),
          );

          expect(message, 'feat: add agent mode', reason: scenario.label);
          expect(capturedRequests, hasLength(2), reason: scenario.label);
          expect(
            capturedRequests.first.uri.toString(),
            contains(scenario.endpointFragment),
            reason: scenario.label,
          );
          final firstRequestData =
              capturedRequests.first.data as Map<String, dynamic>;
          expect(firstRequestData['tools'], isA<List<dynamic>>());
          expect(capturedRequests.last.data.toString(), contains('lib/a.dart'));
        } finally {
          $dio.interceptors.remove(interceptor);
        }
      }
    });

    test('Gemini uses function calls to inspect staged changes', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final capturedRequests = <RequestOptions>[];
      _addQueuedDioResponses(
        capturedRequests,
        <Map<String, dynamic>>[
          <String, dynamic>{
            'candidates': <Map<String, dynamic>>[
              <String, dynamic>{
                'content': <String, dynamic>{
                  'parts': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'functionCall': <String, dynamic>{
                        'name': 'list_staged_files',
                        'args': <String, dynamic>{},
                      },
                    },
                  ],
                },
              },
            ],
          },
          <String, dynamic>{
            'candidates': <Map<String, dynamic>>[
              <String, dynamic>{
                'content': <String, dynamic>{
                  'parts': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'text': 'feat: add agent mode',
                    },
                  ],
                },
              },
            ],
          },
        ],
      );

      final generator = GeminiGenerator('test-key', variant: 'gemini-test');
      expect(generator, isA<AgentCommitGenerator>());

      final message = await generator.generateAgentCommitMessage(
        AgentCommitRequest(
          tools: GitAgentTools(
            folderPath: repo.path,
            onToolUse: (_) {},
          ),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add agent mode');
      expect(capturedRequests, hasLength(2));
      expect(
        capturedRequests.first.uri.toString(),
        contains('googleapis.com'),
      );
      expect(
        capturedRequests.first.data.toString(),
        contains('functionDeclarations'),
      );
      expect(
        capturedRequests.first.data.toString(),
        isNot(contains('additionalProperties')),
      );
      expect(
        capturedRequests.last.data.toString(),
        contains('functionResponse'),
      );
    });

    test('Ollama uses chat tool calls to inspect staged changes', () async {
      final repo = await _createRepoWithStagedFile();
      addTearDown(() => repo.delete(recursive: true));
      final capturedRequests = <RequestOptions>[];
      _addQueuedDioResponses(
        capturedRequests,
        <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'role': 'assistant',
              'content': '',
              'tool_calls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'function': <String, dynamic>{
                    'name': 'list_staged_files',
                    'arguments': <String, dynamic>{},
                  },
                },
              ],
            },
          },
          <String, dynamic>{
            'message': <String, dynamic>{
              'role': 'assistant',
              'content': 'feat: add agent mode',
            },
          },
        ],
      );

      final generator = OllamaGenerator(
        'http://localhost:11434',
        null,
        variant: 'llama3.1',
      );
      expect(generator, isA<AgentCommitGenerator>());

      final message = await generator.generateAgentCommitMessage(
        AgentCommitRequest(
          tools: GitAgentTools(
            folderPath: repo.path,
            onToolUse: (_) {},
          ),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add agent mode');
      expect(capturedRequests, hasLength(2));
      expect(capturedRequests.first.uri.toString(), contains('/api/chat'));
      expect(capturedRequests.first.data.toString(), contains('tools'));
      expect(capturedRequests.last.data.toString(), contains('lib/a.dart'));
    });
  });
}

List<Map<String, dynamic>> _openAiCompatibleToolResponses() {
  return <Map<String, dynamic>>[
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
  ];
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

Future<Directory> _createRepoWithModifiedFile() async {
  final repo = await Directory.systemTemp.createTemp('gitwhisper_agent_test_');
  final libDir = await Directory(p.join(repo.path, 'lib')).create();
  final file = File(p.join(libDir.path, 'a.dart'));
  await file.writeAsString(
    [
      'original line 1',
      'original line 2',
      'original line 3',
      'original line 4',
      'original line 5',
      '',
    ].join('\n'),
  );
  await _runGit(repo, <String>['init']);
  await _runGit(repo, <String>['add', 'lib/a.dart']);
  await _runGit(repo, <String>[
    '-c',
    'user.name=Test User',
    '-c',
    'user.email=test@example.com',
    'commit',
    '-m',
    'initial commit',
  ]);
  await file.writeAsString(
    [
      'original line 1',
      'updated line 2',
      'original line 3',
      'updated line 4',
      'original line 5',
      'new line 6',
      '',
    ].join('\n'),
  );
  await _runGit(repo, <String>['add', 'lib/a.dart']);
  return repo;
}

Future<Directory> _createRepoWithRelatedFiles() async {
  final repo = await _createRepoWithModifiedFile();
  final testDir = await Directory(p.join(repo.path, 'test')).create();
  await File(p.join(testDir.path, 'a_test.dart')).writeAsString(
    'void main() {}\n',
  );
  await _runGit(repo, <String>['add', 'test/a_test.dart']);
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

Interceptor _addQueuedDioResponses(
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
  return interceptor;
}

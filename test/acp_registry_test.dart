import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AcpRegistryLoader cache-first loading', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gw_registry_test_');
    });

    tearDown(() => dir.delete(recursive: true));

    test('uses a fresh cache without hitting the network', () async {
      final cache = File(p.join(dir.path, 'registry.json'))
        ..writeAsStringSync(_registryBody('cached-acp'));
      final adapter = _RecordingAdapter(_registryBody('network-acp'));
      final loader = AcpRegistryLoader(
        dio: Dio()..httpClientAdapter = adapter,
        cacheFile: cache,
        registryUrl: 'https://example.com/registry.json',
      );

      final registry = await loader.load();

      expect(adapter.calls, 0, reason: 'fresh cache should skip the network');
      expect(registry.agents.single.id, 'cached-acp');
    });

    test('forceRefresh fetches from the network and rewrites the cache',
        () async {
      final cache = File(p.join(dir.path, 'registry.json'))
        ..writeAsStringSync(_registryBody('cached-acp'));
      final adapter = _RecordingAdapter(_registryBody('network-acp'));
      final loader = AcpRegistryLoader(
        dio: Dio()..httpClientAdapter = adapter,
        cacheFile: cache,
        registryUrl: 'https://example.com/registry.json',
      );

      final registry = await loader.load(forceRefresh: true);

      expect(adapter.calls, 1);
      expect(registry.agents.single.id, 'network-acp');
      expect(cache.readAsStringSync(), contains('network-acp'));
    });

    test('a stale cache triggers a network refresh', () async {
      final cache = File(p.join(dir.path, 'registry.json'))
        ..writeAsStringSync(_registryBody('cached-acp'));
      await cache.setLastModified(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      final adapter = _RecordingAdapter(_registryBody('network-acp'));
      final loader = AcpRegistryLoader(
        dio: Dio()..httpClientAdapter = adapter,
        cacheFile: cache,
        registryUrl: 'https://example.com/registry.json',
        cacheTtl: const Duration(hours: 6),
      );

      final registry = await loader.load();

      expect(adapter.calls, 1, reason: 'stale cache should refresh');
      expect(registry.agents.single.id, 'network-acp');
    });

    test('falls back to a stale cache when the network fails', () async {
      final cache = File(p.join(dir.path, 'registry.json'))
        ..writeAsStringSync(_registryBody('cached-acp'));
      await cache.setLastModified(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      final adapter = _ThrowingAdapter();
      final loader = AcpRegistryLoader(
        dio: Dio()..httpClientAdapter = adapter,
        cacheFile: cache,
        registryUrl: 'https://example.com/registry.json',
      );

      final registry = await loader.load();

      expect(adapter.calls, 1);
      expect(registry.agents.single.id, 'cached-acp');
    });
  });

  test('resolveSupported resolves product-backed ACP agents', () {
    final registry = AcpRegistry(<AcpAgentDefinition>[
      _agent('codex-acp', 'Codex CLI'),
      _agent('vtcode', 'VT Code'),
    ]);

    expect(registry.resolveSupported('codex').id, 'codex-acp');
  });

  test('resolveSupported rejects generic ACP wrappers', () {
    final registry = AcpRegistry(<AcpAgentDefinition>[
      _agent('codex-acp', 'Codex CLI'),
      _agent('vtcode', 'VT Code'),
    ]);

    expect(
      () => registry.resolveSupported('vtcode'),
      throwsA(
        isA<AcpRegistryException>().having(
          (error) => error.message,
          'message',
          contains('does not target generic or unsupported ACP entries'),
        ),
      ),
    );
  });

  test('resolveSupported rejects closed services still in the ACP registry',
      () {
    final registry = AcpRegistry(<AcpAgentDefinition>[
      _agent('codex-acp', 'Codex CLI'),
      _agent('corust-agent', 'Corust Agent'),
    ]);

    expect(
      registry.supportedCommitAgents.map((agent) => agent.id),
      isNot(contains('corust-agent')),
    );
    expect(
      () => registry.resolveSupported('corust-agent'),
      throwsA(isA<AcpRegistryException>()),
    );
  });

  group('exact agent id matching', () {
    final registry = AcpRegistry(<AcpAgentDefinition>[
      _agent('codex-acp', 'Codex CLI'),
      _agent('claude-acp', 'Claude Agent'),
      _agent('qoder', 'Qoder CLI'),
      _agent('kimi', 'Kimi CLI'),
    ]);

    test('resolves exact ids case-insensitively and known aliases', () {
      expect(registry.resolveSupported('qoder').id, 'qoder');
      expect(registry.resolveSupported('Kimi').id, 'kimi');
      expect(registry.resolveSupported('claude-code').id, 'claude-acp');
    });

    test('no longer resolves partial ids or display names', () {
      for (final query in <String>['qod', 'code', 'Codex CLI', 'acp']) {
        expect(
          () => registry.resolveSupported(query),
          throwsA(isA<AcpRegistryException>()),
          reason: query,
        );
      }
    });

    test('suggests close ids on a near miss', () {
      expect(
        () => registry.resolveSupported('qodr'),
        throwsA(
          isA<AcpRegistryException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Could not find an ACP agent with id "qodr"'),
              contains('Did you mean "qoder"?'),
            ),
          ),
        ),
      );
      expect(
        () => registry.resolve('Codex CLI'),
        throwsA(
          isA<AcpRegistryException>().having(
            (error) => error.message,
            'message',
            contains('"codex-acp"'),
          ),
        ),
      );
    });
  });

  test('parses binary sha256 checksums from the registry', () {
    final registry = AcpRegistry.fromJson(<String, dynamic>{
      'agents': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'kimi',
          'name': 'Kimi CLI',
          'version': '1.50.0',
          'distribution': <String, dynamic>{
            'binary': <String, dynamic>{
              'darwin-aarch64': <String, dynamic>{
                'archive': 'https://example.com/kimi.tar.gz',
                'cmd': './kimi',
                'sha256': '5684F903cfc1ca1be4135a2634f7db108c787827c084b41df6a'
                    '98eb01c9012df',
              },
              'linux-x86_64': <String, dynamic>{
                'archive': 'https://example.com/kimi-linux.tar.gz',
                'cmd': './kimi',
              },
            },
          },
        },
      ],
    });
    final binaries = registry.agents.single.binaryDistributions;

    expect(
      binaries['darwin-aarch64']!.sha256,
      '5684f903cfc1ca1be4135a2634f7db108c787827c084b41df6a98eb01c9012df',
    );
    expect(binaries['darwin-aarch64']!.hasValidSha256, isTrue);
    expect(binaries['linux-x86_64']!.sha256, isNull);
  });
}

AcpAgentDefinition _agent(String id, String name) {
  return AcpAgentDefinition(
    id: id,
    name: name,
    version: '1.0.0',
    npxPackage: '$id@1.0.0',
  );
}

String _registryBody(String agentId) {
  return '{"version":"1.0.0","agents":[{"id":"$agentId",'
      '"name":"Test Agent","version":"1.0.0",'
      '"distribution":{"npx":{"package":"$agentId"}}}]}';
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body);

  final String body;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    throw DioException(requestOptions: options, error: 'network down');
  }

  @override
  void close({bool force = false}) {}
}

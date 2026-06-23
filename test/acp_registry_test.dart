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

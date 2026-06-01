import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:test/test.dart';

void main() {
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

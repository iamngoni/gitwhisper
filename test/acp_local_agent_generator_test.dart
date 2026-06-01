import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/acp/acp_client.dart';
import 'package:gitwhisper/src/acp/acp_registry.dart';
import 'package:gitwhisper/src/agent/agent_commit_generator.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/models/acp_local_agent_generator.dart';
import 'package:gitwhisper/src/models/language.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ACP local agents', () {
    test('codex resolves codex-acp from registry and speaks ACP', () async {
      final fake = await FakeAcpAgent.create();
      addTearDown(fake.dispose);

      final generator = AcpLocalAgentGenerator(
        model: 'codex',
        registryQuery: 'codex',
        registryLoader: fake.registryLoader,
        environment: fake.environment,
        workingDirectory: fake.workingDirectory,
      );

      final message = await generator.generateAgentCommitMessage(
        const AgentCommitRequest(
          tools: GitAgentTools(),
          language: Language.english,
          prefix: 'GW-12',
        ),
      );

      expect(message, 'feat: add ACP local agent support');
      final invocation = await fake.readInvocation();
      expect(invocation.args, [
        '-y',
        '@zed-industries/codex-acp@0.15.0',
      ]);
      expect(invocation.mcpServers.single['name'], 'gitwhisper');
      expect(invocation.mcpServers.single['env'], isA<List<dynamic>>());
      expect(invocation.mcpServers.single['args'], contains('git-tools'));
      expect(
        invocation.mcpServers.single['args'],
        contains(fake.workingDirectory),
      );
      expect(invocation.methods, [
        'initialize',
        'session/new',
        'session/prompt',
      ]);
      expect(invocation.prompt, contains('GW-12'));
      expect(invocation.prompt, contains('Inspect staged git changes'));
      final logPath = AcpDebugLog.lastLogPath;
      expect(logPath, isNotNull);
      expect(await File(logPath!).readAsString(), contains('final_agent_text'));
    });

    test('claude-code resolves claude-acp from registry', () async {
      final fake = await FakeAcpAgent.create();
      addTearDown(fake.dispose);

      final generator = AcpLocalAgentGenerator(
        model: 'claude-code',
        registryQuery: 'claude-code',
        registryLoader: fake.registryLoader,
        environment: fake.environment,
        workingDirectory: fake.workingDirectory,
      );

      final analysis = await generator.analyzeChanges(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
      );

      expect(analysis, 'feat: add ACP local agent support');
      final invocation = await fake.readInvocation();
      expect(invocation.args, [
        '-y',
        '@agentclientprotocol/claude-agent-acp@0.37.0',
      ]);
    });

    test('runs terminal auth and retries when an ACP agent requires login',
        () async {
      final fake = await FakeAuthAcpAgent.create();
      addTearDown(fake.dispose);

      final generator = AcpLocalAgentGenerator(
        model: 'kimi',
        registryQuery: 'kimi',
        registryLoader: fake.registryLoader,
        environment: fake.environment,
        workingDirectory: fake.workingDirectory,
      );

      final message = await generator.generateCommitMessage(
        'diff --git a/README.md b/README.md\n+Docs',
        Language.english,
      );

      expect(message, 'feat: add ACP auth retry');
      final invocations = await fake.readInvocations();
      expect(invocations.map((invocation) => invocation.args), [
        ['-y', 'kimi'],
        ['-y', 'kimi', 'login'],
        ['-y', 'kimi'],
      ]);
      expect(invocations.last.methods, [
        'initialize',
        'session/new',
        'session/prompt',
      ]);
    });

    test('fails clearly when an ACP agent reports a plan limit', () async {
      final fake = await FakeAcpAgent.create(
        responseText: 'Upgrade your plan to continue',
      );
      addTearDown(fake.dispose);

      final generator = AcpLocalAgentGenerator(
        model: 'codex',
        registryQuery: 'codex',
        registryLoader: fake.registryLoader,
        environment: fake.environment,
        workingDirectory: fake.workingDirectory,
      );

      expect(
        () => generator.generateAgentCommitMessage(
          const AgentCommitRequest(
            tools: GitAgentTools(),
            language: Language.english,
          ),
        ),
        throwsA(
          isA<AcpException>().having(
            (error) => error.message,
            'message',
            contains('requires a plan upgrade'),
          ),
        ),
      );
    });

    test('auto-allows read-only GitWhisper MCP permission requests', () async {
      if (Platform.isWindows) return;
      final fake = await FakeAcpAgent.create(requestPermission: true);
      addTearDown(fake.dispose);

      final generator = AcpLocalAgentGenerator(
        model: 'codex',
        registryQuery: 'codex',
        registryLoader: fake.registryLoader,
        environment: fake.environment,
        workingDirectory: fake.workingDirectory,
      );

      final message = await generator.generateAgentCommitMessage(
        const AgentCommitRequest(
          tools: GitAgentTools(),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add ACP local agent support');
      final invocation = await fake.readInvocation();
      expect(
        invocation.permissionResponse?['result'],
        {
          'outcome': {'outcome': 'selected', 'optionId': 'allow-once'},
        },
      );
    });

    test('re-prompts ACP agents that stop before a commit message', () async {
      if (Platform.isWindows) return;
      final fake = await FakeAcpAgent.create(
        responseText:
            'Let me inspect the staged changes.|||feat: add ACP retry prompt',
      );
      addTearDown(fake.dispose);

      final generator = AcpLocalAgentGenerator(
        model: 'codex',
        registryQuery: 'codex',
        registryLoader: fake.registryLoader,
        environment: fake.environment,
        workingDirectory: fake.workingDirectory,
      );

      final message = await generator.generateAgentCommitMessage(
        const AgentCommitRequest(
          tools: GitAgentTools(),
          language: Language.english,
        ),
      );

      expect(message, 'feat: add ACP retry prompt');
      final invocation = await fake.readInvocation();
      expect(
        invocation.methods.where((method) => method == 'session/prompt'),
        hasLength(2),
      );
    });

    test('fails clearly when registry cannot be fetched or loaded', () async {
      final temp = await Directory.systemTemp.createTemp('gitwhisper_acp_');
      addTearDown(() => temp.delete(recursive: true));

      final generator = AcpLocalAgentGenerator(
        model: 'codex',
        registryQuery: 'codex',
        registryLoader: AcpRegistryLoader(
          registryUrl: 'http://127.0.0.1:1/missing.json',
          cacheFile: File(p.join(temp.path, 'missing-registry.json')),
        ),
      );

      expect(
        () => generator.generateCommitMessage('diff', Language.english),
        throwsA(isA<AcpRegistryException>()),
      );
    });
  });
}

class FakeAcpAgent {
  FakeAcpAgent._({
    required this.root,
    required this.binDir,
    required this.captureFile,
    required this.workingDirectory,
    required this.registryLoader,
    required this.responseText,
    required this.requestPermission,
  });

  final Directory root;
  final Directory binDir;
  final File captureFile;
  final String workingDirectory;
  final AcpRegistryLoader registryLoader;
  final bool requestPermission;

  Map<String, String> get environment => {
        'PATH': '${binDir.path}${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH'] ?? ''}',
        'GITWHISPER_FAKE_ACP_CAPTURE': captureFile.path,
        'GITWHISPER_FAKE_ACP_RESPONSE': responseText,
        if (requestPermission) 'GITWHISPER_FAKE_ACP_REQUEST_PERMISSION': 'true',
      };

  final String responseText;

  static Future<FakeAcpAgent> create({
    String responseText = 'feat: add ACP local agent support',
    bool requestPermission = false,
  }) async {
    final root = await Directory.systemTemp.createTemp('gitwhisper_acp_test_');
    final binDir = await Directory(p.join(root.path, 'bin')).create();
    final workspace = await Directory(p.join(root.path, 'workspace')).create();
    final captureFile = File(p.join(root.path, 'invocation.json'));
    final registryFile = File(p.join(root.path, 'registry.json'));

    await registryFile.writeAsString(
      jsonEncode(
        <String, dynamic>{
          'version': '1.0.0',
          'agents': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'codex-acp',
              'name': 'Codex CLI',
              'version': '0.15.0',
              'distribution': <String, dynamic>{
                'npx': <String, dynamic>{
                  'package': '@zed-industries/codex-acp@0.15.0',
                },
              },
            },
            <String, dynamic>{
              'id': 'claude-acp',
              'name': 'Claude Agent',
              'version': '0.37.0',
              'distribution': <String, dynamic>{
                'npx': <String, dynamic>{
                  'package': '@agentclientprotocol/claude-agent-acp@0.37.0',
                },
              },
            },
          ],
        },
      ),
    );

    final script =
        File(p.join(binDir.path, Platform.isWindows ? 'npx.bat' : 'npx'));
    if (Platform.isWindows) {
      await script.writeAsString(_windowsFakeAcpScript);
    } else {
      await script.writeAsString(_unixFakeAcpScript);
      await Process.run('chmod', ['+x', script.path]);
    }

    return FakeAcpAgent._(
      root: root,
      binDir: binDir,
      captureFile: captureFile,
      workingDirectory: workspace.path,
      registryLoader: AcpRegistryLoader(
        registryUrl: 'http://127.0.0.1:1/unused.json',
        cacheFile: registryFile,
      ),
      responseText: responseText,
      requestPermission: requestPermission,
    );
  }

  Future<FakeAcpInvocation> readInvocation() async {
    final json =
        jsonDecode(await captureFile.readAsString()) as Map<String, dynamic>;
    return FakeAcpInvocation(
      args: (json['args'] as List<dynamic>).cast<String>(),
      methods: (json['methods'] as List<dynamic>).cast<String>(),
      mcpServers:
          (json['mcpServers'] as List<dynamic>).cast<Map<String, dynamic>>(),
      prompt: json['prompt'] as String,
      permissionResponse: json['permissionResponse'] as Map<String, dynamic>?,
    );
  }

  Future<void> dispose() => root.delete(recursive: true);
}

class FakeAcpInvocation {
  const FakeAcpInvocation({
    required this.args,
    required this.methods,
    required this.mcpServers,
    required this.prompt,
    this.permissionResponse,
  });

  final List<String> args;
  final List<String> methods;
  final List<Map<String, dynamic>> mcpServers;
  final String prompt;
  final Map<String, dynamic>? permissionResponse;
}

class FakeAuthAcpAgent {
  FakeAuthAcpAgent._({
    required this.root,
    required this.binDir,
    required this.captureFile,
    required this.authMarkerFile,
    required this.workingDirectory,
    required this.registryLoader,
  });

  final Directory root;
  final Directory binDir;
  final File captureFile;
  final File authMarkerFile;
  final String workingDirectory;
  final AcpRegistryLoader registryLoader;

  Map<String, String> get environment => {
        'PATH': '${binDir.path}${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH'] ?? ''}',
        'GITWHISPER_FAKE_ACP_CAPTURE': captureFile.path,
        'GITWHISPER_FAKE_ACP_AUTH_MARKER': authMarkerFile.path,
      };

  static Future<FakeAuthAcpAgent> create() async {
    final root =
        await Directory.systemTemp.createTemp('gitwhisper_acp_auth_test_');
    final binDir = await Directory(p.join(root.path, 'bin')).create();
    final workspace = await Directory(p.join(root.path, 'workspace')).create();
    final captureFile = File(p.join(root.path, 'invocations.jsonl'));
    final authMarkerFile = File(p.join(root.path, 'authenticated'));
    final registryFile = File(p.join(root.path, 'registry.json'));

    await registryFile.writeAsString(
      jsonEncode(
        <String, dynamic>{
          'version': '1.0.0',
          'agents': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'kimi',
              'name': 'Kimi CLI',
              'version': '1.45.0',
              'distribution': <String, dynamic>{
                'npx': <String, dynamic>{'package': 'kimi'},
              },
            },
          ],
        },
      ),
    );

    final script =
        File(p.join(binDir.path, Platform.isWindows ? 'npx.bat' : 'npx'));
    if (Platform.isWindows) {
      await script.writeAsString(_windowsFakeAuthAcpScript);
    } else {
      await script.writeAsString(_unixFakeAuthAcpScript);
      await Process.run('chmod', ['+x', script.path]);
    }

    return FakeAuthAcpAgent._(
      root: root,
      binDir: binDir,
      captureFile: captureFile,
      authMarkerFile: authMarkerFile,
      workingDirectory: workspace.path,
      registryLoader: AcpRegistryLoader(
        registryUrl: 'http://127.0.0.1:1/unused.json',
        cacheFile: registryFile,
      ),
    );
  }

  Future<List<FakeAcpInvocation>> readInvocations() async {
    final lines = await captureFile.readAsLines();
    return lines.where((line) => line.trim().isNotEmpty).map((line) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      return FakeAcpInvocation(
        args: (json['args'] as List<dynamic>).cast<String>(),
        methods: (json['methods'] as List<dynamic>).cast<String>(),
        mcpServers:
            (json['mcpServers'] as List<dynamic>).cast<Map<String, dynamic>>(),
        prompt: json['prompt'] as String,
      );
    }).toList();
  }

  Future<void> dispose() => root.delete(recursive: true);
}

const _unixFakeAcpScript = '''
#!/usr/bin/env python3
import json
import os
import sys

methods = []
prompt = ""
mcp_servers = []
permission_response = None
responses = os.environ.get("GITWHISPER_FAKE_ACP_RESPONSE", "feat: add ACP local agent support").split("|||")
prompt_count = 0

for line in sys.stdin:
    if not line.strip():
        continue
    msg = json.loads(line)
    method = msg.get("method")
    if method:
        methods.append(method)
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}, "agentInfo": {"name": "fake-acp", "version": "1.0.0"}, "authMethods": []}}), flush=True)
    elif method == "session/new":
        mcp_servers = msg["params"].get("mcpServers", [])
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "sess_fake"}}), flush=True)
    elif method == "session/prompt":
        prompt = msg["params"]["prompt"][0]["text"]
        response_text = responses[prompt_count] if prompt_count < len(responses) else responses[-1]
        prompt_count += 1
        if os.environ.get("GITWHISPER_FAKE_ACP_REQUEST_PERMISSION") == "true":
            print(json.dumps({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": "sess_fake", "toolCall": {"toolCallId": "call_001", "title": "mcp:fake__agent__gitwhisper:list_staged_files", "kind": "read", "status": "pending"}, "options": [{"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"}, {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}]}}), flush=True)
            permission_response = json.loads(sys.stdin.readline())
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "sess_fake", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": response_text}}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}}), flush=True)
        if prompt_count >= len(responses):
            break

with open(os.environ["GITWHISPER_FAKE_ACP_CAPTURE"], "w", encoding="utf-8") as handle:
    json.dump({"args": sys.argv[1:], "methods": methods, "mcpServers": mcp_servers, "prompt": prompt, "permissionResponse": permission_response}, handle)
''';

const _unixFakeAuthAcpScript = r'''
#!/usr/bin/env python3
import json
import os
import sys

capture = os.environ["GITWHISPER_FAKE_ACP_CAPTURE"]
marker = os.environ["GITWHISPER_FAKE_ACP_AUTH_MARKER"]

def capture_invocation(methods, prompt):
    with open(capture, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"args": sys.argv[1:], "methods": methods, "mcpServers": globals().get("mcp_servers", []), "prompt": prompt}) + "\n")

if sys.argv[1:] == ["-y", "kimi", "login"]:
    open(marker, "w", encoding="utf-8").write("ok")
    capture_invocation([], "")
    sys.exit(0)

methods = []
prompt = ""
mcp_servers = []

for line in sys.stdin:
    if not line.strip():
        continue
    msg = json.loads(line)
    method = msg.get("method")
    if method:
        methods.append(method)
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}, "agentInfo": {"name": "fake-kimi", "version": "1.0.0"}, "authMethods": []}}), flush=True)
    elif method == "session/new":
        mcp_servers = msg["params"].get("mcpServers", [])
        if not os.path.exists(marker):
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000, "message": "Authentication required", "data": {"authMethods": [{"id": "login", "name": "Login with Kimi account", "description": "Run `kimi login` command in the terminal.", "type": "terminal", "args": ["login"], "env": {}}]}}}), flush=True)
            break
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "sess_fake"}}), flush=True)
    elif method == "session/prompt":
        prompt = msg["params"]["prompt"][0]["text"]
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "sess_fake", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "feat: add ACP auth retry"}}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}}), flush=True)
        break

capture_invocation(methods, prompt)
''';

const _windowsFakeAcpScript = r'''
@echo off
python -c "import json,os,sys; methods=[]; prompt=''; \
import sys as _s; \
for line in _s.stdin: \
    msg=json.loads(line); method=msg.get('method'); \
    methods.append(method) if method else None; \
    print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'protocolVersion':1,'agentCapabilities':{},'authMethods':[]}}), flush=True) if method=='initialize' else None; \
    print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'sessionId':'sess_fake'}}), flush=True) if method=='session/new' else None; \
    (globals().update(prompt=msg['params']['prompt'][0]['text']), print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'sess_fake','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':os.environ.get('GITWHISPER_FAKE_ACP_RESPONSE','feat: add ACP local agent support')}}}}), flush=True), print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'stopReason':'end_turn'}}), flush=True), sys.exit(0)) if method=='session/prompt' else None; \
open(os.environ['GITWHISPER_FAKE_ACP_CAPTURE'],'w').write(json.dumps({'args':sys.argv[1:],'methods':methods,'mcpServers':[],'prompt':prompt}))" %*
''';

const _windowsFakeAuthAcpScript = r'''
@echo off
python -c "import json,os,sys; capture=os.environ['GITWHISPER_FAKE_ACP_CAPTURE']; marker=os.environ['GITWHISPER_FAKE_ACP_AUTH_MARKER']; \
def cap(methods,prompt): open(capture,'a').write(json.dumps({'args':sys.argv[1:],'methods':methods,'mcpServers':[],'prompt':prompt})+'\n'); \
args=sys.argv[1:]; \
import sys as _s; \
if args == ['-y','kimi','login']: open(marker,'w').write('ok'); cap([],''); sys.exit(0); \
methods=[]; prompt=''; \
for line in _s.stdin: \
    msg=json.loads(line); method=msg.get('method'); \
    methods.append(method) if method else None; \
    print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'protocolVersion':1,'agentCapabilities':{},'authMethods':[]}}), flush=True) if method=='initialize' else None; \
    (print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'error':{'code':-32000,'message':'Authentication required','data':{'authMethods':[{'id':'login','name':'Login with Kimi account','description':'Run `kimi login` command in the terminal.','type':'terminal','args':['login'],'env':{}}]}}}), flush=True), cap(methods,prompt), sys.exit(0)) if method=='session/new' and not os.path.exists(marker) else None; \
    print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'sessionId':'sess_fake'}}), flush=True) if method=='session/new' else None; \
    (globals().update(prompt=msg['params']['prompt'][0]['text']), print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'sess_fake','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'feat: add ACP auth retry'}}}}), flush=True), print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'stopReason':'end_turn'}}), flush=True), cap(methods,prompt), sys.exit(0)) if method=='session/prompt' else None" %*
''';

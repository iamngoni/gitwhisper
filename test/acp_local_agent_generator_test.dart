import 'dart:convert';
import 'dart:io';

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
      expect(invocation.methods, [
        'initialize',
        'session/new',
        'session/prompt',
      ]);
      expect(invocation.prompt, contains('GW-12'));
      expect(invocation.prompt, contains('Inspect staged git changes'));
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
  });

  final Directory root;
  final Directory binDir;
  final File captureFile;
  final String workingDirectory;
  final AcpRegistryLoader registryLoader;

  Map<String, String> get environment => {
        'PATH': '${binDir.path}${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH'] ?? ''}',
        'GITWHISPER_FAKE_ACP_CAPTURE': captureFile.path,
      };

  static Future<FakeAcpAgent> create() async {
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
    );
  }

  Future<FakeAcpInvocation> readInvocation() async {
    final json =
        jsonDecode(await captureFile.readAsString()) as Map<String, dynamic>;
    return FakeAcpInvocation(
      args: (json['args'] as List<dynamic>).cast<String>(),
      methods: (json['methods'] as List<dynamic>).cast<String>(),
      prompt: json['prompt'] as String,
    );
  }

  Future<void> dispose() => root.delete(recursive: true);
}

class FakeAcpInvocation {
  const FakeAcpInvocation({
    required this.args,
    required this.methods,
    required this.prompt,
  });

  final List<String> args;
  final List<String> methods;
  final String prompt;
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
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "sess_fake"}}), flush=True)
    elif method == "session/prompt":
        prompt = msg["params"]["prompt"][0]["text"]
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "sess_fake", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "feat: add ACP local agent support"}}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}}), flush=True)
        break

with open(os.environ["GITWHISPER_FAKE_ACP_CAPTURE"], "w", encoding="utf-8") as handle:
    json.dump({"args": sys.argv[1:], "methods": methods, "prompt": prompt}, handle)
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
        handle.write(json.dumps({"args": sys.argv[1:], "methods": methods, "prompt": prompt}) + "\n")

if sys.argv[1:] == ["-y", "kimi", "login"]:
    open(marker, "w", encoding="utf-8").write("ok")
    capture_invocation([], "")
    sys.exit(0)

methods = []
prompt = ""

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
    (globals().update(prompt=msg['params']['prompt'][0]['text']), print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'sess_fake','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'feat: add ACP local agent support'}}}}), flush=True), print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'stopReason':'end_turn'}}), flush=True), sys.exit(0)) if method=='session/prompt' else None; \
open(os.environ['GITWHISPER_FAKE_ACP_CAPTURE'],'w').write(json.dumps({'args':sys.argv[1:],'methods':methods,'prompt':prompt}))" %*
''';

const _windowsFakeAuthAcpScript = r'''
@echo off
python -c "import json,os,sys; capture=os.environ['GITWHISPER_FAKE_ACP_CAPTURE']; marker=os.environ['GITWHISPER_FAKE_ACP_AUTH_MARKER']; \
def cap(methods,prompt): open(capture,'a').write(json.dumps({'args':sys.argv[1:],'methods':methods,'prompt':prompt})+'\n'); \
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

import 'package:gitwhisper/src/acp/acp_client.dart';
import 'package:test/test.dart';

void main() {
  test('ACP auth errors explain agent provider setup', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32603,
      'message': 'Internal error',
      'data': 'OpenAI Chat Completions error (status 401 Unauthorized): '
          "You didn't provide an API key.",
    });

    expect(error.message, contains('model provider is not authenticated'));
    expect(error.message, contains('login command'));
    expect(error.message, contains('provider API key'));
  });

  test('ACP structured auth methods are shown as recovery instructions', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32000,
      'message': 'Authentication required',
      'data': <String, dynamic>{
        'authMethods': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'login',
            'name': 'Login with Kimi account',
            'description': 'Run `kimi login` command in the terminal, then '
                'follow the instructions to finish login.',
            'type': 'terminal',
            'args': <String>['login'],
            'env': <String, dynamic>{},
          },
        ],
      },
    });

    expect(error, isA<AcpAuthenticationRequiredException>());
    expect(error.message, contains('Authentication required'));
    expect(error.message, contains('Login with Kimi account'));
    expect(error.message, contains('kimi login'));
    expect(error.message, isNot(contains('{authMethods')));
  });

  test('ACP auth message fallback extracts terminal command instructions', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32000,
      'message': 'Authentication required',
      'data': <String, dynamic>{
        'message': 'Run `pool login` in a terminal to authenticate to '
            'Poolside.',
      },
    });

    expect(error, isA<AcpAuthenticationRequiredException>());
    final authError = error as AcpAuthenticationRequiredException;
    expect(authError.authMethods.single.command, ['pool', 'login']);
    expect(authError.message, contains('pool login'));
    expect(authError.message, isNot(contains('{message')));
  });

  test('ACP auth message fallback extracts Cursor login and method id', () {
    final error = AcpException.fromJsonRpcError(<String, dynamic>{
      'code': -32000,
      'message': 'Authentication required',
      'data': <String, dynamic>{
        'message': "Authentication required. Please run 'agent login' first, "
            "then call authenticate() with methodId 'cursor_login'.",
      },
    });

    expect(error, isA<AcpAuthenticationRequiredException>());
    final authError = error as AcpAuthenticationRequiredException;
    final method = authError.authMethods.single;
    expect(method.command, ['agent', 'login']);
    expect(method.authenticateMethodId, 'cursor_login');
    expect(authError.message, isNot(contains('{message}')));
  });

  test('ACP auth method parser reads terminal-auth metadata', () {
    final method = AcpAuthMethod.fromJson(<String, dynamic>{
      'id': 'login',
      'name': 'Login with Kimi account',
      'description': 'Run `kimi login`.',
      '_meta': <String, dynamic>{
        'terminal-auth': <String, dynamic>{
          'command': '/tmp/kimi',
          'args': <String>['login'],
          'type': 'terminal',
          'env': <String, dynamic>{'KIMI_TEST': '1'},
        },
      },
    });

    expect(method.isTerminal, isTrue);
    expect(method.command, ['/tmp/kimi', 'login']);
    expect(method.environment, containsPair('KIMI_TEST', '1'));
  });
}

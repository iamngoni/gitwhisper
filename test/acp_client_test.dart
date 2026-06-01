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
    expect(error.message, contains('vtcode auth'));
    expect(error.message, contains('OPENAI_API_KEY'));
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
}

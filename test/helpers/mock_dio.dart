import 'package:dio/dio.dart';
import 'package:gitwhisper/src/agent/git_agent_tools.dart';
import 'package:gitwhisper/src/constants.dart';
import 'package:test/test.dart';

/// A canned reply for one request made through `$dio`.
class MockReply {
  const MockReply(
    this.data, {
    this.statusCode = 200,
    this.headers = const <String, List<String>>{},
  });

  /// A JSON object reply with status 200.
  const MockReply.json(Map<String, dynamic> data) : this(data);

  final Object? data;
  final int statusCode;
  final Map<String, List<String>> headers;
}

/// Answers the next `$dio` requests with [replies], in order, and returns
/// the captured requests. Replies with a status of 400 or more are thrown as
/// bad-response [DioException]s, as Dio does by default. No request leaves
/// the process.
List<RequestOptions> mockDio(List<MockReply> replies) {
  final queue = List<MockReply>.of(replies);
  final requests = <RequestOptions>[];

  final interceptor = InterceptorsWrapper(
    onRequest: (options, handler) {
      requests.add(options);
      if (queue.isEmpty) {
        handler.reject(
          DioException(
            requestOptions: options,
            error: StateError('Unexpected request to ${options.uri}'),
          ),
        );
        return;
      }

      final reply = queue.removeAt(0);
      final response = Response<dynamic>(
        requestOptions: options,
        statusCode: reply.statusCode,
        data: reply.data,
        headers: Headers.fromMap(reply.headers),
      );

      if (reply.statusCode >= 400) {
        handler.reject(
          DioException.badResponse(
            statusCode: reply.statusCode,
            requestOptions: options,
            response: response,
          ),
        );
      } else {
        handler.resolve(response);
      }
    },
  );

  $dio.interceptors.add(interceptor);
  addTearDown(() => $dio.interceptors.remove(interceptor));
  return requests;
}

/// The JSON body of a captured request.
Map<String, dynamic> bodyOf(RequestOptions request) =>
    request.data as Map<String, dynamic>;

/// Agent tools that answer every call without touching git.
class FakeAgentTools extends GitAgentTools {
  FakeAgentTools();

  final List<String> calls = <String>[];

  @override
  Future<String> execute(String name, Map<String, dynamic> input) async {
    calls.add(name);
    return 'result of $name';
  }
}

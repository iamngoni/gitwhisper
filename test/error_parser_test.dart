import 'package:dio/dio.dart';
import 'package:gitwhisper/src/constants.dart';
import 'package:gitwhisper/src/exceptions/exceptions.dart';
import 'package:test/test.dart';

void main() {
  group('ErrorParser retry-after', () {
    test('reads seconds from the retry-after header', () {
      final error = ErrorParser.parseError(
        _badResponse(
          429,
          <String, dynamic>{
            'error': <String, dynamic>{'message': 'Slow down'},
          },
          headers: <String, List<String>>{
            'retry-after': <String>['30'],
          },
        ),
      );

      expect(error, isA<RateLimitException>());
      expect(error.retryAfter, 30);
      expect(error.message, 'Slow down');
    });

    test('prefers the header over the body', () {
      final error = ErrorParser.parseError(
        _badResponse(
          429,
          <String, dynamic>{'retry_after': 99},
          headers: <String, List<String>>{
            'Retry-After': <String>['5'],
          },
        ),
      );

      expect(error.retryAfter, 5);
    });

    test('falls back to the body when the header is unreadable', () {
      final error = ErrorParser.parseError(
        _badResponse(
          429,
          <String, dynamic>{'retry_after': '12'},
          headers: <String, List<String>>{
            'retry-after': <String>['soon'],
          },
        ),
      );

      expect(error.retryAfter, 12);
    });

    test('accepts fractional and string body values without throwing', () {
      for (final (value, expected) in <(Object, int)>[
        (1.5, 2),
        ('7', 7),
        ('2.1', 3),
      ]) {
        final error = ErrorParser.parseError(
          _badResponse(429, <String, dynamic>{'retry_after': value}),
        );
        expect(error.retryAfter, expected, reason: '$value');
      }
    });

    test('parses HTTP-dates relative to now', () {
      expect(
        ErrorParser.parseRetryAfter(
          'Wed, 14 Oct 2026 12:01:00 GMT',
          now: DateTime.utc(2026, 10, 14, 12),
        ),
        60,
      );
      expect(
        ErrorParser.parseRetryAfter(
          'Wed, 14 Oct 2026 11:00:00 GMT',
          now: DateTime.utc(2026, 10, 14, 12),
        ),
        0,
      );
    });

    test('ignores values it cannot read', () {
      for (final value in <Object?>[
        null,
        '',
        'later',
        'NaN',
        <int>[1],
      ]) {
        expect(ErrorParser.parseRetryAfter(value), isNull, reason: '$value');
      }
    });

    test("reads Gemini's RetryInfo delay", () {
      final error = ErrorParser.parseProviderError(
        'gemini',
        _badResponse(429, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 429,
            'message': 'Quota exceeded',
            'status': 'RESOURCE_EXHAUSTED',
            'details': <Map<String, dynamic>>[
              <String, dynamic>{
                '@type': 'type.googleapis.com/google.rpc.RetryInfo',
                'retryDelay': '39s',
              },
            ],
          },
        }),
      );

      expect(error, isA<RateLimitException>());
      expect(error.retryAfter, 39);
    });
  });

  group('ErrorParser error bodies', () {
    test('decodes JSON error bodies that arrive as text', () {
      final error = ErrorParser.parseError(
        _badResponse(404, '{"error":{"message":"model not found"}}'),
      );

      expect(error, isA<ResourceNotFoundException>());
      expect(error.message, 'model not found');
    });

    test('keeps plain-text error bodies', () {
      final error = ErrorParser.parseError(
        _badResponse(400, 'model does not support tools'),
      );

      expect(error, isA<InvalidRequestException>());
      expect(error.message, 'model does not support tools');
    });

    test('reads errors wrapped in a list', () {
      final error = ErrorParser.parseError(
        _badResponse(400, <Map<String, dynamic>>[
          <String, dynamic>{
            'error': <String, dynamic>{'message': 'API key not valid'},
          },
        ]),
      );

      expect(error, isA<InvalidRequestException>());
      expect(error.message, 'API key not valid');
    });

    test('maps Dio timeouts to ApiTimeoutException', () {
      final error = ErrorParser.parseError(
        DioException.connectionTimeout(
          timeout: const Duration(seconds: 30),
          requestOptions: RequestOptions(path: 'https://example.com'),
        ),
      );

      expect(error, isA<ApiTimeoutException>());
    });
  });

  group('shared Dio client', () {
    test('has timeouts so a stalled connection cannot hang forever', () {
      final options = $dio.options;

      expect(options.connectTimeout, const Duration(seconds: 30));
      expect(options.sendTimeout, isNotNull);
      // Dio measures receiveTimeout between chunks, so this must stay
      // generous enough for slow non-streamed generations.
      expect(
        options.receiveTimeout,
        greaterThanOrEqualTo(const Duration(minutes: 5)),
      );
    });
  });
}

DioException _badResponse(
  int statusCode,
  Object? data, {
  Map<String, List<String>> headers = const <String, List<String>>{},
}) {
  final requestOptions = RequestOptions(path: 'https://example.com');
  return DioException.badResponse(
    statusCode: statusCode,
    requestOptions: requestOptions,
    response: Response<dynamic>(
      requestOptions: requestOptions,
      statusCode: statusCode,
      data: data,
      headers: Headers.fromMap(headers),
    ),
  );
}

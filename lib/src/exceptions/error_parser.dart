//
//  gitwhisper
//  error_parser.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'api_exceptions.dart';

/// Utility class for parsing API errors from different providers
class ErrorParser {
  /// Upper bound for parsed retry delays, so a bogus value can't overflow.
  static const int _maxRetryAfterSeconds = 7 * 24 * 60 * 60;

  /// Longest plain-text error body kept in an exception message.
  static const int _maxPlainTextErrorLength = 500;

  /// Parse error response from different API providers
  static ApiException parseError(DioException error) {
    final statusCode = error.response?.statusCode ?? 0;
    final headers = error.response?.headers;
    final responseData = _decodeErrorBody(error.response?.data);
    final requestId = _extractRequestId(headers);

    // Handle network/connection errors
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return ApiTimeoutException(
        message: 'Request timed out: ${error.message}',
        requestId: requestId,
      );
    }

    if (error.type == DioExceptionType.connectionError) {
      return const ServerException(
        message: 'Connection error: Unable to connect to the API service',
        statusCode: 503,
      );
    }

    // Parse error based on response format
    if (responseData is Map<String, dynamic>) {
      return _parseErrorResponse(statusCode, responseData, requestId, headers);
    }

    // Plain-text bodies still carry the provider's explanation.
    final message = _plainTextError(responseData) ?? error.message;
    if (statusCode > 0) {
      return _createSpecificError(
        statusCode: statusCode,
        message: message ?? 'Unknown error occurred',
        requestId: requestId,
        retryAfter: _extractRetryAfter(headers, null),
      );
    }

    // Fallback for unknown error format
    return _createGenericError(statusCode, message, requestId);
  }

  /// Parses a retry delay, in whole seconds, from a `Retry-After` header or
  /// a response body field.
  ///
  /// Accepts integer or fractional seconds given as numbers or strings (with
  /// an optional `s` suffix, as Gemini sends), and HTTP-dates. Returns null
  /// when [value] can't be read.
  static int? parseRetryAfter(Object? value, {DateTime? now}) {
    if (value is num) return _wholeSeconds(value);
    if (value is! String) return null;

    final text = value.trim();
    if (text.isEmpty) return null;

    final seconds = num.tryParse(
      text.endsWith('s') ? text.substring(0, text.length - 1).trim() : text,
    );
    if (seconds != null) return _wholeSeconds(seconds);

    try {
      final retryAt = HttpDate.parse(text);
      final wait = retryAt.difference(now ?? DateTime.now());
      return _wholeSeconds(wait.inMilliseconds / 1000);
    } on Exception {
      return null;
    }
  }

  static int? _wholeSeconds(num seconds) {
    if (seconds.isNaN || seconds.isInfinite) return null;
    if (seconds <= 0) return 0;
    return math.min(seconds, _maxRetryAfterSeconds).ceil();
  }

  /// Reads the retry delay from the `retry-after` header, falling back to
  /// `retry_after` in the body and Gemini's `RetryInfo` detail.
  static int? _extractRetryAfter(
    Headers? headers,
    Map<String, dynamic>? data,
  ) {
    final headerValues = headers?['retry-after'];
    if (headerValues != null && headerValues.isNotEmpty) {
      final fromHeader = parseRetryAfter(headerValues.first);
      if (fromHeader != null) return fromHeader;
    }

    if (data == null) return null;
    final errorData = data['error'];
    return parseRetryAfter(data['retry_after']) ??
        (errorData is Map ? parseRetryAfter(errorData['retry_after']) : null) ??
        _geminiRetryDelay(errorData);
  }

  static int? _geminiRetryDelay(Object? errorData) {
    if (errorData is! Map) return null;
    final details = errorData['details'];
    if (details is! List) return null;

    for (final detail in details) {
      if (detail is Map && detail['retryDelay'] != null) {
        return parseRetryAfter(detail['retryDelay']);
      }
    }
    return null;
  }

  /// Normalizes an error body to a JSON map where possible.
  ///
  /// Providers sometimes send JSON with a non-JSON content type (so Dio leaves
  /// it as a string) or wrap the error object in a list.
  static Object? _decodeErrorBody(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }
    if (data is List) {
      final first = data.isEmpty ? null : data.first;
      return first is Map ? _decodeErrorBody(first) : data;
    }
    if (data is String) {
      final text = data.trim();
      if (text.startsWith('{') || text.startsWith('[')) {
        try {
          return _decodeErrorBody(jsonDecode(text));
        } on FormatException {
          return text;
        }
      }
      return text;
    }
    return data;
  }

  /// Returns a short plain-text error body, skipping empty and HTML bodies.
  static String? _plainTextError(Object? data) {
    if (data is! String) return null;
    final text = data.trim();
    if (text.isEmpty || text.startsWith('<')) return null;
    if (text.length <= _maxPlainTextErrorLength) return text;
    return '${text.substring(0, _maxPlainTextErrorLength)}…';
  }

  /// Parse error response based on API provider format
  static ApiException _parseErrorResponse(
    int statusCode,
    Map<String, dynamic> data,
    String? requestId,
    Headers? headers,
  ) {
    String message = 'Unknown error';
    String? errorType;
    String? errorCode;

    // Parse different API response formats
    if (data.containsKey('error')) {
      final errorData = data['error'];
      if (errorData is Map<String, dynamic>) {
        // OpenAI/DeepSeek/Grok/GitHub format
        message = errorData['message']?.toString() ?? message;
        errorType = errorData['type']?.toString();
        errorCode = errorData['code']?.toString();
      } else if (errorData is String) {
        // Simple error format
        message = errorData;
      }
    } else if (data.containsKey('message')) {
      // Direct message format
      message = data['message']?.toString() ?? message;
    } else if (data.containsKey('detail')) {
      // Detail format (other APIs)
      message = data['detail']?.toString() ?? message;
    }

    return _createSpecificError(
      statusCode: statusCode,
      message: message,
      errorType: errorType,
      errorCode: errorCode,
      requestId: requestId,
      retryAfter: _extractRetryAfter(headers, data),
    );
  }

  /// Create specific error based on status code
  static ApiException _createSpecificError({
    required int statusCode,
    required String message,
    String? errorType,
    String? errorCode,
    String? requestId,
    int? retryAfter,
  }) {
    switch (statusCode) {
      case 400:
      case 422:
        return InvalidRequestException(
          message: message,
          statusCode: statusCode,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 401:
        return AuthenticationException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 402:
        return InsufficientBalanceException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 403:
        return PermissionException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 404:
        return ResourceNotFoundException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 413:
        return RequestTooLargeException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 429:
        return RateLimitException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
          retryAfter: retryAfter,
        );
      case 500:
      case 502:
      case 503:
        return ServerException(
          message: message,
          statusCode: statusCode,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 504:
        return ApiTimeoutException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      case 529:
        return ServiceOverloadedException(
          message: message,
          errorType: errorType,
          errorCode: errorCode,
          requestId: requestId,
        );
      default:
        return _createGenericError(statusCode, message, requestId);
    }
  }

  /// Create generic error for unknown status codes
  static ApiException _createGenericError(
    int statusCode,
    String? message,
    String? requestId,
  ) {
    return ServerException(
      message: message ?? 'Unknown error occurred',
      statusCode: statusCode,
      requestId: requestId,
    );
  }

  /// Extract request ID from response headers
  static String? _extractRequestId(Headers? headers) {
    if (headers == null) return null;

    // Check common request ID header names
    final requestIdHeaders = [
      'request-id',
      'x-request-id',
      'cf-ray',
      'x-trace-id',
      'trace-id',
    ];

    for (final headerName in requestIdHeaders) {
      final value = headers.value(headerName);
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  /// Parse provider-specific error formats
  static ApiException parseProviderError(
    String provider,
    DioException error,
  ) {
    final baseError = parseError(error);

    // Add provider-specific error handling if needed
    switch (provider.toLowerCase()) {
      case 'anthropic':
      case 'claude':
        return _parseClaudeError(error, baseError);
      case 'openai':
        return _parseOpenAIError(error, baseError);
      case 'gemini':
        return _parseGeminiError(error, baseError);
      case 'deepseek':
        return _parseDeepseekError(error, baseError);
      case 'grok':
        return _parseGrokError(error, baseError);
      default:
        return baseError;
    }
  }

  /// Parse Claude/Anthropic specific errors
  static ApiException _parseClaudeError(
    DioException error,
    ApiException baseError,
  ) {
    final responseData = _decodeErrorBody(error.response?.data);
    if (responseData is Map<String, dynamic> &&
        responseData.containsKey('error')) {
      final errorData = responseData['error'];
      if (errorData is Map<String, dynamic>) {
        final errorType = errorData['type'];

        // Handle Claude-specific error types
        switch (errorType) {
          case 'overloaded_error':
            return ServiceOverloadedException(
              message: errorData['message']?.toString() ??
                  'Service is temporarily overloaded',
              errorType: errorType?.toString(),
              requestId: _extractRequestId(error.response?.headers),
            );
          case 'authentication_error':
            return AuthenticationException(
              message: errorData['message']?.toString() ?? 'Invalid API key',
              errorType: errorType?.toString(),
              requestId: _extractRequestId(error.response?.headers),
            );
        }
      }
    }
    return baseError;
  }

  /// Parse OpenAI specific errors
  static ApiException _parseOpenAIError(
    DioException error,
    ApiException baseError,
  ) {
    return baseError;
  }

  /// Parse Gemini specific errors
  static ApiException _parseGeminiError(
    DioException error,
    ApiException baseError,
  ) {
    final responseData = _decodeErrorBody(error.response?.data);
    if (responseData is Map<String, dynamic> &&
        responseData.containsKey('error')) {
      final errorData = responseData['error'];
      if (errorData is Map<String, dynamic>) {
        final status = errorData['status'];
        final message = errorData['message'];

        // Handle Gemini-specific error statuses
        switch (status) {
          case 'RESOURCE_EXHAUSTED':
            return RateLimitException(
              message: message?.toString() ?? 'Rate limit exceeded',
              errorType: status?.toString(),
              requestId: _extractRequestId(error.response?.headers),
              retryAfter: baseError.retryAfter,
            );
          case 'FAILED_PRECONDITION':
            return PermissionException(
              message: message?.toString() ??
                  'API access not available in your region',
              errorType: status?.toString(),
              requestId: _extractRequestId(error.response?.headers),
            );
        }
      }
    }
    return baseError;
  }

  /// Parse DeepSeek specific errors
  static ApiException _parseDeepseekError(
    DioException error,
    ApiException baseError,
  ) {
    // DeepSeek uses OpenAI-compatible format
    return baseError;
  }

  /// Parse Grok specific errors
  static ApiException _parseGrokError(
    DioException error,
    ApiException baseError,
  ) {
    // Grok uses OpenAI-compatible format
    return baseError;
  }
}

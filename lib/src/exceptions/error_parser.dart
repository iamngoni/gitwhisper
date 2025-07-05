//
//  gitwhisper
//  error_parser.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'api_exceptions.dart';

/// Utility class for parsing API errors from different providers
class ErrorParser {
  /// Parse error response from different API providers
  static ApiException parseError(DioException error) {
    final statusCode = error.response?.statusCode ?? 0;
    final responseData = error.response?.data;
    final requestId = _extractRequestId(error.response?.headers);

    // Handle network/connection errors
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return TimeoutException(
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
      return _parseErrorResponse(statusCode, responseData, requestId);
    }

    // Fallback for unknown error format
    return _createGenericError(statusCode, error.message, requestId);
  }

  /// Parse error response based on API provider format
  static ApiException _parseErrorResponse(
    int statusCode,
    Map<String, dynamic> data,
    String? requestId,
  ) {
    String message = 'Unknown error';
    String? errorType;
    String? errorCode;
    int? retryAfter;

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

    // Extract retry-after header for rate limiting
    if (statusCode == 429 && data.containsKey('retry_after')) {
      retryAfter = data['retry_after'] as int?;
    }

    return _createSpecificError(
      statusCode: statusCode,
      message: message,
      errorType: errorType,
      errorCode: errorCode,
      requestId: requestId,
      retryAfter: retryAfter,
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
        return TimeoutException(
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
      DioException error, ApiException baseError) {
    final responseData = error.response?.data;
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
      DioException error, ApiException baseError) {
    final responseData = error.response?.data;
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
      DioException error, ApiException baseError) {
    // Grok uses OpenAI-compatible format
    return baseError;
  }
}

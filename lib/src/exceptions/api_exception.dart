//
//  gitwhisper
//  api_exception.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

/// Base class for all API-related exceptions
abstract class ApiException implements Exception {
  const ApiException({
    required this.message,
    required this.statusCode,
    this.errorType,
    this.errorCode,
    this.requestId,
    this.retryAfter,
  });

  /// Human-readable error message
  final String message;

  /// HTTP status code
  final int statusCode;

  /// API-specific error type (e.g., 'invalid_request_error', 'rate_limit_error')
  final String? errorType;

  /// API-specific error code
  final String? errorCode;

  /// Request ID for debugging (if available)
  final String? requestId;

  /// Retry after duration in seconds (for rate limiting)
  final int? retryAfter;

  /// Whether this error is retryable
  bool get isRetryable => statusCode >= 500 || statusCode == 429;

  /// Whether this error is due to rate limiting
  bool get isRateLimited => statusCode == 429;

  /// Whether this error is due to authentication issues
  bool get isAuthenticationError => statusCode == 401;

  /// Whether this error is due to permission issues
  bool get isPermissionError => statusCode == 403;

  /// Whether this error is due to invalid request
  bool get isInvalidRequest => statusCode == 400;

  /// Whether this error is due to server issues
  bool get isServerError => statusCode >= 500;

  /// Get a user-friendly error message with recovery suggestions
  String get userFriendlyMessage {
    switch (statusCode) {
      case 400:
        return 'Invalid request: $message\n'
            'Please check your request parameters and try again.';
      case 401:
        return 'Authentication failed: $message\n'
            'Please check your API key and ensure it\'s valid.';
      case 403:
        return 'Permission denied: $message\n'
            'Please check your API key permissions or account status.';
      case 404:
        return 'Resource not found: $message\n'
            'Please check the model name or endpoint URL.';
      case 413:
        return 'Request too large: $message\n'
            'Please reduce the size of your request (shorter diff or prompt).';
      case 429:
        final retryMsg = retryAfter != null
            ? ' Please wait $retryAfter seconds before retrying.'
            : ' Please wait before retrying.';
        return 'Rate limit exceeded: $message$retryMsg';
      case 500:
        return 'Server error: $message\n'
            'This is a temporary issue. Please try again later.';
      case 503:
        return 'Service unavailable: $message\n'
            'The service is temporarily down. Please try again later.';
      case 529:
        return 'Service overloaded: $message\n'
            'The service is experiencing high traffic. Please try again later.';
      default:
        return 'API error ($statusCode): $message';
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer('${runtimeType}: $message');

    if (statusCode != 0) {
      buffer.write(' (HTTP $statusCode)');
    }

    if (errorType != null) {
      buffer.write(' [Type: $errorType]');
    }

    if (errorCode != null) {
      buffer.write(' [Code: $errorCode]');
    }

    if (requestId != null) {
      buffer.write(' [Request ID: $requestId]');
    }

    return buffer.toString();
  }
}

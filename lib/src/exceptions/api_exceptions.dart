//
//  gitwhisper
//  api_exceptions.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'api_exception.dart';

/// Exception for authentication-related errors (401)
class AuthenticationException extends ApiException {
  const AuthenticationException({
    required super.message,
    super.statusCode = 401,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Authentication failed: $message\n'
      'Solutions:\n'
      '• Check that your API key is correct and valid\n'
      '• Ensure your API key has not expired\n'
      '• Verify you\'re using the correct API key for this service\n'
      '• Make sure your API key is properly formatted (no extra spaces)';
}

/// Exception for permission-related errors (403)
class PermissionException extends ApiException {
  const PermissionException({
    required super.message,
    super.statusCode = 403,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Permission denied: $message\n'
      'Solutions:\n'
      '• Check your API key permissions\n'
      '• Ensure your account has access to this model\n'
      '• Verify your account is in good standing\n'
      '• Check if billing is enabled for your account';
}

/// Exception for rate limiting errors (429)
class RateLimitException extends ApiException {
  const RateLimitException({
    required super.message,
    super.statusCode = 429,
    super.errorType,
    super.errorCode,
    super.requestId,
    super.retryAfter,
  });

  @override
  String get userFriendlyMessage {
    final retryMsg = retryAfter != null
        ? 'Please wait $retryAfter seconds before retrying.'
        : 'Please wait before retrying.';

    return 'Rate limit exceeded: $message\n'
        'Solutions:\n'
        '• Reduce the frequency of your requests\n'
        '• Implement exponential backoff in your retry logic\n'
        '• Consider upgrading your API plan for higher limits\n'
        '• $retryMsg';
  }
}

/// Exception for invalid request errors (400, 422)
class InvalidRequestException extends ApiException {
  const InvalidRequestException({
    required super.message,
    super.statusCode = 400,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Invalid request: $message\n'
      'Solutions:\n'
      '• Check your request parameters\n'
      '• Ensure the model name is correct\n'
      '• Verify the request format matches the API specification\n'
      '• Check that all required fields are provided';
}

/// Exception for resource not found errors (404)
class ResourceNotFoundException extends ApiException {
  const ResourceNotFoundException({
    required super.message,
    super.statusCode = 404,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Resource not found: $message\n'
      'Solutions:\n'
      '• Check the model name is correct\n'
      '• Verify the API endpoint URL\n'
      '• Ensure the resource exists and is accessible\n'
      '• Check your API version';
}

/// Exception for request too large errors (413)
class RequestTooLargeException extends ApiException {
  const RequestTooLargeException({
    required super.message,
    super.statusCode = 413,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Request too large: $message\n'
      'Solutions:\n'
      '• Reduce the size of your git diff\n'
      '• Break large changes into smaller commits\n'
      '• Exclude unnecessary files from your git diff\n'
      '• Use a model with a larger context window';
}

/// Exception for server errors (500, 502, 503)
class ServerException extends ApiException {
  const ServerException({
    required super.message,
    required super.statusCode,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Server error: $message\n'
      'This is a temporary issue on the service provider\'s side.\n'
      'Solutions:\n'
      '• Wait a few minutes and try again\n'
      '• Check the service status page\n'
      '• Try using a different model if available\n'
      '• Contact support if the issue persists';
}

/// Exception for service overload errors (529)
class ServiceOverloadedException extends ApiException {
  const ServiceOverloadedException({
    required super.message,
    super.statusCode = 529,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Service overloaded: $message\n'
      'The service is experiencing high traffic.\n'
      'Solutions:\n'
      '• Wait a few minutes and try again\n'
      '• Try during off-peak hours\n'
      '• Use exponential backoff for retries\n'
      '• Consider switching to a different model temporarily';
}

/// Exception for insufficient balance/credits (402)
class InsufficientBalanceException extends ApiException {
  const InsufficientBalanceException({
    required super.message,
    super.statusCode = 402,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Insufficient balance: $message\n'
      'Solutions:\n'
      '• Add funds to your account\n'
      '• Check your billing information\n'
      '• Verify your payment method\n'
      '• Review your usage limits';
}

/// Exception for timeout errors
class TimeoutException extends ApiException {
  const TimeoutException({
    required super.message,
    super.statusCode = 504,
    super.errorType,
    super.errorCode,
    super.requestId,
  });

  @override
  String get userFriendlyMessage => 'Request timeout: $message\n'
      'Solutions:\n'
      '• Reduce the size of your request\n'
      '• Try again with a shorter prompt\n'
      '• Use a faster model if available\n'
      '• Check your network connection';
}

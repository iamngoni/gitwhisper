//
//  gitwhisper
//  error_handler.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import '../acp/acp_client.dart';
import '../constants.dart';
import '../user_home.dart';
import 'api_exception.dart';
import 'api_exceptions.dart';

/// Utility class for handling errors in commands
class ErrorHandler {
  /// Handle API errors with appropriate user feedback
  static void handleApiError(ApiException error, {String? context}) {
    $logger.err('API Error: $error');

    // Display user-friendly error message
    final contextMsg = context != null ? ' while $context' : '';
    $logger
      ..err('Error$contextMsg:')
      ..err(error.userFriendlyMessage);

    // Show additional debugging info if available
    if (error.requestId != null) {
      $logger.detail('Request ID: ${error.requestId}');
    }
  }

  /// Handle general exceptions
  static void handleGeneralError(Object error, {String? context}) {
    if (error is AcpException) {
      final contextMsg = context != null ? ' while $context' : '';
      $logger
        ..err('ACP agent error$contextMsg:')
        ..err(error.message);
      return;
    }

    if (error is UserHomeException) {
      $logger.err(error.message);
      return;
    }

    $logger.err('General Error: $error');

    // Display user-friendly error message
    final contextMsg = context != null ? ' while $context' : '';
    $logger
      ..err('An unexpected error occurred$contextMsg:')
      ..err(error.toString());
  }

  /// Handle errors with retry suggestions
  static void handleErrorWithRetry(
    ApiException error, {
    String? context,
    bool showRetryInfo = true,
  }) {
    handleApiError(error, context: context);

    if (showRetryInfo) {
      if (error.isRetryable) {
        $logger
          ..info('')
          ..info('This error is retryable. You can:')
          ..info('• Try running the command again');

        if (error.isRateLimited && error.retryAfter != null) {
          $logger.info('• Wait ${error.retryAfter} seconds before retrying');
        } else if (error.isRateLimited) {
          $logger.info('• Wait a few minutes before retrying');
        } else if (error.isServerError) {
          $logger.info('• Wait a few minutes and try again');
        }
      } else {
        $logger
          ..info('')
          ..info('This error requires your attention before retrying.');
      }
    }
  }

  /// Handle errors with fallback options
  static void handleErrorWithFallback(
    ApiException error, {
    String? context,
    List<String>? fallbackOptions,
  }) {
    handleApiError(error, context: context);

    if (fallbackOptions != null && fallbackOptions.isNotEmpty) {
      $logger
        ..info('')
        ..info('You can try these alternatives:');
      for (final option in fallbackOptions) {
        $logger.info('• $option');
      }
    }
  }

  /// Get a short error summary for display
  static String getErrorSummary(ApiException error) {
    return switch (error) {
      AuthenticationException() => 'Authentication failed - check your API key',
      PermissionException() => 'Permission denied - check your account access',
      RateLimitException() =>
        'Rate limit exceeded - please wait before retrying',
      InvalidRequestException() => 'Invalid request - check your parameters',
      ResourceNotFoundException() =>
        'Resource not found - check your configuration',
      RequestTooLargeException() =>
        'Request too large - reduce the size of your changes',
      ServerException() => 'Server error - temporary issue, please try again',
      ServiceOverloadedException() =>
        'Service overloaded - please try again later',
      InsufficientBalanceException() =>
        'Insufficient balance - add funds to your account',
      ApiTimeoutException() =>
        'Request timeout - reduce request size or try again',
      ResponseTruncatedException() =>
        'Response truncated - the model hit its output token limit',
      InvalidResponseException() =>
        'Unexpected response - try again or use another model',
      ProviderRetiredException() =>
        'Provider retired - switch to another provider',
      _ => 'API error occurred',
    };
  }

  /// Check if an error suggests switching to a different model
  static bool shouldSuggestModelSwitch(ApiException error) {
    return error.isServerError ||
        error is ServiceOverloadedException ||
        error is RequestTooLargeException ||
        error is ApiTimeoutException;
  }

  /// Get model switch suggestions based on error type
  static List<String> getModelSwitchSuggestions(ApiException error) {
    final suggestions = <String>[];

    if (error is ServiceOverloadedException || error.isServerError) {
      suggestions
        ..add('Try switching to a different AI provider temporarily')
        ..add('Use a different model variant if available');
    }

    if (error is RequestTooLargeException || error is ApiTimeoutException) {
      suggestions
        ..add('Switch to a model with a larger context window')
        ..add('Use a faster model for quicker processing');
    }

    return suggestions;
  }

  /// Format error for logging
  static String formatErrorForLogging(Exception error, {String? context}) {
    final buffer = StringBuffer();

    if (context != null) {
      buffer.writeln('Context: $context');
    }

    buffer
      ..writeln('Error Type: ${error.runtimeType}')
      ..writeln('Error Message: $error');

    if (error is ApiException) {
      buffer.writeln('Status Code: ${error.statusCode}');
      if (error.errorType != null) {
        buffer.writeln('Error Type: ${error.errorType}');
      }
      if (error.errorCode != null) {
        buffer.writeln('Error Code: ${error.errorCode}');
      }
      if (error.requestId != null) {
        buffer.writeln('Request ID: ${error.requestId}');
      }
    }

    return buffer.toString();
  }
}

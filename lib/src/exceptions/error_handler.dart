//
//  gitwhisper
//  error_handler.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import '../constants.dart';
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
  static void handleGeneralError(Exception error, {String? context}) {
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
    switch (error.runtimeType) {
      case AuthenticationException:
        return 'Authentication failed - check your API key';
      case PermissionException:
        return 'Permission denied - check your account access';
      case RateLimitException:
        return 'Rate limit exceeded - please wait before retrying';
      case InvalidRequestException:
        return 'Invalid request - check your parameters';
      case ResourceNotFoundException:
        return 'Resource not found - check your configuration';
      case RequestTooLargeException:
        return 'Request too large - reduce the size of your changes';
      case ServerException:
        return 'Server error - temporary issue, please try again';
      case ServiceOverloadedException:
        return 'Service overloaded - please try again later';
      case InsufficientBalanceException:
        return 'Insufficient balance - add funds to your account';
      case TimeoutException:
        return 'Request timeout - reduce request size or try again';
      default:
        return 'API error occurred';
    }
  }

  /// Check if an error suggests switching to a different model
  static bool shouldSuggestModelSwitch(ApiException error) {
    return error.isServerError ||
        error is ServiceOverloadedException ||
        error is RequestTooLargeException ||
        error is TimeoutException;
  }

  /// Get model switch suggestions based on error type
  static List<String> getModelSwitchSuggestions(ApiException error) {
    final suggestions = <String>[];

    if (error is ServiceOverloadedException || error.isServerError) {
      suggestions
        ..add('Try switching to a different AI provider temporarily')
        ..add('Use a different model variant if available');
    }

    if (error is RequestTooLargeException || error is TimeoutException) {
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

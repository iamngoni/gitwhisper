//
//  gitwhisper
//  commit_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:async';

import '../exceptions/api_exceptions.dart';
import 'language.dart';

/// Text from one provider request, and whether the provider cut it off at
/// the output token limit.
typedef GeneratedText = ({String text, bool truncated});

/// Abstract base class for AI commit message generators
abstract class CommitGenerator {
  const CommitGenerator(this.apiKey, {this.variant});
  final String? apiKey;
  final String? variant;

  /// Generate a commit message based on the git diff
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  });

  /// Generate an analysis of the provided diff for what's changed and possibly
  /// what can be made better
  Future<String> analyzeChanges(
    String diff,
    Language language,
  );

  /// Returns the name of the model
  String get modelName;

  /// Returns the default variant to use if none specified
  String get defaultVariant;

  /// Gets the actual variant to use (specified or default)
  String get actualVariant =>
      (variant != null && variant!.isNotEmpty) ? variant! : defaultVariant;

  /// The maximum number of tokens allowed for the commit message generation.
  ///
  /// Reasoning models count hidden reasoning against this limit, so it leaves
  /// room well beyond the short visible message. The prompt, not this limit,
  /// keeps commit messages concise.
  int get maxTokens => 2048;

  /// The maximum number of tokens allowed for the analysis message generation.
  int get maxAnalysisTokens => 8000;

  /// The output token limit for one retry after a commit message is cut off
  /// at [maxTokens].
  int get truncationRetryMaxTokens => 8192;

  /// The output token limit for each agent-mode request.
  int get agentTurnMaxTokens => 4096;

  /// Runs [request] with [maxTokens] and returns the commit message.
  ///
  /// If the provider cuts the message off, retries once with
  /// [truncationRetryMaxTokens]. Throws [ResponseTruncatedException] if the
  /// retry is cut off too, and [InvalidResponseException] if no text comes
  /// back. [provider] names the provider in error messages.
  Future<String> requestCommitMessage(
    String provider,
    Future<GeneratedText> Function(int maxTokens) request,
  ) async {
    var limit = maxTokens;
    var result = await request(limit);
    if (result.truncated) {
      limit = truncationRetryMaxTokens;
      result = await request(limit);
    }

    if (result.truncated) {
      throw ResponseTruncatedException(
        message: '$provider stopped at the $limit-token output limit before '
            'finishing the commit message.',
      );
    }

    final text = result.text.trim();
    if (text.isEmpty) {
      throw InvalidResponseException(
        message: '$provider returned an empty commit message.',
      );
    }
    return text;
  }

  /// Runs [request] with [maxAnalysisTokens] and returns the analysis.
  ///
  /// An analysis cut off at the limit is still returned, with a note saying
  /// so. Throws [InvalidResponseException] if no text comes back.
  Future<String> requestAnalysis(
    String provider,
    Future<GeneratedText> Function(int maxTokens) request,
  ) async {
    final result = await request(maxAnalysisTokens);
    final text = result.text.trim();

    if (text.isEmpty) {
      if (result.truncated) {
        throw ResponseTruncatedException(
          message: '$provider used the whole $maxAnalysisTokens-token output '
              'limit without writing an analysis.',
        );
      }
      throw InvalidResponseException(
        message: '$provider returned an empty analysis.',
      );
    }

    if (!result.truncated) return text;
    return '$text\n\n[Analysis truncated: $provider reached the '
        '$maxAnalysisTokens-token output limit.]';
  }
}

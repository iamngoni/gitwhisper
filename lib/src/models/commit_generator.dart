//
//  gitwhisper
//  commit_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:async';

/// Abstract base class for AI commit message generators
abstract class CommitGenerator {
  const CommitGenerator(this.apiKey, {this.variant});
  final String apiKey;
  final String? variant;

  /// Generate a commit message based on the git diff
  Future<String> generateCommitMessage(String diff, {String? prefix});

  /// Generate an analysis of the provided diff for what's changed and possibly
  /// what can be made better
  Future<String> analyzeChanges(String diff);

  /// Returns the name of the model
  String get modelName;

  /// Returns the default variant to use if none specified
  String get defaultVariant;

  /// Gets the actual variant to use (specified or default)
  String get actualVariant =>
      (variant != null && variant!.isNotEmpty) ? variant! : defaultVariant;

  /// The maximum number of tokens allowed for the commit message generation.
  ///
  /// This limits the size of the generated commit message to ensure it remains
  /// concise and follows best practices for Git commit messages.
  /// A lower value encourages more focused, single-purpose commit messages.
  int get maxTokens => 300;

  /// The maximum number of tokens allowed for the analysis message generation.
  int get maxAnalysisTokens => 8000;
}

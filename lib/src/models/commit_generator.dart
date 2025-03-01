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
  Future<String> generateCommitMessage(String diff);

  /// Returns the name of the model
  String get modelName;

  /// Returns the default variant to use if none specified
  String get defaultVariant;

  /// Gets the actual variant to use (specified or default)
  String get actualVariant =>
      (variant != null && variant!.isNotEmpty) ? variant! : defaultVariant;
}

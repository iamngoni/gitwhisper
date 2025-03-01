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
  const CommitGenerator(this.apiKey);
  final String apiKey;

  /// Generate a commit message based on the git diff
  Future<String> generateCommitMessage(String diff);

  /// Returns the name of the model
  String get modelName;
}

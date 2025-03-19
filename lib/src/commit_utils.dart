//
//  gitwhisper
//  commit_utils.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/19.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

/// Generates a prompt for creating a git commit message based on staged changes.
///
/// Takes the [diff] of staged changes and inserts it into a template prompt
/// that instructs an AI assistant to generate a conventional commit message.
///
/// Returns a formatted prompt string ready to be sent to an AI assistant.
String getCommitPrompt(String diff) {
  final prompt = '''
  You are an assistant that generates git commit messages. 
  Based on the following diff of staged changes, generate a concise and descriptive commit message.
  Follow the conventional commit format: <type>: <description>
  
  Common types: feat, fix, docs, style, refactor, test, chore
  
  Include relevant emojis e.g. 🐛 for fixes, ✨ for features
  
  Here's the diff:
  $diff
  
  Generate only the commit message, nothing else.
  ''';

  return prompt;
}
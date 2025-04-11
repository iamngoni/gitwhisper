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
    Based on the following diff of staged changes, generate concise and descriptive commit messages.
    
    For the commit message format, use:
    <type>: <emoji> <description>
    
    [optional body with more details]
    
    [optional footer with breaking changes or issue references]
    
    Commit types with their required emojis:
    - feat: ✨ (new feature)
    - fix: 🐛 (bug fix)
    - docs: 📚 (documentation changes)
    - style: 💄 (formatting, missing semi colons, etc; no code change)
    - refactor: ♻️ (code change that neither fixes a bug nor adds a feature)
    - test: 🧪 (adding or modifying tests)
    - chore: 🔧 (updating build tasks, package manager configs, etc)
    - perf: ⚡ (performance improvements)
    - ci: 👷 (CI/CD related changes)
    - build: 📦 (changes affecting build system or dependencies)
    - revert: ⏪ (reverting a previous commit)
    
    Pay special attention to file patterns that indicate related changes:
    - When changes to configuration files (like pubspec.yaml, package.json) are accompanied by implementation 
      files, focus on the overall feature being implemented rather than the config changes.
    - For database schema changes with corresponding model updates, group them together.
    - When API endpoint implementations are added along with their tests, consider the purpose rather than 
      treating them as separate feat/test changes.
    
    For large diffs, prioritize the most significant changes to determine the commit type and message,
    rather than getting distracted by minor changes (like formatting or comments).
    
    For complex changes, include a brief explanatory body after a blank line following the commit header.
    
    Only generate multiple commit lines when changes are truly unrelated to each other:
    <type>: <emoji> <description>
    <type>: <emoji> <description>
    
    Example of a commit with body:
    feat: ✨ Add user preferences with local storage
    
    Implement SharedPreferences to store user theme and notification settings.
    Configuration persists across app restarts.
    
    Example of multiple unrelated changes:
    feat: ✨ Add dark mode toggle
    fix: 🐛 Fix login validation error
    
    Here's the diff:
    $diff
    
    Keep descriptions concise but informative (under 50 characters if possible).
    Use imperative mood for descriptions ("Add feature" not "Added feature").
    
    Generate only the commit message(s), nothing else.
''';

  return prompt;
}

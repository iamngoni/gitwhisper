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
    Follow the conventional commit format: <type>: <emoji> <description>
    
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
    
    If there are multiple unrelated changes, generate multiple commit lines like this:
    <type>: <emoji> <description>
    <type>: <emoji> <description>
    <type>: <emoji> <description>
    
    Example:
    feat: ✨ Add user authentication
    fix: 🐛 Fix crash on profile update
    refactor: ♻️ Improve validation logic
    
    Here's the diff:
    $diff
    
    Generate only the commit message(s), nothing else.
''';

  return prompt;
}

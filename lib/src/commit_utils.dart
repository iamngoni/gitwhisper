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
String getCommitPrompt(String diff, {String? prefix}) {
  final hasPrefix = prefix != null && prefix.isNotEmpty;
  final prefixNote = hasPrefix
      ? '''
If a prefix like "$prefix" is provided, format it like this:

- For a **single commit message**:
  fix: 🐛 $prefix -> Fix login validation, handle empty input

- For **multiple unrelated messages**:
  **$prefix**
  feat: ✨ -> Add dark mode toggle, persist setting
  fix: 🐛 -> Fix login bug, validate inputs
'''
      : '';

  final prompt = '''
You are an assistant that generates commit messages.

You must return only one-liner commit messages. Each message must follow this strict format:
<type>: <emoji> <description[, additional brief context]>

Where:
- <type> is a valid conventional type
- <emoji> is the matching emoji
- <description> is in imperative mood ("Fix bug", not "Fixed bug")
- Optional context (e.g., small body) must be **on the same line**, comma-separated after the description

Do NOT include:
- Blank lines
- Multiline messages
- Commit bodies or footers below the header
- Summaries, intros, or explanations

$prefixNote

### Commit types and emojis:
- feat: ✨ New feature
- fix: 🐛 Bug fix
- docs: 📚 Documentation
- style: 💄 Code formatting only
- refactor: ♻️ Code improvements
- test: 🧪 Tests
- chore: 🔧 Tooling/maintenance
- perf: ⚡ Performance improvements
- ci: 👷 CI/CD
- build: 📦 Build system/dependencies
- revert: ⏪ Reverting a commit

⚠️ Output must only be properly formatted commit message(s). Nothing else.

Here’s the diff:
$diff
''';

  return prompt;
}

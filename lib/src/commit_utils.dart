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
When generating the commit message(s), apply the prefix **$prefix** as follows:

- If there is **only one** commit message, include the prefix after the emoji in the header:
  Example: fix: 🐛 $prefix -> Fix login error

- If there are **multiple** unrelated commit messages, start the output with the prefix in bold on its own line:
  **$prefix**
  feat: ✨ -> Add dark mode toggle
  fix: 🐛 -> Fix login validation
'''
      : '';

  final prompt = '''
You are an assistant that generates git commit messages.

Based on the following diff of staged changes, generate valid, concise, and conventional commit messages using this format:
<type>: <emoji> <description>

[optional body — separated by a blank line]

[optional footer — e.g., BREAKING CHANGE, issue references]

Commit types with their required emojis:
- feat: ✨ new feature
- fix: 🐛 bug fix
- docs: 📚 documentation changes
- style: 💄 formatting changes (no logic changes)
- refactor: ♻️ code improvements
- test: 🧪 test additions/changes
- chore: 🔧 tooling or maintenance
- perf: ⚡ performance enhancements
- ci: 👷 CI/CD changes
- build: 📦 build/dependency updates
- revert: ⏪ revert changes

$prefixNote

⚠️ Output requirements:
- ONLY return the commit message(s), no explanations, no intro text, no summaries, no closing lines
- Do NOT include phrases like "Here are the messages", "Based on the diff", etc.
- Messages should be valid to pass directly as commit messages
- Use imperative mood ("Add feature", not "Added feature")
- Keep descriptions concise (preferably under 50 characters)
- Only generate multiple commit messages if changes are truly unrelated

Here’s the diff:
$diff
''';

  return prompt;
}

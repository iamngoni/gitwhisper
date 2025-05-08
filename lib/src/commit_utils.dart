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
If a prefix is provided, format it like this:

- For a **single commit message**:
  fix: 🐛 **PREFIX** -> Fix login validation, handle empty input

- For **multiple unrelated messages**:
  **PREFIX**
  feat: ✨ Add dark mode toggle, persist setting
  fix: 🐛 Fix login bug, validate inputs

  Here's the commit prefix: $prefix
'''
      : '';

  final prompt = '''
You are an assistant that generates commit messages.

Based on the following diff of staged changes, generate valid, concise, and conventional commit messages. Each message must follow this strict format:
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

MANDATORY FORMAT RULES:
1. IMPERATIVE VERB: Always use "Add", "Fix", "Update", etc. (NOT "Added", "Fixed", "Updated")
2. CAPITALIZE: First word must be capitalized
3. CONCISE: Keep descriptions concise (preferably under 50 characters)
4. TYPES AND EMOJIS: Must use ONLY from the approved list below
5. Only generate multiple commit messages if changes are truly unrelated

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

⚠️ Output must only be properly formatted commit message(s). Nothing else. Violation is not acceptable

Here’s the diff:
$diff
''';

  return prompt;
}

String getAnalysisPrompt(String diff) {
  final prompt = '''
# Code Change Analyzer

You are a specialized code review assistant focused on analyzing git diffs and providing terminal-friendly feedback.

## Your task:

Analyze the provided diff and deliver a clear, structured analysis that includes:

1. **Overview Summary**
   - Brief description of what changes were made
   - The apparent purpose of these changes
   - Files affected and their roles

2. **Technical Analysis**
   - Identify the key functional changes
   - Note any architectural or structural modifications
   - Highlight important API changes or dependency updates

3. **Code Quality Assessment**
   - Evaluate the quality of implemented changes
   - Identify any code smells or potential issues
   - Suggest better patterns or approaches where applicable

4. **Optimization Opportunities**
   - Point out any performance concerns
   - Suggest more efficient alternatives
   - Identify opportunities for code reuse or abstraction

5. **Security & Edge Cases**
   - Highlight potential security vulnerabilities
   - Note any missing input validation or error handling
   - Identify edge cases that might not be handled

## IMPORTANT: Ignore trivial changes

- IGNORE whitespace-only changes (indentation, line breaks, spacing)
- IGNORE code formatting changes that don't affect functionality
- IGNORE simple line shifts without actual content changes
- IGNORE comment-only changes unless they are substantial or important
- Focus ONLY on changes that affect functionality, logic, architecture, or security

## Terminal-Friendly Format:

Format your analysis for optimal display in a terminal environment:

1. Use simple terminal-friendly formatting:
   - Separate sections with clear dividers (e.g., "-------------")
   - Use symbols (*, >, +, -) instead of markdown bullets
   - Highlight important points with uppercase or symbols (⚠️, ✅, ⚡)
   - Keep line width to 80-100 characters maximum

2. Use simple text highlighting:
   - Make headers UPPERCASE or use symbols like "==" for emphasis
   - Use plain ASCII characters for emphasis (*, _, |)
   - Maintain consistent indentation for readability

3. Structure for scannability:
   - Start with a 2-3 line executive summary
   - Use short paragraphs (3-5 lines maximum)
   - Use lists for multiple related points
   - Include line numbers in [brackets] when referencing specific code

Keep your analysis balanced - highlight both positive aspects and areas for improvement. Prioritize the most important findings over trivial issues.

## Diff to analyze:

$diff
''';

  return prompt;
}

## 0.1.19
- Made `gw update` detect Dart pub, Homebrew, APT, and manual installs, with `gw update --check` to preview the update path.
- Sanitized noisy agent responses so only valid conventional commit lines are used as commit messages.

## 0.1.18
- Formatted tool use events

## 0.1.17
- Expanded agent mode with richer read-only tools for large staged changes, including diff hunks, content chunks, search, deterministic file summaries, related files, and blame.

## 0.1.16
- Added local CLI providers for Codex (`--model codex`) and Claude Code (`--model claude-code`), using the user's installed and authenticated CLIs instead of GitWhisper API keys.
- Added `gw commit --agent` for OpenAI and Claude, letting models inspect staged changes through read-only GitWhisper tools instead of receiving the whole diff at once.

## 0.1.15
- switched openai models to make use of `max_completion_tokens` instead of the deprecated `max_tokens` param

## 0.1.14
- Automatically detects files >10MB before committing to prevent accidentally adding large files to git history.
- When diff exceeds max size, automatically processes file-by-file without prompting (revert previously added behaviour)

## 0.1.13
- **Configurable max diff size** - New `--max-diff-size` option in `set-defaults` to customize the threshold (in characters) before prompting for interactive staging (default: 50,000)
- **New command** - `gw show-config` displays your full configuration file in a formatted view
- **Improved large diff handling** - Large diffs now trigger an interactive prompt with options to use focused staging, commit everything, or cancel

## 0.1.12
- **Free Model (No API Key Required!)** - New `free` model option powered by LLM7.io. Use GitWhisper without any API key setup: `gw commit --model free`
- **Git Tagging Support** - New `--tag` / `-t` flag to create a git tag alongside your commit (e.g., `gw commit -t v1.0.0`)
- **Auto-push Tags** - When using `--auto-push` with `--tag`, both the commit and tag are pushed to the remote
- **Improved Ticket Prefix** - Fixed ticket prefix formatting to correctly include the prefix in generated commit messages (e.g., `JIRA-123 -> fix: 🐛 Fix bug`)

## 0.1.11
- Build for ARM64

## 0.1.10
- **Git Editor Integration** - Edit commit messages in your preferred Git editor (vim, nano, VS Code, etc.) instead of inline prompt
- **Improved Edit Workflow** - After editing, the commit message returns to the confirmation menu for review instead of auto-committing
- **Better UX** - Respects Git's editor configuration hierarchy: `GIT_EDITOR` → `$EDITOR` → `vi` as fallback

## 0.1.9
- **Emoji Control** - New `--allow-emojis` / `--no-allow-emojis` flag to control emoji inclusion in commit messages (defaults to enabled)
- **Updated Model Variants** - Refreshed all AI model variants with latest releases:
  - OpenAI: Added GPT-5 family (gpt-5, gpt-5-mini, gpt-5-nano, gpt-5-pro), GPT-4.1 family, and gpt-realtime models
  - Claude: Added claude-sonnet-4-5-20250929 and claude-opus-4-1-20250805
  - Gemini: Updated to Gemini 2.5 family (gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite, gemini-2.5-flash-image, gemini-2.5-computer-use)
  - Grok: Added grok-4, grok-4-heavy, grok-4-fast, and grok-code-fast-1
  - DeepSeek: Added deepseek-v3.2-exp, deepseek-v3.1, deepseek-r1-0528, and more
- **Build Improvements** - Added dynamic version injection via yq in build workflow
- **Code Documentation** - Added comprehensive method documentation for commit prompt utilities

## 0.1.2
- **Interactive Commit Confirmation** - Review, edit, retry with different models, or discard AI-generated messages
- **Enhanced User Experience** - All commands now use interactive prompts with smart defaults and guided workflows
- **Multi-repo Support** - Confirmation workflow works across single and multiple repositories
- **Improved Security** - Hidden input for API keys and better Ollama handling

## 0.0.59
- feat: ✨ Add language support to commit and analysis generation

## 0.0.58
- chore: 🔧 Update documentation

## 0.0.57
- Make gitwhisper available on all platforms through various installation channels

## 0.0.53
- fix: 🐛 Fix API key to be optional

## 0.0.52
- fix: 🐛 API key issue with Ollama

## 0.0.51
- feat: ✨ Add Ollama support

## 0.0.50
- feat: ✨ Make gitwhisper installable through Homebrew

## 0.0.49
- fix: 🐛 Add Windows compatibility for file permissions

## 0.0.48
- feat: ✨ Update Claude model variants and default version

## 0.0.47
- enhancements

## 0.0.46
- fix: 🐛 Update success message, support singular repo

## 0.0.45
- feat: ✨ Add folderPath to GitUtils.runGitCommit

## 0.0.44
- fix: 🐛 Fix Git add, pass workingDirectory

## 0.0.43
- fix: 🐛 Pass folderPath to git diff command

## 0.0.42
- fix: 🐛 multi repo options

## 0.0.41
- feat: ✨ Implement analysis on multiple git repos
- feat: ✨ Implement commit command in subfolders
- refactor: ♻️ Improve git utils with subfolder support

## 0.0.40
- fix: 🐛 remove argOptions

## 0.0.39
- fix: 🐛 remove always add abbreviation

## 0.0.38
- fix: 🐛 Handle null home directory, throw exception if null
- feat: ✨ Add always-add command to allow you to skip running `git add` manually
- feat: ✨ Stage all unstaged files if configured

## 0.0.37
- refactor: ♻️ Simplify git push confirmation logic

## 0.0.36
- fix: 🐛 Handle missing remote URL during push

## 0.0.35
- feat: ✨ Add auto-push support (by [Takudzwa Nyanhanga](https://github.com/abcdOfficialzw))

## 0.0.34
- fix: remove markdown changes

## 0.0.33
- render markdown properly

## 0.0.32
- feat: ✨ Update Gemini model variants and API integration, dynamic endpoint support

## 0.0.31
- increase max output tokens for analysis

## 0.0.30
- lower mason_logger dependency version

## 0.0.29
- feat: ✨ Add analyze command for detailed code change analysis


## 0.0.28
- refactor: ♻️ Update commit message generation prompt

## 0.0.27
- feat: ✨ Add mandatory format rules for commit messages

## 0.0.26
- refactor: 🔧 Remove debug print statement, bump version to 0.0.26

## 0.0.25
- fix: make AI aware of the prefix

## 0.0.24
- chore: update release notes url

## 0.0.23
- fix: formatting issue (regression)

## 0.0.22
- refactor: ♻️ Remove manual commit message prefix formatting logic
- feat: ✨ Add prefix support to AI commit message generation
- docs: 📚 Update commit prompt with prefix instructions


## 0.0.21
- docs: 📚 Update commit message guide with format details

## 0.0.20
- refactor: ♻️ Enhance prompt formatting for commit message generation

## 0.0.16
- docs: 📝 update commit message guidelines to include emojis

## 0.0.15
- chore: 🧹 remove unused process_run dependency from pubspec.yaml

## 0.0.14
- docs: expand commit types with mandatory emojis in prompt

## 0.0.13
- feat: extract commit prompt to shared utility module

## 0.0.12+1
- Added `Deepseek-V3`, `Phi-4-mini-instruct`, `Codestral 25.01`, and `Mistral Large 24.11` to `list_variants_command`.
- Updated README with a link to check for more models on GitHub Marketplace.

## 0.0.12
- Updated README to include GitHub models and authentication instructions.
- Enhanced command options to support new 'github' model.
- Added `GithubGenerator` for generating commit messages using GitHub model.
- Updated `model_variants` with a new default variant for GitHub.

## 0.0.11
- Integrated Deepseek model into the project
- Updated model listing and validation to include Deepseek
- Added Deepseek-specific generator implementation
- Updated documentation to reflect the new model addition
- Incremented version to 0.0.11 for release with new feature

## 0.0.10
- update README with better documentation of the commands

## 0.0.9
- feat: default to 'commit' command when args are empty, add 'gw' executable alias

## 0.0.8
- fix(set_defaults_command): remove default values to enforce mandatory options

## 0.0.7
- set and clear default model and variant for future use

## 0.0.6
- resolve dart sdk constraint issue

## 0.0.5
- fix(claude_generator): update API endpoint and model selection
- refactor(dependencies): remove curl_logger_dio_interceptor and update model variants
- feat(commit): add model-variant option to commit command
- feat(list-variants): update and expand model variant lists for all models
- fix(models): use ModelVariants for default model variants across all generators

## 0.0.3
- testing configurations

## 0.0.2
- setup basic features for the tool

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

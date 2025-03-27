## 0.0.18
- feat: ✨ Add template support for customizable commit messages
- docs: 📚 Add custom templates feature and update documentation format

## 0.0.17
- fix: 🐛 improve handling of emojis in commit message formatting

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
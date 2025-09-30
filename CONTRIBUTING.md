# Contributing to GitWhisper

Thanks for contributing! We appreciate your help in making GitWhisper better.

## Getting Started

1. **Fork the repository** and clone your fork locally
2. **Create a branch** with a descriptive name:
   - `feat/brief-description` for new features
   - `fix/brief-description` for bug fixes
   - `docs/brief-description` for documentation changes
   - `refactor/brief-description` for code refactoring

## Development Setup

### Prerequisites
- Dart SDK (^3.5.0)
- Git

### Installation
```bash
# Install dependencies
dart pub get

# Activate the package locally for testing
dart pub global activate --source=path .
```

## Making Changes

1. **Write your code** following the existing code style
2. **Run tests** to ensure nothing breaks:
   ```bash
   dart test
   ```
3. **Test your changes** manually:
   ```bash
   # Test the CLI locally
   dart run bin/gitwhisper.dart commit --model <your-model>
   ```
4. **Update documentation** if you're adding new features or changing behavior

## Code Style

- Follow Dart's official style guide
- This project uses [very_good_analysis](https://pub.dev/packages/very_good_analysis) for linting
- Run analysis before committing:
  ```bash
  dart analyze
  ```

## Commit Messages

We use conventional commits with emojis (it's what GitWhisper does!):
- `feat: ✨ Add new feature`
- `fix: 🐛 Fix bug description`
- `docs: 📚 Update documentation`
- `test: 🧪 Add or update tests`
- `refactor: ♻️ Refactor code`
- `chore: 🔧 Update build or dependencies`

Use GitWhisper itself to generate your commit messages!

## Pull Request Process

1. **Open a PR** against the `master` branch
2. **Reference any related issues** in the PR description
3. **Explain what you changed and why** - help reviewers understand your changes
4. **Ensure CI passes** - all tests and checks must pass
5. **Respond to feedback** - be open to suggestions and changes

### Hacktoberfest
If your PR is for Hacktoberfest, mention `hacktoberfest` in the PR description.

## What to Contribute

We welcome contributions of all kinds:

- 🐛 **Bug fixes** - Help us squash bugs!
- ✨ **New features** - Have an idea? Let's discuss it first by opening an issue
- 📚 **Documentation** - Improvements to README, code comments, or examples
- 🧪 **Tests** - More test coverage is always appreciated
- 🌍 **Translations** - Add support for more languages
- 🤖 **Model support** - Add support for new AI models

### Areas That Need Help
- Additional test coverage
- Performance optimizations
- Better error handling and user feedback
- Support for more AI models and variants

## Guidelines

- **Keep changes focused** - Small, incremental changes are easier to review
- **One feature per PR** - Don't bundle unrelated changes together
- **Test your changes** - Ensure everything works as expected
- **Be respectful** - See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community rules

## Questions?

If you have questions or need help, feel free to:
- Open an issue for discussion
- Ask in your PR if you need guidance

Thank you for contributing to GitWhisper! 🎉
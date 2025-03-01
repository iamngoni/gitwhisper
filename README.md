## gitwhisper

![coverage][coverage_badge]
[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

Generated by the [Very Good CLI][very_good_cli_link] 🤖

---

Git Whisper is an AI-powered Git commit message generator that whispers the perfect commit message based on your staged changes.

---

## Getting Started 🚀

If the CLI application is available on [pub](https://pub.dev), activate globally via:

```sh
dart pub global activate gitwhisper
```

Or locally via:

```sh
dart pub global activate --source=path <path to this package>
```

## Features

- 🤖 Leverages various AI models to analyze your code changes and generate meaningful commit messages
- 🔄 Follows conventional commit format: `<type>(<scope>): <description>`
- 📋 Pre-fills the Git commit editor for easy review and modification
- 🔑 Securely saves API keys for future use
- 🔌 Supports multiple AI models:
    - Claude (Anthropic)
    - OpenAI (GPT)
    - Gemini (Google)
    - Grok (xAI)
    - Llama (Meta)

## Usage

```bash
# List available models
gitwhisper --list-models

# Use with a specific model and API key
gitwhisper --model openai --key "your-api-key"

# Save an API key for future use
gitwhisper --model claude --key "your-claude-key" --save-key

# Use a previously saved API key
gitwhisper --model claude

# Get help
gitwhisper --help
```

## API Keys

You can provide API keys in several ways:

1. **Command line argument**: `--key "your-api-key"`
2. **Environment variables**:
    - `ANTHROPIC_API_KEY` (for Claude)
    - `OPENAI_API_KEY` (for OpenAI)
    - `GEMINI_API_KEY` (for Gemini)
    - `GROK_API_KEY` (for Grok)
    - `LLAMA_API_KEY` (for Llama)
3. **Saved configuration**: Use `--save-key` to store your API key in `~/.git_whisper.yaml`

## How It Works

Git Whisper:
1. Checks if you have staged changes in your repository
2. Retrieves the diff of your staged changes
3. Sends the diff to the selected AI model
4. Generates a commit message following the conventional commit format
5. Pre-fills the git commit editor with the generated message
6. Opens the editor for your review and confirmation

## Configuration

Configuration is stored in `~/.git_whisper.yaml` and typically contains your saved API keys:

```yaml
api_keys:
  claude: "your-claude-key"
  openai: "your-openai-key"
  # ...
```

## Requirements

- Dart SDK (>=2.19.0 <3.0.0)
- Git installed and available in your PATH

## Conventional Commit Format

Git Whisper generates commit messages following the conventional commit format:

```
<type>(<scope>): <description>
```

Common types include:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code changes that neither fix bugs nor add features
- `test`: Adding or fixing tests
- `chore`: Changes to the build process or auxiliary tools

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

[coverage_badge]: coverage_badge.svg
[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
[very_good_cli_link]: https://github.com/VeryGoodOpenSource/very_good_cli
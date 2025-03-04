# gitwhisper

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
- 🔄 Follows conventional commit format: `<type>: <description>`
- 📋 Pre-fills the Git commit editor for easy review and modification
- 🎫 Supports ticket number prefixing for commit messages
- 🧩 Choose specific model variants (gpt-4o, claude-3-opus, etc.)
- 🔑 Securely saves API keys for future use
- 🔌 Supports multiple AI models:
    - Claude (Anthropic)
    - OpenAI (GPT)
    - Gemini (Google)
    - Grok (xAI)
    - Llama (Meta)

## Usage

```bash
# Generate a commit message (main command)
gitwhisper commit --model openai

# Choose a specific model variant
gitwhisper commit --model openai --model-variant gpt-4o

# Add a ticket number prefix to your commit message
gitwhisper commit --prefix "JIRA-123"

# List available models
gitwhisper list-models

# List available variants for a specific model
gitwhisper list-variants --model claude

# Save an API key for future use
gitwhisper save-key --model claude --key "your-claude-key"

# Get help
gitwhisper --help
```

## Command Structure

GitWhisper uses a command-based structure:

- `commit`: Generate and apply a commit message (main command)
- `list-models`: Show all supported AI models
- `list-variants`: Show available variants for each AI model
- `save-key`: Store an API key for future use
- `update`: Update GitWhisper to the latest version
- `set-defaults`: Set default model and variant for future use
- `clear-defaults`: Clear any set default preferences

## API Keys

You can provide API keys in several ways:

1. **Command line argument**: `--key "your-api-key"`
2. **Environment variables**:
    - `ANTHROPIC_API_KEY` (for Claude)
    - `OPENAI_API_KEY` (for OpenAI)
    - `GEMINI_API_KEY` (for Gemini)
    - `GROK_API_KEY` (for Grok)
    - `LLAMA_API_KEY` (for Llama)
3. **Saved configuration**: Use the `save-key` command to store your API key permanently

## Model Variants

GitWhisper supports a comprehensive range of model variants:

### OpenAI
- `gpt-4` (default)
- `gpt-4-turbo-2024-04-09`
- `gpt-4o`
- `gpt-4o-mini`
- `gpt-4.5-preview`
- `gpt-3.5-turbo-0125`
- `gpt-3.5-turbo-instruct`
- `o1-preview`
- `o1-mini`
- `o3-mini`

### Claude (Anthropic)
- `claude-3-opus-20240307` (default)
- `claude-3-sonnet-20240307`
- `claude-3-haiku-20240307`
- `claude-3-5-sonnet-20240620`
- `claude-3-5-sonnet-20241022`
- `claude-3-7-sonnet-20250219`

### Gemini (Google)
- `gemini-1.0-pro` (default)
- `gemini-1.0-ultra`
- `gemini-1.5-pro-002`
- `gemini-1.5-flash-002`
- `gemini-1.5-flash-8b`
- `gemini-2.0-pro`
- `gemini-2.0-flash`
- `gemini-2.0-flash-lite`
- `gemini-2.0-flash-thinking`

### Grok (xAI)
- `grok-1` (default)
- `grok-2`
- `grok-3`
- `grok-2-mini`

### Llama (Meta)
- `llama-3-70b-instruct` (default)
- `llama-3-8b-instruct`
- `llama-3.1-8b-instruct`
- `llama-3.1-70b-instruct`
- `llama-3.1-405b-instruct`
- `llama-3.2-1b-instruct`
- `llama-3.2-3b-instruct`
- `llama-3.3-70b-instruct`

## How It Works

Git Whisper:
1. Checks if you have staged changes in your repository
2. Retrieves the diff of your staged changes
3. Sends the diff to the selected AI model
4. Generates a commit message following the conventional commit format
5. Applies any prefix/ticket number if specified
6. Submits the commit with the generated message

## Configuration

Configuration is stored in `~/.git_whisper.yaml` and typically contains your saved API keys:

```yaml
api_keys:
  claude: "your-claude-key"
  openai: "your-openai-key"
  # ...
```

## Requirements

- Dart SDK (^3.5.0)
- Git installed and available in your PATH

## Conventional Commit Format

Git Whisper generates commit messages following the conventional commit format:

```
<type>: <description>
```

With prefix option:
```
<type>: PREFIX-123 -> <description>
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
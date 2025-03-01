//
//  gitwhisper
//  main.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:developer';
import 'dart:io';

import 'package:args/args.dart';
import 'package:gitwhisper/gitwhisper.dart';
import 'package:gitwhisper/src/config_manager.dart';
import 'package:gitwhisper/src/git_utils.dart';

void main(List<String> arguments) async {
  log('gitwhisper by iamngoni🚀');

  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addOption(
      'model',
      abbr: 'm',
      help: 'AI model to use (claude, openai, gemini, grok, llama)',
      defaultsTo: 'openai',
    )
    ..addOption('key', abbr: 'k', help: 'API key for the selected model')
    ..addFlag(
      'save-key',
      abbr: 's',
      negatable: false,
      help: 'Save the provided API key for future use',
    )
    ..addFlag(
      'list-models',
      abbr: 'l',
      negatable: false,
      help: 'List available AI models',
    )
    ..addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print the version information.',
    );

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    printUsage(parser);
    exit(1);
  }

  if (args['help'] == true) {
    printUsage(parser);
    return;
  }

  if (args['version'] == true) {
    log('git-whisper version 0.1.0');
    return;
  }

  if (args['list-models'] == true) {
    log('Available models:');
    log('  - claude (Anthropic Claude)');
    log('  - openai (OpenAI GPT models)');
    log('  - gemini (Google Gemini)');
    log('  - grok (xAI Grok)');
    log('  - llama (Meta Llama)');
    return;
  }

  // Check if we're in a git repository
  if (!await GitUtils.isGitRepository()) {
    log('Error: Not a git repository. Please run from a git repository.');
    exit(1);
  }

  // Initialize config manager
  final configManager = ConfigManager();
  await configManager.load();

  // Handle saving API key if requested
  final String modelName = args['model'] as String;
  String? apiKey = args['key'] as String?;

  if (args['save-key'] == true && apiKey != null) {
    configManager.setApiKey(modelName, apiKey);
    await configManager.save();
    log('API key for $modelName saved successfully.');
    if (!args.rest.contains('--continue')) {
      return;
    }
  }

  // Check if API key is provided or available in config
  apiKey ??=
      configManager.getApiKey(modelName) ?? _getEnvironmentApiKey(modelName);

  if (apiKey == null || apiKey.isEmpty) {
    log(
      'Error: No API key provided for $modelName. Please provide an API key'
      ' using --key.',
    );
    exit(1);
  }

  // Check if there are staged changes
  if (!await GitUtils.hasStagedChanges()) {
    log(
      'No staged changes found. Please stage your changes using `git add` first.',
    );
    exit(1);
  }

  // Get the diff of staged changes
  final diff = await GitUtils.getStagedDiff();
  if (diff.isEmpty) {
    log('No changes detected in staged files.');
    exit(1);
  }

  log('Analyzing staged changes using $modelName...');

  // Create the appropriate AI generator based on model name
  final generator = CommitGeneratorFactory.create(modelName, apiKey);

  try {
    // Generate commit message with AI
    final commitMessage = await generator.generateCommitMessage(diff);

    // Write the message to the git commit editor
    await GitUtils.setGitCommitMessage(commitMessage);

    log('Opening git commit editor with the generated message...');

    // Open the git commit editor
    await GitUtils.runGitCommit();
  } catch (e) {
    log('Error generating commit message: $e');
    exit(1);
  }
}

String? _getEnvironmentApiKey(String modelName) {
  switch (modelName.toLowerCase()) {
    case 'claude':
      return Platform.environment['ANTHROPIC_API_KEY'];
    case 'openai':
      return Platform.environment['OPENAI_API_KEY'];
    case 'gemini':
      return Platform.environment['GEMINI_API_KEY'];
    case 'grok':
      return Platform.environment['GROK_API_KEY'];
    case 'llama':
      return Platform.environment['LLAMA_API_KEY'];
    default:
      return null;
  }
}

void printUsage(ArgParser parser) {
  log('Git Whisper - Your AI companion for crafting perfect commit messages');
  log('');
  log('Usage: git-whisper [options]');
  log('');
  log(parser.usage);
}

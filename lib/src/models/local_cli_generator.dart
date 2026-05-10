//
//  gitwhisper
//  local_cli_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2026/05/10.
//  Copyright (c) 2026 Codecraft Solutions. All rights reserved.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../commit_utils.dart';
import 'commit_generator.dart';
import 'language.dart';

abstract class LocalCliGenerator extends CommitGenerator {
  const LocalCliGenerator(
    super.apiKey, {
    super.variant,
    Map<String, String>? environment,
    String? workingDirectory,
    Duration timeout = const Duration(minutes: 2),
  })  : _environment = environment,
        _workingDirectory = workingDirectory,
        _timeout = timeout;

  final Map<String, String>? _environment;
  final String? _workingDirectory;
  final Duration _timeout;

  String? get workingDirectory => _workingDirectory;

  String get executable;

  String get displayName;

  List<String> buildArguments();

  String get missingCliMessage;

  @override
  String get defaultVariant => '';

  @override
  Future<String> generateCommitMessage(
    String diff,
    Language language, {
    String? prefix,
    bool withEmoji = true,
  }) {
    final prompt = getCommitPrompt(
      diff,
      language,
      prefix: prefix,
      withEmoji: withEmoji,
    );
    return runPrompt(prompt);
  }

  @override
  Future<String> analyzeChanges(String diff, Language language) {
    return runPrompt(getAnalysisPrompt(diff, language));
  }

  Future<String> runPrompt(String prompt) async {
    final process = await _startProcess();
    final stdoutFuture = utf8.decodeStream(process.stdout);
    final stderrFuture = utf8.decodeStream(process.stderr);

    process.stdin.write(prompt);
    await process.stdin.close();

    final exitCode = await process.exitCode.timeout(
      _timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException(
          '$displayName did not finish within ${_timeout.inSeconds} seconds.',
          _timeout,
        );
      },
    );

    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;

    if (exitCode != 0) {
      throw ProcessException(
        executable,
        buildArguments(),
        stderr.trim().isEmpty
            ? '$displayName exited with code $exitCode.'
            : stderr.trim(),
        exitCode,
      );
    }

    return stdout.trim();
  }

  Future<Process> _startProcess() async {
    try {
      return await Process.start(
        executable,
        buildArguments(),
        workingDirectory: _workingDirectory,
        environment: _environment,
      );
    } on ProcessException catch (error) {
      throw ProcessException(
        executable,
        buildArguments(),
        '$missingCliMessage\n${error.message}',
        error.errorCode,
      );
    }
  }
}

//
//  gitwhisper
//  codex_cli_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2026/05/10.
//  Copyright (c) 2026 Codecraft Solutions. All rights reserved.
//

import 'dart:io';

import 'local_cli_generator.dart';

class CodexCliGenerator extends LocalCliGenerator {
  const CodexCliGenerator({
    super.variant,
    super.environment,
    super.workingDirectory,
    super.timeout,
  }) : super(null);

  @override
  String get modelName => 'codex';

  @override
  String get executable => 'codex';

  @override
  String get displayName => 'Codex CLI';

  @override
  String get missingCliMessage =>
      'Codex CLI was not found. Install and sign in to Codex, then try again.';

  @override
  List<String> buildArguments() {
    return [
      'exec',
      '--sandbox',
      'read-only',
      '--ephemeral',
      '--cd',
      workingRoot,
      if (actualVariant.isNotEmpty) ...['--model', actualVariant],
      '--skip-git-repo-check',
      '-',
    ];
  }

  String get workingRoot => workingDirectory ?? Directory.current.path;
}

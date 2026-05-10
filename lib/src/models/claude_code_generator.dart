//
//  gitwhisper
//  claude_code_generator.dart
//
//  Created by Ngonidzashe Mangudya on 2026/05/10.
//  Copyright (c) 2026 Codecraft Solutions. All rights reserved.
//

import 'local_cli_generator.dart';

class ClaudeCodeGenerator extends LocalCliGenerator {
  const ClaudeCodeGenerator({
    super.variant,
    super.environment,
    super.workingDirectory,
    super.timeout,
  }) : super(null);

  @override
  String get modelName => 'claude-code';

  @override
  String get executable => 'claude';

  @override
  String get displayName => 'Claude Code CLI';

  @override
  String get missingCliMessage =>
      'Claude Code CLI was not found. Install and sign in to Claude Code, '
      'then try again.';

  @override
  List<String> buildArguments() {
    return [
      '--print',
      if (actualVariant.isNotEmpty) ...['--model', actualVariant],
    ];
  }
}

import 'dart:io';

import 'package:path/path.dart' as path;

import '../private_files.dart';

/// GitWhisper's ACP debug logs (`~/.gitwhisper/acp/logs`).
///
/// Off by default. Set `GITWHISPER_ACP_DEBUG=1` to write one log per ACP run.
/// Logs record the shape of the JSON-RPC traffic (methods, ids, sizes),
/// never prompts, diffs, tool output or agent text. They live in an
/// owner-only (0700) directory as owner-only (0600) files. Logs older than
/// [retention] are pruned whenever ACP starts, whether or not logging is on.
class AcpDebugLogs {
  AcpDebugLogs({
    Directory? directory,
    bool? enabled,
    Map<String, String>? environment,
    DateTime Function()? clock,
  })  : directory = directory ?? _defaultDirectory(),
        enabled = enabled ??
            _isEnabledValue(
              (environment ?? Platform.environment)[environmentVariable],
            ),
        _clock = clock ?? DateTime.now;

  /// Environment variable that turns ACP debug logging on (`1` or `true`).
  static const environmentVariable = 'GITWHISPER_ACP_DEBUG';

  /// How long GitWhisper keeps its ACP logs.
  static const retention = Duration(days: 7);

  /// Names GitWhisper gives its logs: `<agent>-<timestamp>.jsonl`, with the
  /// local ISO-8601 timestamp's `:` and `.` replaced by `-`.
  static final _logName = RegExp(
    r'^[A-Za-z0-9_.-]+-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d+Z?\.jsonl$',
  );

  final Directory directory;
  final bool enabled;
  final DateTime Function() _clock;

  /// Creates an empty private log file for [agentId], or returns null when
  /// logging is off.
  Future<File?> createLogFile(String agentId) async {
    if (!enabled) return null;
    await ensurePrivateDirectory(directory);
    final safeAgent = agentId.replaceAll(RegExp('[^a-zA-Z0-9_.-]+'), '-');
    final timestamp =
        _clock().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
    final file = File(path.join(directory.path, '$safeAgent-$timestamp.jsonl'));
    await createPrivateFile(file);
    return file;
  }

  /// Deletes GitWhisper's own ACP logs older than [retention] and returns how
  /// many were removed. Only regular files with GitWhisper's log naming in
  /// [directory] are touched.
  Future<int> prune() async {
    if (!directory.existsSync()) return 0;
    // Older GitWhisper versions wrote full prompts and diffs to 0644 files in
    // a 0755 directory. Make the directory owner-only so logs that have not
    // aged out yet are private too.
    await restrictToOwner(directory.path, directory: true);
    final cutoff = _clock().subtract(retention);
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!_logName.hasMatch(path.basename(entity.path))) continue;
      try {
        if (entity.statSync().modified.isBefore(cutoff)) {
          await entity.delete();
          removed++;
        }
      } on FileSystemException {
        // Another process may have removed it; keep pruning the rest.
      }
    }
    return removed;
  }

  static bool _isEnabledValue(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == '1' || normalized == 'true';
  }

  static Directory _defaultDirectory() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return Directory(path.join(home, '.gitwhisper', 'acp', 'logs'));
  }
}

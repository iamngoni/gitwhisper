import 'dart:io';

import 'package:path/path.dart' as path;

/// Thrown when the user's home directory cannot be determined safely.
class UserHomeException implements Exception {
  const UserHomeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Returns the current user's home directory.
///
/// GitWhisper keeps API keys, ACP approvals, the ACP registry cache and
/// installed agents under the home directory. Falling back to the current
/// directory would let a repository supply all of that state, so an unset,
/// empty or relative home is an error instead.
///
/// [environment] defaults to [Platform.environment]; [isWindows] defaults to
/// [Platform.isWindows].
String userHomeDirectory({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final env = environment ?? Platform.environment;
  final windows = isWindows ?? Platform.isWindows;
  final variable = windows ? 'USERPROFILE' : 'HOME';
  final home = env[variable]?.trim() ?? '';
  final context = windows ? path.windows : path.posix;

  if (home.isEmpty) {
    throw UserHomeException(
      'Could not determine your home directory: \$$variable is not set.',
    );
  }
  if (!context.isAbsolute(home)) {
    throw UserHomeException(
      'Could not determine your home directory: \$$variable ("$home") is '
      'not an absolute path.',
    );
  }
  return home;
}

import 'dart:io';

import 'package:path/path.dart' as path;

// Helpers for files only the current user should read: saved API keys, ACP
// approvals, and ACP debug logs.
//
// dart:io cannot pass a creation mode to open(2), so on POSIX these helpers
// create content inside a directory that is already owner-only (0700) and
// restrict the file before writing to it. Other users can never open the file
// while it holds data. Windows has no POSIX modes, so permissions are left to
// the user profile ACLs there.

/// Restricts [entityPath] to owner-only access: 0700 for directories, 0600
/// for files. Does nothing on Windows.
Future<void> restrictToOwner(
  String entityPath, {
  bool directory = false,
}) async {
  if (Platform.isWindows) return;
  final result = await Process.run(
    'chmod',
    <String>[if (directory) '700' else '600', entityPath],
  );
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not restrict permissions: ${result.stderr}'.trim(),
      entityPath,
    );
  }
}

/// Creates [directory] if needed and makes it owner-only (0700 on POSIX).
///
/// A missing directory is created through `mkdtemp`, which creates it as
/// 0700, and then renamed into place, so it is never briefly world-readable.
Future<void> ensurePrivateDirectory(Directory directory) async {
  if (Platform.isWindows) {
    await directory.create(recursive: true);
    return;
  }

  if (!directory.existsSync()) {
    await directory.parent.create(recursive: true);
    final staging = await directory.parent.createTemp(
      '.${path.basename(directory.path)}.tmp.',
    );
    try {
      await staging.rename(directory.path);
    } on FileSystemException {
      // Another process created it first; fall through and tighten it.
      if (staging.existsSync()) await staging.delete(recursive: true);
      if (!directory.existsSync()) rethrow;
    }
  }

  await restrictToOwner(directory.path, directory: true);
}

/// Creates [file] as an empty owner-only file (0600 on POSIX).
///
/// Call this before writing anything to the file. Its directory should
/// already be private (see [ensurePrivateDirectory]).
Future<void> createPrivateFile(File file) async {
  await file.create();
  await restrictToOwner(file.path);
}

/// Replaces [target] with [contents] atomically, as an owner-only file.
///
/// The new content is written to a temp file inside a private `mkdtemp`
/// directory next to [target], restricted to 0600, flushed, and then renamed
/// over [target]. Readers see either the old file or the complete new one.
/// A failed write never leaves [target] empty or truncated. If [target] is a
/// symlink (for example a dotfile managed elsewhere), the file it points to
/// is replaced and the link is kept.
Future<void> writePrivateFileAtomically(File target, String contents) async {
  var destination = target.path;
  if (FileSystemEntity.isLinkSync(destination)) {
    try {
      destination = await target.resolveSymbolicLinks();
    } on FileSystemException {
      // Dangling link: replace the link itself.
    }
  }

  final parent = Directory(path.dirname(destination));
  await parent.create(recursive: true);
  final name = path.basename(destination);
  final staging = await parent.createTemp('.$name.tmp.');
  try {
    final temp = File(path.join(staging.path, name));
    await createPrivateFile(temp);
    await temp.writeAsString(contents, flush: true);
    await _replaceFile(temp, destination);
  } finally {
    if (staging.existsSync()) await staging.delete(recursive: true);
  }
}

Future<void> _replaceFile(File source, String destination) async {
  try {
    await source.rename(destination);
  } on FileSystemException {
    if (!Platform.isWindows || !File(destination).existsSync()) rethrow;
    // Some Windows file systems refuse to rename over an existing file.
    await File(destination).delete();
    await source.rename(destination);
  }
}

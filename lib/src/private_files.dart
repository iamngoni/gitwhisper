import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

// Helpers for files only the current user should read: saved API keys, ACP
// approvals, ACP debug logs, and the Claude Code and Codex credentials that
// GitWhisper refreshes. Also bounded reads for settings and credential files
// that may not be what they claim to be.
//
// dart:io cannot pass a creation mode to open(2), so on POSIX these helpers
// create content inside a directory that is already owner-only (0700) and
// restrict the file before writing to it. Other users can never open the file
// while it holds data. Windows has no POSIX modes, so permissions are left to
// the user profile ACLs there.

/// The largest settings or credentials file GitWhisper reads: 1 MiB.
const int maxSettingsFileBytes = 1024 * 1024;

/// Thrown when a file is not read because it is not a regular file (a
/// device, FIFO or socket could block or never end) or is too large.
class UnsafeFileException extends FileSystemException {
  const UnsafeFileException(super.message, super.path);
}

/// Called with each staged file once it is owner-only and before anything is
/// written to it. Only tests set this, to check the file is private then.
void Function(File stagedFile)? debugOnPrivateFileStaged;

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

/// Makes an existing [file] owner-only (0600) when group or other users have
/// any access to it and it belongs to the current user.
///
/// Files written by older versions may still have the umask default, such as
/// 0644. Best effort: a file that cannot be checked or changed is left as it
/// is. Does nothing on Windows.
Future<void> tightenPrivateFile(File file) async {
  if (Platform.isWindows) return;
  try {
    if (file.statSync().mode & 0x3F == 0) return;
    // `test -O` succeeds only when the file belongs to the effective user.
    final owned = await Process.run('test', <String>['-O', file.path]);
    if (owned.exitCode != 0) return;
    await restrictToOwner(file.path);
  } on FileSystemException {
    // Saving the file rewrites it as 0600 anyway.
  } on ProcessException {
    // Saving the file rewrites it as 0600 anyway.
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
///
/// [isWindows] selects the Windows fallback for file systems that refuse to
/// rename over an existing file; it defaults to [Platform.isWindows].
Future<void> writePrivateFileAtomically(
  File target,
  String contents, {
  bool? isWindows,
}) async {
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
  var keepStaging = false;
  try {
    final temp = File(path.join(staging.path, name));
    await createPrivateFile(temp);
    debugOnPrivateFileStaged?.call(temp);
    await temp.writeAsString(contents, flush: true);
    try {
      await temp.rename(destination);
    } on FileSystemException {
      if (!(isWindows ?? Platform.isWindows) ||
          !File(destination).existsSync()) {
        rethrow;
      }
      // Some Windows file systems refuse to rename over an existing file.
      await File(destination).delete();
      try {
        await temp.rename(destination);
      } on FileSystemException catch (error) {
        // The old file is gone, so the staged copy is the only one left.
        keepStaging = true;
        throw FileSystemException(
          'Could not replace the file after removing it; the new contents '
          'were kept at ${temp.path}',
          destination,
          error.osError,
        );
      }
    }
  } finally {
    if (!keepStaging && staging.existsSync()) {
      await staging.delete(recursive: true);
    }
  }
}

/// Reads [file] as UTF-8 if it is a regular file of at most [maxBytes].
///
/// Returns null when nothing usable is there: the file is missing, is a
/// dangling link, or is a directory. Throws [UnsafeFileException] for a
/// device, FIFO or socket, or a file larger than [maxBytes]: reading those
/// could block forever or exhaust memory. Throws [FormatException] for
/// invalid UTF-8.
String? readRegularFileSync(
  File file, {
  int maxBytes = maxSettingsFileBytes,
}) {
  final stat = file.statSync();
  if (stat.type != FileSystemEntityType.file) {
    // stat reports devices as notFound, but they still "exist".
    if (stat.type == FileSystemEntityType.directory ||
        (stat.type == FileSystemEntityType.notFound && !file.existsSync())) {
      return null;
    }
    throw UnsafeFileException('it is not a regular file', file.path);
  }

  final tooLarge = UnsafeFileException(
    'it is larger than ${_describeSize(maxBytes)}',
    file.path,
  );
  if (stat.size > maxBytes) throw tooLarge;

  final handle = file.openSync();
  try {
    final bytes = BytesBuilder(copy: false);
    // Stop one byte past the limit in case the file grew since stat.
    while (bytes.length <= maxBytes) {
      final chunk = handle.readSync(maxBytes + 1 - bytes.length);
      if (chunk.isEmpty) break;
      bytes.add(chunk);
    }
    if (bytes.length > maxBytes) throw tooLarge;
    return utf8.decode(bytes.takeBytes());
  } finally {
    handle.closeSync();
  }
}

String _describeSize(int bytes) {
  const mebibyte = 1024 * 1024;
  if (bytes >= mebibyte && bytes % mebibyte == 0) {
    return '${bytes ~/ mebibyte} MiB';
  }
  return '$bytes bytes';
}

/// Runs [action] while holding an exclusive lock on [lockFile], creating the
/// file if needed, so only one process at a time runs it.
///
/// Waits up to [timeout] for another holder to finish. Locking is best
/// effort: if the lock cannot be taken, [onLockFailed] is told why and
/// [action] runs anyway.
Future<T> withExclusiveFileLock<T>(
  File lockFile,
  Future<T> Function() action, {
  Duration timeout = const Duration(seconds: 30),
  void Function(FileSystemException error)? onLockFailed,
}) async {
  RandomAccessFile? handle;
  try {
    handle = await lockFile.open(mode: FileMode.append);
    await _acquireExclusiveLock(handle, timeout);
  } on FileSystemException catch (error) {
    onLockFailed?.call(error);
    await _closeQuietly(handle);
    handle = null;
  }

  try {
    return await action();
  } finally {
    if (handle != null) {
      try {
        await handle.unlock();
      } on FileSystemException {
        // Closing the file releases the lock as well.
      }
      await _closeQuietly(handle);
    }
  }
}

Future<void> _acquireExclusiveLock(
  RandomAccessFile handle,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      // The default is a non-blocking exclusive lock; poll so a stuck holder
      // cannot hang this process forever.
      await handle.lock();
      return;
    } on FileSystemException {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

Future<void> _closeQuietly(RandomAccessFile? handle) async {
  try {
    await handle?.close();
  } on FileSystemException {
    // Nothing useful to do; the OS releases the handle on exit.
  }
}

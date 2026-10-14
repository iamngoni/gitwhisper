import 'dart:convert';
import 'dart:io';

import 'package:gitwhisper/src/private_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gw_private_files_test_');
  });

  tearDown(() async {
    debugOnPrivateFileStaged = null;
    // Undo any permission changes a test made so the directory can go.
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['-R', 'u+rwx', dir.path]);
    }
    await dir.delete(recursive: true);
  });

  group('writePrivateFileAtomically', () {
    test(
      'never lets the new file be readable by other users',
      () async {
        final target = File(p.join(dir.path, 'secrets.json'))
          ..writeAsStringSync('old');
        await Process.run('chmod', <String>['644', target.path]);

        final steps = <String, int>{};
        File? stagedFile;
        debugOnPrivateFileStaged = (file) {
          stagedFile = file;
          steps['staging directory'] = _mode(file.parent.path);
          steps['staged file'] = _mode(file.path);
          steps['staged length'] = file.lengthSync();
        };

        await writePrivateFileAtomically(target, 'new secret');

        // Staged in a fresh mkdtemp directory next to the target (the same
        // file system, so the rename is atomic) that only the owner can
        // enter, and restricted to 0600 before any data is written.
        expect(stagedFile, isNotNull);
        expect(stagedFile!.parent.parent.path, dir.path);
        expect(steps, <String, int>{
          'staging directory': 0x1C0,
          'staged file': 0x180,
          'staged length': 0,
        });
        expect(target.readAsStringSync(), 'new secret');
        expect(_mode(target.path), 0x180);
        expect(stagedFile!.parent.existsSync(), isFalse);
        expect(
          dir.listSync().map((entity) => p.basename(entity.path)),
          <String>['secrets.json'],
        );
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );

    test(
      'keeps the staged copy when the Windows fallback cannot replace the '
      'removed file',
      () async {
        final target = File(p.join(dir.path, 'config.yaml'))
          ..writeAsStringSync('old');
        File? stagedFile;
        debugOnPrivateFileStaged = (file) {
          stagedFile = file;
          // Renames out of a read-only directory fail, standing in for a
          // file system that refuses to rename over an existing file.
          Process.runSync('chmod', <String>['500', file.parent.path]);
        };

        Object? error;
        try {
          await writePrivateFileAtomically(
            target,
            'new contents',
            isWindows: true,
          );
        } on FileSystemException catch (caught) {
          error = caught;
        }

        if (target.existsSync()) {
          markTestSkipped('Directory permissions are not enforced (root?).');
          return;
        }
        expect(
          error,
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains(stagedFile!.path),
          ),
        );
        expect(stagedFile!.readAsStringSync(), 'new contents');
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );
  });

  group('readRegularFileSync', () {
    test('reads a regular file up to the limit', () {
      final file = File(p.join(dir.path, 'settings.json'))
        ..writeAsStringSync('x' * 16);

      expect(readRegularFileSync(file, maxBytes: 16), 'x' * 16);
    });

    test('returns null when there is no file to read', () {
      final missing = File(p.join(dir.path, 'missing.json'));
      final directory = Directory(p.join(dir.path, 'folder'))..createSync();

      expect(readRegularFileSync(missing), isNull);
      expect(readRegularFileSync(File(directory.path)), isNull);
      if (!Platform.isWindows) {
        final dangling = Link(p.join(dir.path, 'dangling.json'))
          ..createSync(missing.path);
        expect(readRegularFileSync(File(dangling.path)), isNull);
      }
    });

    test('refuses a file larger than the limit', () {
      final file = File(p.join(dir.path, 'settings.json'))
        ..writeAsStringSync('x' * 17);

      expect(
        () => readRegularFileSync(file, maxBytes: 16),
        throwsA(
          isA<UnsafeFileException>().having(
            (error) => error.message,
            'message',
            'it is larger than 16 bytes',
          ),
        ),
      );
    });

    test('refuses a settings file over 1 MiB by default', () {
      final file = File(p.join(dir.path, 'settings.json'))
        ..writeAsStringSync(
          jsonEncode(<String, String>{'padding': 'x' * (1024 * 1024)}),
        );

      expect(
        () => readRegularFileSync(file),
        throwsA(
          isA<UnsafeFileException>().having(
            (error) => error.message,
            'message',
            'it is larger than 1 MiB',
          ),
        ),
      );
    });

    test(
      'refuses devices and FIFOs without reading or blocking',
      () {
        final zero = Link(p.join(dir.path, 'zero.json'))
          ..createSync('/dev/zero');
        final fifo = p.join(dir.path, 'fifo.json');
        Process.runSync('mkfifo', <String>[fifo]);

        for (final path in <String>[zero.path, '/dev/zero', fifo]) {
          expect(
            () => readRegularFileSync(File(path)),
            throwsA(
              isA<UnsafeFileException>().having(
                (error) => error.message,
                'message',
                'it is not a regular file',
              ),
            ),
            reason: path,
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
      skip: Platform.isWindows ? 'Uses POSIX devices and FIFOs.' : false,
    );
  });

  group('tightenPrivateFile', () {
    test(
      'makes a file other users can access owner-only',
      () async {
        for (final mode in <String>['644', '640', '604', '666']) {
          final file = File(p.join(dir.path, 'config-$mode.yaml'))
            ..writeAsStringSync('{}');
          await Process.run('chmod', <String>[mode, file.path]);

          await tightenPrivateFile(file);

          expect(_mode(file.path), 0x180, reason: 'from $mode');
        }
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );

    test(
      'leaves owner-only files and missing files alone',
      () async {
        final file = File(p.join(dir.path, 'config.yaml'))
          ..writeAsStringSync('{}');
        await Process.run('chmod', <String>['400', file.path]);

        await tightenPrivateFile(file);
        await tightenPrivateFile(File(p.join(dir.path, 'missing.yaml')));

        expect(_mode(file.path), 0x100);
      },
      skip: Platform.isWindows ? 'POSIX permissions only.' : false,
    );
  });

  group('withExclusiveFileLock', () {
    test('runs the action holding the lock and then releases it', () async {
      final lockFile = File(p.join(dir.path, '.refresh.lock'));

      final result = await withExclusiveFileLock(lockFile, () async {
        expect(lockFile.existsSync(), isTrue);
        return 'done';
      });

      expect(result, 'done');
      final handle = await lockFile.open(mode: FileMode.append);
      addTearDown(handle.close);
      await handle.lock();
    });

    test('runs the action anyway when the lock is not released in time',
        () async {
      final lockFile = File(p.join(dir.path, '.refresh.lock'));
      final holder = await _startLockHolder(dir, lockFile);
      addTearDown(holder.kill);

      FileSystemException? lockError;
      final result = await withExclusiveFileLock(
        lockFile,
        () async => 'ran',
        timeout: const Duration(milliseconds: 300),
        onLockFailed: (error) => lockError = error,
      );

      expect(result, 'ran');
      expect(lockError, isNotNull);
    });
  });
}

int _mode(String path) => FileStat.statSync(path).mode & 0x1FF;

/// Starts a separate Dart process that holds [lockFile] until its stdin is
/// closed or it is killed.
Future<Process> _startLockHolder(Directory sandbox, File lockFile) async {
  final script = File(p.join(sandbox.path, 'hold_lock.dart'))
    ..writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> args) async {
  final handle = await File(args.single).open(mode: FileMode.append);
  await handle.lock();
  stdout.writeln('locked');
  await stdin.drain<void>();
  await handle.unlock();
  await handle.close();
}
''');
  final process = await Process.start(
    Platform.resolvedExecutable,
    <String>[script.path, lockFile.path],
  );
  await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((line) => line == 'locked')
      .timeout(const Duration(seconds: 60));
  return process;
}

import 'package:gitwhisper/src/user_home.dart';
import 'package:test/test.dart';

void main() {
  group('userHomeDirectory', () {
    test('returns HOME on POSIX', () {
      expect(
        userHomeDirectory(
          environment: {'HOME': '/home/dev'},
          isWindows: false,
        ),
        '/home/dev',
      );
    });

    test('returns USERPROFILE on Windows', () {
      expect(
        userHomeDirectory(
          environment: {'USERPROFILE': r'C:\Users\dev', 'HOME': '/ignored'},
          isWindows: true,
        ),
        r'C:\Users\dev',
      );
    });

    for (final home in <String?>[null, '', '   ', 'relative/home', '.']) {
      test('refuses ${home == null ? 'an unset' : '"$home" as'} HOME', () {
        expect(
          () => userHomeDirectory(
            environment: {if (home != null) 'HOME': home},
            isWindows: false,
          ),
          throwsA(isA<UserHomeException>()),
        );
      });
    }
  });
}

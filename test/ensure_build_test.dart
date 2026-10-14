@Tags(['version-verify'])
library;

import 'package:build_verify/build_verify.dart';
import 'package:test/test.dart';

void main() {
  // build_runner compiles its builders first, which can take well over the
  // default 30 seconds on a fresh CI runner.
  test(
    'ensure_build',
    expectBuildClean,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

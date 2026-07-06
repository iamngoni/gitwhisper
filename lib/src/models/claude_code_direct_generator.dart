import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../constants.dart';
import '../exceptions/exceptions.dart';
import 'claude_generator.dart';
import 'model_variants.dart';

typedef ClaudeCodeLoginRunner = Future<int> Function(
  String executable,
  List<String> arguments,
);

class ClaudeCodeDirectGenerator extends ClaudeGenerator {
  ClaudeCodeDirectGenerator({
    String? apiKey,
    String? variant,
    String? baseUrl,
    String? claudeConfigDir,
    Map<String, String>? environment,
    ClaudeCodeLoginRunner? runLogin,
    this.loginExecutable = 'claude',
    this.loginArguments = const <String>['setup-token'],
    this.useMacOsKeychain = true,
  })  : _explicitApiKey = apiKey,
        _claudeConfigDir = claudeConfigDir,
        _environment = environment,
        _runLogin = runLogin ?? _defaultRunLogin,
        super(
          apiKey,
          variant: variant,
          baseUrl: baseUrl ??
              (environment ?? Platform.environment)['ANTHROPIC_BASE_URL'],
        );

  final String? _explicitApiKey;
  final String? _claudeConfigDir;
  final Map<String, String>? _environment;
  final ClaudeCodeLoginRunner _runLogin;
  final String loginExecutable;
  final List<String> loginArguments;
  final bool useMacOsKeychain;

  Map<String, String> get _env => _environment ?? Platform.environment;

  @override
  String get modelName => 'claude-code';

  @override
  String get defaultVariant => ModelVariants.getDefault(modelName);

  @override
  Future<Map<String, String>> resolveHeaders() async {
    final auth = await _loadAuth();
    return <String, String>{
      'anthropic-version': '2023-06-01',
      ...auth.headers,
    };
  }

  Future<_ClaudeCodeAuth> _loadAuth({bool allowLogin = true}) async {
    final envAuth = _readEnvironmentAuth();
    if (envAuth != null) return envAuth;

    final storedOAuthToken = await _readStoredOAuthToken();
    if (storedOAuthToken != null) {
      return _ClaudeCodeAuth(bearerToken: storedOAuthToken);
    }

    final storedApiKey = await _readStoredApiKey();
    if (storedApiKey != null) {
      return _ClaudeCodeAuth(apiKey: storedApiKey);
    }

    if (allowLogin) {
      await _runInteractiveLogin();
      return _loadAuth(allowLogin: false);
    }

    throw const AuthenticationException(
      message: 'Claude Code credentials were not found. Run `claude '
          'setup-token` and export CLAUDE_CODE_OAUTH_TOKEN, or set '
          'ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY.',
    );
  }

  _ClaudeCodeAuth? _readEnvironmentAuth() {
    final apiKey = _nonBlank(_explicitApiKey) ??
        _nonBlank(_env['ANTHROPIC_API_KEY']) ??
        _nonBlank(_env['CLAUDE_API_KEY']);
    final bearerToken = _nonBlank(_env['CLAUDE_CODE_OAUTH_TOKEN']) ??
        _nonBlank(_env['ANTHROPIC_AUTH_TOKEN']);

    if (apiKey == null && bearerToken == null) return null;
    return _ClaudeCodeAuth(apiKey: apiKey, bearerToken: bearerToken);
  }

  Future<String?> _readStoredOAuthToken() async {
    final fileToken = await _readClaudeAiOauthTokenFromFile();
    if (fileToken != null) return fileToken;

    if (!useMacOsKeychain) return null;
    final keychainValue = await _readMacOsKeychainService(
      'Claude Code-credentials',
    );
    if (keychainValue == null) return null;

    return _extractClaudeAiOauthToken(keychainValue);
  }

  Future<String?> _readStoredApiKey() async {
    final globalConfigKey = await _readGlobalConfigApiKey();
    if (globalConfigKey != null) return globalConfigKey;

    if (!useMacOsKeychain) return null;
    final keychainValue = await _readMacOsKeychainService('Claude Code');
    if (keychainValue == null || keychainValue.startsWith('{')) return null;

    return _nonBlank(keychainValue);
  }

  Future<String?> _readClaudeAiOauthTokenFromFile() async {
    final credentialsFile = File(
      path.join(_resolvedClaudeConfigDir, '.credentials.json'),
    );
    final decoded = await _readJsonObject(credentialsFile);
    if (decoded == null) return null;

    return _readNestedString(decoded, <String>[
      'claudeAiOauth',
      'accessToken',
    ]);
  }

  Future<String?> _readGlobalConfigApiKey() async {
    final home = _env['HOME'];
    if (home == null || home.isEmpty) return null;

    final decoded =
        await _readJsonObject(File(path.join(home, '.claude.json')));
    if (decoded == null) return null;

    return _readNestedString(decoded, <String>['primaryApiKey']);
  }

  Future<Map<String, dynamic>?> _readJsonObject(File file) async {
    try {
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<dynamic, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }

    return null;
  }

  Future<String?> _readMacOsKeychainService(String service) async {
    if (!Platform.isMacOS) return null;

    final account = _nonBlank(_env['USER']) ?? _nonBlank(_env['LOGNAME']);
    if (account == null) return null;

    try {
      final result = await Process.run(
        'security',
        <String>[
          'find-generic-password',
          '-a',
          account,
          '-w',
          '-s',
          service,
        ],
      );

      if (result.exitCode != 0) return null;
      return _nonBlank(result.stdout.toString());
    } on ProcessException {
      return null;
    }
  }

  String? _extractClaudeAiOauthToken(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<dynamic, dynamic>) return null;
      return _readNestedString(
        Map<String, dynamic>.from(decoded),
        <String>['claudeAiOauth', 'accessToken'],
      );
    } on FormatException {
      return null;
    }
  }

  String? _readNestedString(
    Map<String, dynamic> object,
    List<String> pathSegments,
  ) {
    Object? current = object;
    for (final segment in pathSegments) {
      if (current is! Map<dynamic, dynamic>) return null;
      current = current[segment];
    }

    return _nonBlank(current?.toString());
  }

  Future<void> _runInteractiveLogin() async {
    $logger.info(
      'Claude Code authentication required. Starting $loginExecutable '
      '${loginArguments.join(' ')}...',
    );

    final exitCode = await _runLogin(loginExecutable, loginArguments);
    if (exitCode != 0) {
      throw AuthenticationException(
        message: '$loginExecutable ${loginArguments.join(' ')} failed with '
            'exit code $exitCode.',
      );
    }
  }

  String get _resolvedClaudeConfigDir {
    final explicit = _nonBlank(_claudeConfigDir);
    if (explicit != null) return explicit;

    final envDir = _nonBlank(_env['CLAUDE_CONFIG_DIR']);
    if (envDir != null) return envDir;

    final home = _nonBlank(_env['HOME']);
    if (home != null) return path.join(home, '.claude');

    return path.join(Directory.current.path, '.claude');
  }

  static String? _nonBlank(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  static Future<int> _defaultRunLogin(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

class _ClaudeCodeAuth {
  const _ClaudeCodeAuth({
    this.apiKey,
    this.bearerToken,
  });

  final String? apiKey;
  final String? bearerToken;

  Map<String, String> get headers {
    return <String, String>{
      if (apiKey != null) 'x-api-key': apiKey!,
      if (bearerToken != null) ...<String, String>{
        'Authorization': 'Bearer $bearerToken',
        'anthropic-beta': 'oauth-2025-04-20',
      },
    };
  }
}

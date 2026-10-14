import 'package:dio/dio.dart';
import 'package:mason_logger/mason_logger.dart';

/// Shared HTTP client for provider requests.
///
/// Dio applies [BaseOptions.receiveTimeout] to the wait for response headers
/// and then to each gap between received chunks, not to the whole body, so
/// long streamed responses keep working while data keeps arriving. The limit
/// still has to cover a full non-streamed generation, hence the generous
/// value. Requests to slow backends (e.g. local Ollama models) override it.
final Dio $dio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(minutes: 2),
    receiveTimeout: const Duration(minutes: 10),
  ),
);
final $logger = Logger(
  level: Level.verbose,
);

import 'package:curl_logger_dio_interceptor/curl_logger_dio_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:mason_logger/mason_logger.dart';

final Dio $dio = Dio()
  ..interceptors.add(
    CurlLoggerDioInterceptor(printOnSuccess: true),
  );
final $logger = Logger(
  level: Level.verbose,
);

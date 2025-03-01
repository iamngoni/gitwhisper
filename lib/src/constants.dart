import 'package:dio/dio.dart';
import 'package:mason_logger/mason_logger.dart';

final Dio $dio = Dio();
final $logger = Logger(
  level: Level.verbose,
);

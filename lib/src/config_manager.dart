//
//  gitwhisper
//  config_manager.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/01.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// Manages configuration and API keys for the application
class ConfigManager {
  static const String _configFileName = '.git_whisper.yaml';
  Map<String, dynamic> _config = {};

  /// Loads configuration from the config file
  Future<void> load() async {
    final configFile = File(_getConfigPath());
    if (configFile.existsSync()) {
      final yamlString = await configFile.readAsString();
      final yamlMap = loadYaml(yamlString);
      _config = _convertYamlToMap(yamlMap as YamlMap);
    } else {
      // Initialize with empty config if file doesn't exist
      _config = {'api_keys': <String, dynamic>{}};
    }
  }

  /// Saves the current configuration to the config file
  Future<void> save() async {
    final configFile = File(_getConfigPath());
    final yamlString = json.encode(_config);
    await configFile.writeAsString(yamlString);

    // Set file permissions to be readable only by the user
    await Process.run('chmod', ['600', _getConfigPath()]);
  }

  /// Gets the API key for the specified model
  String? getApiKey(String model) {
    return (_config['api_keys'] as Map<String, dynamic>)[model.toLowerCase()]
        as String?;
  }

  /// Gets the API key for the specified model
  (String, String)? getDefaultModelAndVariant() {
    if (_config.containsKey('defaults')) {
      final String model =
          (_config['defaults'] as Map<String, dynamic>)['model'] as String;
      final String variant =
          (_config['defaults'] as Map<String, dynamic>)['variant'] as String;

      return (model, variant);
    } else {
      return null;
    }
  }

  /// Sets the API key for the specified model
  void setApiKey(String model, String apiKey) {
    if (_config['api_keys'] == null) {
      _config['api_keys'] = <String, dynamic>{};
    }
    (_config['api_keys'] as Map<String, dynamic>)[model.toLowerCase()] = apiKey;
  }

  /// Sets the default model and default variant
  void setDefaults(String model, String modelVariant) {
    if (_config['defaults'] == null) {
      _config['defaults'] = <String, dynamic>{};
    }
    (_config['defaults'] as Map<String, dynamic>)['model'] = model;
    (_config['defaults'] as Map<String, dynamic>)['variant'] = modelVariant;
  }

  /// Clears the default model and default variant
  void clearDefaults() {
    if (_config['defaults'] != null) {
      _config.remove('defaults');
    }
  }

  /// Gets the path to the config file
  String _getConfigPath() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return path.join(home!, _configFileName);
  }

  /// Converts a YamlMap to a regular Map
  Map<String, dynamic> _convertYamlToMap(YamlMap yamlMap) {
    final map = <String, dynamic>{};
    for (final entry in yamlMap.entries) {
      if (entry.value is YamlMap) {
        map[entry.key.toString()] = _convertYamlToMap(entry.value as YamlMap);
      } else if (entry.value is YamlList) {
        map[entry.key.toString()] = _convertYamlList(entry.value as YamlList);
      } else {
        map[entry.key.toString()] = entry.value;
      }
    }
    return map;
  }

  /// Converts a YamlList to a regular List
  List<dynamic> _convertYamlList(YamlList yamlList) {
    return yamlList.map((item) {
      if (item is YamlMap) {
        return _convertYamlToMap(item);
      } else if (item is YamlList) {
        return _convertYamlList(item);
      } else {
        return item;
      }
    }).toList();
  }
}

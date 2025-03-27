//
//  gitwhisper
//  template_manager.dart
//
//  Created by Ngonidzashe Mangudya on 2025/03/27.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

class TemplateManager {
  TemplateManager() {
    _templates = _loadTemplates();
  }
  static const _configFile = '.git_whisper_templates.yaml';
  static const _defaultTemplateName = 'default';
  static const _defaultTemplate = '{{type}}: {{emoji}} {{description}}';

  late final Map<String, dynamic> _templates;

  Map<String, dynamic> _loadTemplates() {
    final file = File(_getConfigPath());
    if (!file.existsSync()) {
      // Create default template if file doesn't exist
      _saveTemplates({_defaultTemplateName: _defaultTemplate});
      return {_defaultTemplateName: _defaultTemplate};
    }

    try {
      final content = file.readAsStringSync();
      final YamlMap yamlMap = loadYaml(content) as YamlMap;
      // Convert YamlMap to Map<String, dynamic>
      final Map<String, dynamic> templates = {};
      for (final entry in yamlMap.entries) {
        templates[entry.key.toString()] = entry.value;
      }
      return templates;
    } catch (e) {
      // If file is corrupted, reset to default
      _saveTemplates({_defaultTemplateName: _defaultTemplate});
      return {_defaultTemplateName: _defaultTemplate};
    }
  }

  void _saveTemplates(Map<String, dynamic> templates) {
    final file = File(_getConfigPath());
    final content = json.encode(templates);
    file.writeAsStringSync(content);
    _templates = templates;
  }

  String _getConfigPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return path.join(home, _configFile);
  }

  // Get all available templates
  Map<String, String> getAllTemplates() {
    return Map<String, String>.from(_templates);
  }

  // Get a specific template by name
  String getTemplate(String name) {
    return _templates[name] as String? ?? _defaultTemplate;
  }

  // Add or update a template
  void saveTemplate(String name, String template) {
    _templates[name] = template;
    _saveTemplates(_templates);
  }

  // Delete a template
  void deleteTemplate(String name) {
    if (name == _defaultTemplateName) {
      throw ArgumentError('Cannot delete the default template');
    }
    _templates.remove(name);
    _saveTemplates(_templates);
  }
}

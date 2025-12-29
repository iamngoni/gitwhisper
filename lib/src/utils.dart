//
//  gitwhisper
//  utils.dart
//
//  Created by Ngonidzashe Mangudya on 2025/12/29.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//


extension StringExtension on String {
  String get heading {
    final s = trim();
    if (s.isEmpty) return s;

    // 1) Normalize separators to spaces
    var out = s.replaceAll(RegExp(r'[_\-\.\s]+'), ' ');

    // 2) Insert spaces for camelCase / PascalCase boundaries:
    //    - "baseUrl" -> "base Url"
    //    - "URLValue" -> "URL Value"
    out = out
        .replaceAllMapped(
          RegExp('([a-z0-9])([A-Z])'),
          (m) => '${m[1]} ${m[2]}',
        )
        .replaceAllMapped(
          RegExp('([A-Z]+)([A-Z][a-z])'),
          (m) => '${m[1]} ${m[2]}',
        );

    // 3) Title-case each word
    final words = out.split(' ').where((w) => w.isNotEmpty).map((w) {
      final lower = w.toLowerCase();
      return lower[0].toUpperCase() + lower.substring(1);
    }).toList();

    return words.join(' ');
  }
}

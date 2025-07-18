//
//  gitwhisper
//  language.dart
//
//  Created by Ngonidzashe Mangudya on 2025/07/18.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

enum Language {
  english('English', 'en', 'US'),
  spanish('Spanish', 'es', 'ES'),
  french('French', 'fr', 'FR'),
  german('German', 'de', 'DE'),
  chineseSimplified('Chinese (simplified)', 'zh', 'CN'),
  chineseTraditional('Chinese (traditional)', 'zh', 'TW'),
  japanese('Japanese', 'ja', 'JP'),
  korean('Korean', 'ko', 'KR'),
  arabic('Arabic', 'ar', 'SA'),
  italian('Italian', 'it', 'IT'),
  portuguese('Portuguese', 'pt', 'PT'),
  russian('Russian', 'ru', 'RU'),
  dutch('Dutch', 'nl', 'NL'),
  swedish('Swedish', 'sv', 'SE'),
  norwegian('Norwegian', 'no', 'NO'),
  danish('Danish', 'da', 'DK'),
  finnish('Finnish', 'fi', 'FI'),
  greek('Greek', 'el', 'GR'),
  turkish('Turkish', 'tr', 'TR'),
  hindi('Hindi', 'hi', 'IN'),
  englishUS('English (US)', 'en', 'US'),
  englishUK('English (UK)', 'en', 'GB'),
  shona('Shona', 'sn', 'ZW'),
  zulu('Zulu', 'zu', 'ZA');

  const Language(this.name, this.code, this.countryCode);
  final String name;
  final String code;
  final String countryCode;

  @override
  String toString() => name;
}

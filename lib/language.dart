import 'dart:ui';

enum AppLanguage {
  english('en', 'English'),
  chinese('zh', '简体中文'),
  japanese('ja', '日本語'),
  french('fr', 'Français'),
  spanish('es', 'Español');

  const AppLanguage(this.code, this.label);
  final String code;
  final String label;

  Locale get locale => Locale(code);

  static AppLanguage fromCode(Object? code) =>
      values.where((language) => language.code == code).firstOrNull ?? chinese;
}

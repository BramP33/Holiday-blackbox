import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class AppLocalizations {
  AppLocalizations(this.locale, this._strings, this._fallbackStrings);

  final Locale locale;
  final Map<String, String> _strings;
  final Map<String, String> _fallbackStrings;

  static const supportedLocales = [Locale('en'), Locale('nl')];

  static const localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    AppLocalizationsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  static AppLocalizations of(BuildContext context) {
    final result = Localizations.of<AppLocalizations>(context, AppLocalizations);
    assert(result != null, 'No AppLocalizations found in context');
    return result!;
  }

  String translate(String key, {Map<String, String>? params}) {
    String? value = _strings[key] ?? _fallbackStrings[key];
    value ??= key;
    if (params != null) {
      params.forEach((placeholder, replacement) {
        value = value!.replaceAll('{$placeholder}', replacement);
      });
    }
    return value!;
  }
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales
        .any((supported) => supported.languageCode == locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final fallbackData = await _loadJson('en');
    final localeData = locale.languageCode == 'en'
        ? fallbackData
        : await _loadJson(locale.languageCode) ?? fallbackData;

    final fallbackStrings = _mapToStrings(fallbackData ?? {});
    final localeStrings = _mapToStrings(localeData ?? {});

    return AppLocalizations(locale, {...fallbackStrings, ...localeStrings}, fallbackStrings);
  }

  Future<Map<String, dynamic>?> _loadJson(String languageCode) async {
    try {
      final raw = await rootBundle.loadString('assets/i18n/$languageCode.json');
      return json.decode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _mapToStrings(Map<String, dynamic> source) {
    return source.map((key, value) => MapEntry(key, value.toString()));
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) => false;
}

extension AppLocalizationsBuildContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
  String tr(String key, {Map<String, String>? params}) => l10n.translate(key, params: params);
}

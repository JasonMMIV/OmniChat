// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/main.dart';

void main() {
  testWidgets('OmniChat app builds', (WidgetTester tester) async {
    // SettingsProvider._load 會讀 prefs + secure storage；未 mock 的
    // platform channel 在測試中永不回傳（背景卡住 _load）。
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const MyApp(enableUpdateCheck: false));

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

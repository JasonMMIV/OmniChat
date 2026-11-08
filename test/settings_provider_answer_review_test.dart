// Answer Review v1 — settings tests (docs/answer_review_plan.md §11.4).
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/backup/backup_preferences.dart' as backup;

/// 建立已載入完成的真實 SettingsProvider（_load 完成後會 notifyListeners）。
Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('defaults to off', () async {
    final sp = await _loadedProvider();
    expect(sp.answerReviewMode, AnswerReviewMode.off);
  });

  test('invalid persisted value falls back to off', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'answer_review_v1': 'bogus',
    });
    final sp = await _loadedProvider();
    expect(sp.answerReviewMode, AnswerReviewMode.off);
  });

  test('setter persists across provider instances', () async {
    final sp = await _loadedProvider();
    await sp.setAnswerReviewMode(AnswerReviewMode.smart);
    expect(sp.answerReviewMode, AnswerReviewMode.smart);

    final sp2 = await _loadedProvider();
    expect(sp2.answerReviewMode, AnswerReviewMode.smart);

    await sp2.setAnswerReviewMode(AnswerReviewMode.always);
    final sp3 = await _loadedProvider();
    expect(sp3.answerReviewMode, AnswerReviewMode.always);
  });

  test('setAnswerReviewMode with the same value is a no-op', () async {
    final sp = await _loadedProvider();
    var notifications = 0;
    void listener() => notifications++;
    sp.addListener(listener);
    await sp.setAnswerReviewMode(AnswerReviewMode.off);
    sp.removeListener(listener);
    expect(notifications, 0);
  });

  test('copyWith overrides and preserves the mode', () async {
    final sp = await _loadedProvider();
    final copy = sp.copyWith(answerReviewMode: AnswerReviewMode.always);
    expect(copy.answerReviewMode, AnswerReviewMode.always);
    expect(sp.answerReviewMode, AnswerReviewMode.off);

    final keep = sp.copyWith();
    expect(keep.answerReviewMode, AnswerReviewMode.off);
  });

  test('answer_review_v1 is NOT device-local: it travels with backups',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'answer_review_v1': 'always',
    });
    final async = await backup.SharedPreferencesAsync.instance;
    final snapshot = await async.snapshot();
    expect(snapshot['answer_review_v1'], 'always');
  });
}

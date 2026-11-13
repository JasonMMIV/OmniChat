import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/stt/transcript_join.dart';

void main() {
  test('empty sides return the other side', () {
    expect(joinTranscript('', 'hello'), 'hello');
    expect(joinTranscript('hello', ''), 'hello');
    expect(joinTranscript('', ''), '');
  });

  test('Latin segments get a single space', () {
    expect(joinTranscript('hello', 'world'), 'hello world');
  });

  test('Chinese segments get no space', () {
    expect(joinTranscript('你好', '世界'), '你好世界');
    expect(joinTranscript('你好。', '世界'), '你好。世界');
  });

  test('mixed Chinese/Latin does not inject spaces', () {
    expect(joinTranscript('我用 Flutter', '寫程式'), '我用 Flutter寫程式');
  });

  test('punctuation at the boundary gets a space before the next word', () {
    expect(joinTranscript('Hello,', 'world'), 'Hello, world');
  });

  test('existing leading whitespace is respected', () {
    expect(joinTranscript('hello', ' world'), 'hello world');
    expect(joinTranscript('hello ', 'world'), 'hello world');
  });

  test('Hangul uses spaces between words', () {
    expect(joinTranscript('안녕', '하세요'), '안녕 하세요');
  });

  test('Japanese kana gets no space', () {
    expect(joinTranscript('こんにちは', 'せかい'), 'こんにちはせかい');
  });

  test('digits behave like Latin words', () {
    expect(joinTranscript('2026', 'year'), '2026 year');
  });
}

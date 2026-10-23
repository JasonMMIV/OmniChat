import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' as cs;
import 'package:enough_convert/gbk.dart' as enough_gbk;
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/web/charset_decoder.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  // Fixtures captured from their respective tables.
  final big5Traditional = _bytes(<int>[
    0xC1,
    0x63,
    0xC5,
    0xE9,
    0xA4,
    0xA4,
    0xA4,
    0xE5,
  ]); // 繁體中文
  final gbkSimplified = _bytes(<int>[
    0xBC,
    0xF2,
    0xCC,
    0xE5,
    0xD6,
    0xD0,
    0xCE,
    0xC4,
  ]); // 简体中文
  final shiftJisJapanese = _bytes(<int>[
    0x93,
    0xFA,
    0x96,
    0x7B,
    0x8C,
    0xEA,
  ]); // 日本語

  group('declared charsets', () {
    test('utf-8', () {
      final decoded = CharsetDecoder.decode(
        Uint8List.fromList(utf8.encode('hello 世界')),
        contentType: 'text/plain; charset=utf-8',
      );
      expect(decoded.text, 'hello 世界');
      expect(decoded.charset, 'utf-8');
      expect(decoded.charsetFallback, isFalse);
    });

    test('big5', () {
      final decoded = CharsetDecoder.decode(
        big5Traditional,
        contentType: 'text/html; charset=big5',
      );
      expect(decoded.text, '繁體中文');
      expect(decoded.charset, 'big5');
    });

    test('gbk', () {
      final decoded = CharsetDecoder.decode(
        gbkSimplified,
        contentType: 'text/html; charset=gbk',
      );
      expect(decoded.text, '简体中文');
      expect(decoded.charset, 'gbk');
    });

    test('gb2312 label normalizes to gbk', () {
      final decoded = CharsetDecoder.decode(
        gbkSimplified,
        contentType: 'text/html; charset=gb2312',
      );
      expect(decoded.text, '简体中文');
      expect(decoded.charset, 'gbk');
    });

    test('shift-jis', () {
      final decoded = CharsetDecoder.decode(
        shiftJisJapanese,
        contentType: 'text/html; charset=Shift_JIS',
      );
      expect(decoded.text, '日本語');
      expect(decoded.charset, 'shift_jis');
    });

    test('unknown labels fall through to detection', () {
      final decoded = CharsetDecoder.decode(
        Uint8List.fromList(utf8.encode('plain')),
        contentType: 'text/plain; charset=x-unknown',
      );
      expect(decoded.text, 'plain');
      expect(decoded.charset, 'utf-8');
    });
  });

  group('BOM', () {
    test('UTF-8 BOM', () {
      final decoded = CharsetDecoder.decode(
        _bytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode('abc')]),
      );
      expect(decoded.text, 'abc');
      expect(decoded.charset, 'utf-8');
    });

    test('UTF-16LE BOM', () {
      final decoded = CharsetDecoder.decode(
        _bytes(<int>[0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00]),
      );
      expect(decoded.text, 'AB');
      expect(decoded.charset, 'utf-16le');
    });

    test('UTF-16BE BOM', () {
      final decoded = CharsetDecoder.decode(
        _bytes(<int>[0xFE, 0xFF, 0x00, 0x41, 0x00, 0x42]),
      );
      expect(decoded.text, 'AB');
      expect(decoded.charset, 'utf-16be');
    });
  });

  group('HTML meta detection', () {
    test('meta charset is honoured without a content-type', () {
      final html = <int>[
        ...ascii.encode('<html><head><meta charset="big5"></head><body>'),
        ...big5Traditional,
        ...ascii.encode('</body></html>'),
      ];
      final decoded = CharsetDecoder.decode(_bytes(html));
      expect(decoded.charset, 'big5');
      expect(decoded.text, contains('繁體中文'));
    });

    test('http-equiv meta content is honoured', () {
      final html = <int>[
        ...ascii.encode(
          '<meta http-equiv="Content-Type" content="text/html; charset=gbk">',
        ),
        ...gbkSimplified,
      ];
      final decoded = CharsetDecoder.decode(_bytes(html));
      expect(decoded.charset, 'gbk');
      expect(decoded.text, contains('简体中文'));
    });
  });

  group('fallbacks', () {
    test('undeclared Big5 is detected over UTF-8 / latin1', () {
      final decoded = CharsetDecoder.decode(big5Traditional);
      expect(decoded.charset, 'big5');
      expect(decoded.text, '繁體中文');
    });

    test('undeclared Shift-JIS is decoded as Japanese, not GBK', () {
      final decoded = CharsetDecoder.decode(shiftJisJapanese);
      expect(decoded.charset, 'shift_jis');
      expect(decoded.text, '日本語');
    });

    test('lone high bytes fall back to latin1', () {
      final decoded = CharsetDecoder.decode(_bytes(<int>[0xE9]));
      expect(decoded.charset, 'iso-8859-1');
      expect(decoded.text, 'é');
    });

    test('fallback flag is set when replacement characters appear', () {
      final decoded = CharsetDecoder.decode(
        _bytes(<int>[0x41, 0x80, 0x42]),
        contentType: 'text/plain; charset=utf-8',
      );
      expect(decoded.charsetFallback, isTrue);
    });
  });

  group('package consistency', () {
    test('enough_convert and charset agree on GBK', () {
      final fromEnough = enough_gbk.gbk.decode(gbkSimplified);
      final fromCharset = const cs.GbkCodec().decode(gbkSimplified);
      expect(fromEnough, fromCharset);
      expect(fromEnough, '简体中文');
    });
  });
}

// Web fetch charset decoding (WEB_FETCH_PLAN.md §5.4).
//
// Detection order: Content-Type charset → BOM → <meta charset> in the first
// 4 KB → strict UTF-8 → best-effort CJK candidates → latin1.
//
// Package split is deliberate (never mix them):
//   * enough_convert: Big5, GBK (MPL-2.0)
//   * charset:        Shift-JIS, EUC-JP, EUC-KR (Apache-2.0)
//   * dart:convert:   UTF-8 / UTF-16 / latin1

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' as cs;
import 'package:enough_convert/big5.dart' as enough_big5;
import 'package:enough_convert/gbk.dart' as enough_gbk;

/// Result of decoding a response body.
class DecodedBody {
  const DecodedBody({
    required this.text,
    required this.charset,
    required this.charsetFallback,
  });

  final String text;

  /// Canonical label of the encoding that produced [text] (`utf-8`, `big5`,
  /// `gbk`, `shift_jis`, `euc-jp`, `euc-kr`, `utf-16le`, `utf-16be`,
  /// `iso-8859-1`).
  final String charset;

  /// True when the decoder had to replace invalid bytes.
  final bool charsetFallback;
}

class CharsetDecoder {
  CharsetDecoder._();

  static const int metaProbeBytes = 4096;

  /// Decodes [bytes], honouring [contentType]'s `charset=` when present.
  static DecodedBody decode(Uint8List bytes, {String? contentType}) {
    if (bytes.isEmpty) {
      return const DecodedBody(
        text: '',
        charset: 'utf-8',
        charsetFallback: false,
      );
    }

    final declared = _charsetFromContentType(contentType);
    if (declared != null) {
      final decoded = _decodeWith(declared, bytes);
      if (decoded != null) {
        return DecodedBody(
          text: decoded,
          charset: declared,
          charsetFallback: decoded.contains('\uFFFD'),
        );
      }
    }

    final bom = _decodeBom(bytes);
    if (bom != null) return bom;

    final meta = _charsetFromMeta(bytes);
    if (meta != null) {
      final decoded = _decodeWith(meta, bytes);
      if (decoded != null) {
        return DecodedBody(
          text: decoded,
          charset: meta,
          charsetFallback: decoded.contains('\uFFFD'),
        );
      }
    }

    try {
      return DecodedBody(
        text: utf8.decode(bytes),
        charset: 'utf-8',
        charsetFallback: false,
      );
    } on FormatException {
      // Not valid UTF-8 and nothing declared: pick the CJK candidate that
      // produces the fewest replacement characters.
    }

    String? best;
    String bestLabel = 'utf-8';
    var bestBadness = 1 << 30;
    for (final candidate in const <String>['big5', 'gbk', 'shift_jis']) {
      final decoded = _decodeWith(candidate, bytes);
      if (decoded == null) continue;
      final badness = _replacementCount(decoded);
      if (badness < bestBadness) {
        best = decoded;
        bestLabel = candidate;
        bestBadness = badness;
      }
      if (badness == 0) break;
    }
    final latin1Badness = _replacementCount(latin1.decode(bytes));
    if (best != null && (bestBadness == 0 || bestBadness < latin1Badness)) {
      return DecodedBody(
        text: best,
        charset: bestLabel,
        charsetFallback: bestBadness > 0,
      );
    }

    return DecodedBody(
      text: latin1.decode(bytes),
      charset: 'iso-8859-1',
      charsetFallback: false,
    );
  }

  /// Normalizes a charset label (including `charset=` parameter syntax) to
  /// the canonical label used by this decoder. Returns null for labels this
  /// build cannot decode.
  static String? normalizeLabel(String? raw) {
    if (raw == null) return null;
    var label = raw.trim().toLowerCase();
    if (label.isEmpty) return null;
    final semi = label.indexOf(';');
    if (semi >= 0) label = label.substring(0, semi).trim();
    label = label.replaceAll('"', '').replaceAll("'", '').trim();
    switch (label) {
      case 'utf-8':
      case 'utf8':
      case 'unicode-1-1-utf-8':
        return 'utf-8';
      case 'big5':
      case 'big5-hkscs':
      case 'cp950':
      case 'csbig5':
        return 'big5';
      case 'gbk':
      case 'gb2312':
      case 'gb18030':
      case 'cp936':
      case 'x-gbk':
        return 'gbk';
      case 'shift_jis':
      case 'shift-jis':
      case 'sjis':
      case 'cp932':
      case 'ms_kanji':
      case 'x-sjis':
        return 'shift_jis';
      case 'euc-jp':
      case 'eucjp':
      case 'x-euc-jp':
        return 'euc-jp';
      case 'euc-kr':
      case 'euckr':
      case 'cp949':
      case 'ks_c_5601-1987':
        return 'euc-kr';
      case 'utf-16le':
      case 'utf-16':
        return 'utf-16le';
      case 'utf-16be':
        return 'utf-16be';
      case 'iso-8859-1':
      case 'latin1':
      case 'latin-1':
      case 'us-ascii':
      case 'windows-1252':
        return 'iso-8859-1';
      default:
        return null;
    }
  }

  static String? _charsetFromContentType(String? contentType) {
    if (contentType == null) return null;
    final match = RegExp(
      r'charset\s*=\s*("?)([^;"\s]+)\1',
      caseSensitive: false,
    ).firstMatch(contentType);
    if (match == null) return null;
    return normalizeLabel(match.group(2));
  }

  static String? _charsetFromMeta(Uint8List bytes) {
    final probeLength = bytes.length < metaProbeBytes
        ? bytes.length
        : metaProbeBytes;
    final head = latin1.decode(bytes.sublist(0, probeLength));
    final direct = RegExp(
      r'''<meta[^>]+charset\s*=\s*["']?\s*([a-zA-Z0-9_\-]+)''',
      caseSensitive: false,
    ).firstMatch(head);
    if (direct != null) {
      final label = normalizeLabel(direct.group(1));
      if (label != null) return label;
    }
    final httpEquiv = RegExp(
      r'''<meta[^>]+http-equiv\s*=\s*["']?content-type["']?[^>]*>''',
      caseSensitive: false,
    ).firstMatch(head);
    if (httpEquiv != null) {
      final content = RegExp(
        r'''content\s*=\s*["']([^"']*)''',
        caseSensitive: false,
      ).firstMatch(httpEquiv.group(0)!);
      if (content != null) {
        final label = _charsetFromContentType(content.group(1));
        if (label != null) return label;
      }
    }
    return null;
  }

  static DecodedBody? _decodeBom(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return DecodedBody(
        text: utf8.decode(bytes.sublist(3), allowMalformed: true),
        charset: 'utf-8',
        charsetFallback: false,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return DecodedBody(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: true),
        charset: 'utf-16le',
        charsetFallback: false,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return DecodedBody(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: false),
        charset: 'utf-16be',
        charsetFallback: false,
      );
    }
    return null;
  }

  static String? _decodeWith(String label, Uint8List bytes) {
    try {
      switch (label) {
        case 'utf-8':
          return utf8.decode(bytes, allowMalformed: true);
        case 'big5':
          return const enough_big5.Big5Decoder(allowInvalid: true).convert(bytes);
        case 'gbk':
          return const enough_gbk.GbkDecoder(allowInvalid: true).convert(bytes);
        case 'shift_jis':
          return const cs.ShiftJISCodec(allowMalformed: true).decode(bytes);
        case 'euc-jp':
          return const cs.EucJPDecoder(true).convert(bytes);
        case 'euc-kr':
          return const cs.EucKRDecoder(true).convert(bytes);
        case 'utf-16le':
          return _decodeUtf16(bytes, littleEndian: true);
        case 'utf-16be':
          return _decodeUtf16(bytes, littleEndian: false);
        case 'iso-8859-1':
          return latin1.decode(bytes);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(
        littleEndian
            ? (bytes[i + 1] << 8) | bytes[i]
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(units);
  }

  static int _replacementCount(String text) {
    var count = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0xFFFD) count++;
    }
    return count;
  }
}

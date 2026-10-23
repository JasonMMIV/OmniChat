// Web fetch charset decoding (WEB_FETCH_PLAN.md §5.4).
//
// Detection order: Content-Type charset → BOM → <meta charset> in the first
// 4 KB → strict UTF-8 → script-plausibility scoring for CJK → latin1.
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

  /// Plausibility scoring only needs a representative prefix; decoding three
  /// 2 MB candidates and scanning every rune would add avoidable latency.
  static const int plausibilitySampleChars = 64 * 1024;

  static const List<String> _candidateOrder = <String>[
    'big5',
    'gbk',
    'shift_jis',
  ];

  /// Characters that are common in Traditional Chinese but rare in Simplified
  /// Chinese. Used only to rank already-decodable candidates.
  static final Set<int> _traditionalHints = _hints(
    '繁體中文國學說時會來對開關進過發後裡麼動現點業兩間問題並產員電數報結'
    '務場計區隊書聽廣東車極辦議證轉單愛擊團華離請際復線滿須寫稱嗎標談圖'
    '歷醫專費號盡較語僅隨選紅響雖勢參眾構節範殺蘇願錢網熱屬臉職樂獨彈創'
    '錯蘭腦預誰陽繼驚傷藥適衛險陸習勞財環歡獲負雲遊龍樹層漢簡擔靜積餘檢'
    '協勝階審堅媽劉讀壓銀買養懷亂幫歲優鐵稅藝陣腳惡頓島戶評寶釋顧貨歐換'
    '聞壞麗臨魚雜誤灣編敗溫劍貴槍樓縣頁傑築鄭貝吳圓',
  );

  /// Characters that are common in Simplified Chinese but rare in Traditional
  /// Chinese.
  static final Set<int> _simplifiedHints = _hints(
    '简体中文国学说话时会来对开关进过发后里么动现点业两间问题并产员电数报结'
    '务场计区队书听广东车极办议证转单爱击团华离请际复线满须写称吗标谈图'
    '历医专费号尽较语仅随选红响虽势参众构节范杀苏愿钱网热属脸职乐独弹创'
    '错兰脑预谁阳继惊伤药适卫险陆习劳财环欢获负云游龙树层汉简担静积余检'
    '协胜阶审坚妈刘读压银买养怀乱帮岁优铁税艺阵脚恶顿岛户评宝释顾货欧换'
    '闻坏丽临鱼杂误湾编败温剑贵枪楼县页杰筑郑贝吴圆',
  );

  /// Common Japanese kanji. Kana are counted separately and weighted higher.
  static final Set<int> _japaneseHints = _hints(
    '日本語人年大月小中高校生先私今週間事思言読書聞食飲買友達駅電車道家'
    '出入上下新古安長短明暗白黒赤青空海山川花木雨風雪春夏秋冬朝昼夜一'
    '二三四五六七八九十百千万円時分気前後男子女学校会社員手目何',
  );

  static Set<int> _hints(String value) => value.runes.toSet();

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
        final sample = _sample(decoded);
        final badness = _replacementCount(sample);
        if (badness <= _tolerance(sample.length)) {
          return DecodedBody(
            text: decoded,
            charset: declared,
            charsetFallback: badness > 0,
          );
        }
        // A declared charset that produces mostly replacement characters is
        // almost always wrong (legacy hosts often mislabel Big5 as UTF-8).
        // Fall through to BOM/meta/candidate detection instead of returning
        // guaranteed mojibake.
      }
    }

    final bom = _decodeBom(bytes);
    if (bom != null) return bom;

    final meta = _charsetFromMeta(bytes);
    if (meta != null) {
      final decoded = _decodeWith(meta, bytes);
      if (decoded != null) {
        final sample = _sample(decoded);
        final badness = _replacementCount(sample);
        if (badness <= _tolerance(sample.length)) {
          return DecodedBody(
            text: decoded,
            charset: meta,
            charsetFallback: badness > 0,
          );
        }
      }
    }

    try {
      return DecodedBody(
        text: utf8.decode(bytes),
        charset: 'utf-8',
        charsetFallback: false,
      );
    } on FormatException {
      // Not valid UTF-8 and nothing usable declared: rank CJK candidates.
    }

    final candidates = <_Candidate>[];
    for (final label in _candidateOrder) {
      final decoded = _decodeWith(label, bytes);
      if (decoded == null) continue;
      final sample = _sample(decoded);
      final badness = _replacementCount(sample);
      final plausibility = _plausibility(sample, label);
      candidates.add(
        _Candidate(
          label: label,
          text: decoded,
          badness: badness,
          plausibility: plausibility,
          score: plausibility * 8 - badness * 3,
        ),
      );
    }
    candidates.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byBadness = a.badness.compareTo(b.badness);
      if (byBadness != 0) return byBadness;
      return _candidateOrder
          .indexOf(a.label)
          .compareTo(_candidateOrder.indexOf(b.label));
    });

    final best = candidates.isEmpty ? null : candidates.first;
    if (best != null && (best.plausibility > 0 || best.badness == 0)) {
      final isAscii = best.text.codeUnits.every((unit) => unit < 0x80);
      return DecodedBody(
        text: best.text,
        charset: isAscii ? 'utf-8' : best.label,
        charsetFallback: best.badness > 0,
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

  static int _tolerance(int length) =>
      (length ~/ 100).clamp(1, 8).toInt();

  static int _plausibility(String text, String label) {
    final hints = switch (label) {
      'big5' => _traditionalHints,
      'gbk' => _simplifiedHints,
      _ => _japaneseHints,
    };
    var hits = 0;
    for (final rune in text.runes) {
      if (hints.contains(rune)) hits++;
      if (label == 'shift_jis' && _isKana(rune)) hits += 2;
    }
    return hits;
  }

  static bool _isKana(int rune) =>
      (rune >= 0x3040 && rune <= 0x309F) ||
      (rune >= 0x30A0 && rune <= 0x30FF);

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
      final text = utf8.decode(bytes.sublist(3), allowMalformed: true);
      return DecodedBody(
        text: text,
        charset: 'utf-8',
        charsetFallback: text.contains('\uFFFD'),
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

  static String _sample(String text) => text.length <= plausibilitySampleChars
      ? text
      : text.substring(0, plausibilitySampleChars);

  static int _replacementCount(String text) {
    var count = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0xFFFD) count++;
    }
    return count;
  }
}

class _Candidate {
  const _Candidate({
    required this.label,
    required this.text,
    required this.badness,
    required this.plausibility,
    required this.score,
  });

  final String label;
  final String text;
  final int badness;
  final int plausibility;
  final int score;
}

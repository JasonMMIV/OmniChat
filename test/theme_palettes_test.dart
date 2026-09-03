import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/theme/palettes.dart';

void main() {
  group('ThemePalettes', () {
    test('contains exactly 6 curated palettes', () {
      expect(ThemePalettes.all.length, 6);
      final ids = ThemePalettes.all.map((p) => p.id).toList();
      expect(ids, containsAll([
        ThemePalettes.blueId,
        ThemePalettes.monochromeId,
        ThemePalettes.minimalId,
        ThemePalettes.vermillionId,
        ThemePalettes.amberId,
        ThemePalettes.greenId,
      ]));
    });

    test('byId resolves existing palettes and falls back gracefully', () {
      expect(ThemePalettes.byId('blue').id, 'blue');
      expect(ThemePalettes.byId('monochrome').id, 'monochrome');
      expect(ThemePalettes.byId('minimal').id, 'minimal');
      expect(ThemePalettes.byId('vermillion').id, 'vermillion');
      expect(ThemePalettes.byId('amber').id, 'amber');
      expect(ThemePalettes.byId('green').id, 'green');

      // Old / unknown IDs fallback to blue (海霄藍)
      expect(ThemePalettes.byId('default').id, 'blue');
      expect(ThemePalettes.byId('purple').id, 'blue');
      expect(ThemePalettes.byId('nonexistent_id').id, 'blue');
    });

    test('supports both Traditional and Simplified Chinese naming', () {
      final blue = ThemePalettes.blue;
      expect(blue.displayNameZh, '海霄蓝');
      expect(blue.displayNameZhHant, '海霄藍');

      final mono = ThemePalettes.monochrome;
      expect(mono.displayNameZh, '纸墨灰');
      expect(mono.displayNameZhHant, '紙墨灰');

      final minimal = ThemePalettes.minimal;
      expect(minimal.displayNameZh, '极简蓝');
      expect(minimal.displayNameZhHant, '極簡藍');
      expect(minimal.light.primary, const Color(0xFF2563EB)); // RikkaHub Minimal Blue

      final vermillion = ThemePalettes.vermillion;
      expect(vermillion.displayNameZh, '朱砂红');
      expect(vermillion.displayNameZhHant, '硃砂紅');

      final amber = ThemePalettes.amber;
      expect(amber.displayNameZh, '琥珀金');
      expect(amber.displayNameZhHant, '琥珀金');

      final green = ThemePalettes.green;
      expect(green.displayNameZh, '翡翠绿');
      expect(green.displayNameZhHant, '翡翠綠');
    });

    testWidgets('localizedName resolves according to Locale', (tester) async {
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('zh', 'TW'),
          delegates: const [DefaultWidgetsLocalizations.delegate],
          child: Builder(
            builder: (context) {
              expect(ThemePalettes.blue.localizedName(context), '海霄藍');
              expect(ThemePalettes.monochrome.localizedName(context), '紙墨灰');
              expect(ThemePalettes.minimal.localizedName(context), '極簡藍');
              expect(ThemePalettes.vermillion.localizedName(context), '硃砂紅');
              return const SizedBox();
            },
          ),
        ),
      );

      await tester.pumpWidget(
        Localizations(
          locale: const Locale('zh', 'CN'),
          delegates: const [DefaultWidgetsLocalizations.delegate],
          child: Builder(
            builder: (context) {
              expect(ThemePalettes.blue.localizedName(context), '海霄蓝');
              expect(ThemePalettes.monochrome.localizedName(context), '纸墨灰');
              expect(ThemePalettes.minimal.localizedName(context), '极简蓝');
              expect(ThemePalettes.vermillion.localizedName(context), '朱砂红');
              return const SizedBox();
            },
          ),
        ),
      );

      await tester.pumpWidget(
        Localizations(
          locale: const Locale('en', 'US'),
          delegates: const [DefaultWidgetsLocalizations.delegate],
          child: Builder(
            builder: (context) {
              expect(ThemePalettes.blue.localizedName(context), 'Aether Blue');
              expect(ThemePalettes.monochrome.localizedName(context), 'Frost Gray');
              expect(ThemePalettes.minimal.localizedName(context), 'Minimal Blue');
              expect(ThemePalettes.vermillion.localizedName(context), 'Vermillion');
              return const SizedBox();
            },
          ),
        ),
      );
    });
  });
}

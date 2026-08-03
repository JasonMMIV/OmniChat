import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/features/home/utils/chat_input_button_catalog.dart';

void main() {
  group('chatInputButtonCatalog', () {
    test('ids are unique', () {
      final ids = chatInputButtonCatalog.map((s) => s.id).toSet();
      expect(ids.length, chatInputButtonCatalog.length);
    });

    test('default order covers every catalog button exactly once', () {
      expect(
        chatInputButtonDefaultOrder.length,
        chatInputButtonCatalog.length,
      );
      expect(
        chatInputButtonDefaultOrder.toSet(),
        chatInputButtonCatalog.map((s) => s.id).toSet(),
      );
    });

    test('every id resolves via chatInputButtonSpecById', () {
      for (final spec in chatInputButtonCatalog) {
        expect(chatInputButtonSpecById(spec.id), same(spec));
      }
    });

    test('unknown id resolves to null', () {
      expect(chatInputButtonSpecById('does-not-exist'), isNull);
    });
  });

  group('chatInputButtonEffectiveOrder', () {
    test('empty stored order yields the default catalog order', () {
      expect(
        chatInputButtonEffectiveOrder(const []),
        chatInputButtonDefaultOrder,
      );
    });

    test('applies a custom order and keeps the rest appended', () {
      final result = chatInputButtonEffectiveOrder(
        const ['ocr', 'voice', 'search'],
      );
      expect(result.take(3), ['ocr', 'voice', 'search']);
      final rest = chatInputButtonDefaultOrder
          .where((id) => !{'ocr', 'voice', 'search'}.contains(id))
          .toList();
      expect(result.skip(3).toList(), rest);
    });

    test('always returns every catalog id exactly once', () {
      for (final order in [
        const <String>[],
        const ['model', 'model', 'camera'],
        chatInputButtonDefaultOrder.reversed.toList(),
        const ['unknown-1', 'unknown-2'],
      ]) {
        final result = chatInputButtonEffectiveOrder(order);
        expect(result.toSet().length, result.length);
        expect(
          result.toSet(),
          chatInputButtonCatalog.map((s) => s.id).toSet(),
        );
      }
    });

    test('unknown ids in stored order are dropped', () {
      final result = chatInputButtonEffectiveOrder(
        const ['voice', 'bogus', 'ocr', 'bogus2'],
      );
      expect(result.where((id) => id.startsWith('bogus')), isEmpty);
      expect(result.indexOf('voice'), lessThan(result.indexOf('ocr')));
    });
  });
}

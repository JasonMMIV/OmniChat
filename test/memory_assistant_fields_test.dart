import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/memory_entry.dart';

void main() {
  test('memory fields default to toolDefaultAssistant + llm', () {
    const assistant = Assistant(id: 'a1', name: 'A');
    expect(assistant.memoryWriteScope, MemoryWriteScope.toolDefaultAssistant);
    expect(assistant.memoryDedupeMode, MemoryDedupeMode.llm);
  });

  test('memory fields survive a JSON round-trip', () {
    const assistant = Assistant(
      id: 'a1',
      name: 'A',
      memoryWriteScope: MemoryWriteScope.alwaysGlobal,
      memoryDedupeMode: MemoryDedupeMode.strict,
    );
    final decoded = Assistant.fromJson(
      Map<String, dynamic>.from(assistant.toJson()),
    );
    expect(decoded.memoryWriteScope, MemoryWriteScope.alwaysGlobal);
    expect(decoded.memoryDedupeMode, MemoryDedupeMode.strict);
  });

  test('unknown or missing memory fields fall back defensively', () {
    final decoded = Assistant.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'A',
      'memoryWriteScope': 'nonsense',
    });
    expect(decoded.memoryWriteScope, MemoryWriteScope.toolDefaultAssistant);
    expect(decoded.memoryDedupeMode, MemoryDedupeMode.llm);
  });
}

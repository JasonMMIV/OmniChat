import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/mcp/mcp_tool_prompts.dart';

void main() {
  group('McpToolPrompts.forDefinitions', () {
    test('returns the policy when illustrate is advertised (OpenAI shape)', () {
      final prompt = McpToolPrompts.forDefinitions([
        {
          'type': 'function',
          'function': {'name': 'illustrate', 'description': 'x'},
        },
      ]);
      expect(prompt, isNotNull);
      expect(prompt, contains('## illustrate usage'));
      expect(prompt, contains('decorative filler'));
      expect(prompt, contains('never repeat an image or query'));
    });

    test('returns null when no policy-backed tool is advertised', () {
      expect(
        McpToolPrompts.forDefinitions([
          {
            'type': 'function',
            'function': {'name': 'web_fetch'},
          },
        ]),
        isNull,
      );
    });

    test('returns null for an empty list', () {
      expect(McpToolPrompts.forDefinitions(const []), isNull);
    });

    test('deduplicates repeated definitions', () {
      final prompt = McpToolPrompts.forDefinitions([
        {
          'type': 'function',
          'function': {'name': 'illustrate'},
        },
        {
          'type': 'function',
          'function': {'name': 'illustrate'},
        },
      ])!;
      expect('## illustrate usage'.allMatches(prompt).length, 1);
    });

    test('accepts MCP-style definitions', () {
      final prompt = McpToolPrompts.forDefinitions([
        {'name': 'illustrate'},
      ]);
      expect(prompt, contains('## illustrate usage'));
    });

    test('forRequest injects when illustrate is advertised', () {
      final prompt = McpToolPrompts.forRequest(
        defs: [
          {
            'type': 'function',
            'function': {'name': 'illustrate'},
          },
        ],
        hasBuiltInSearch: false,
      );
      expect(prompt, contains('## illustrate usage'));
    });

    test('forRequest omits the policy when Gemini built-ins are active', () {
      final prompt = McpToolPrompts.forRequest(
        defs: [
          {
            'type': 'function',
            'function': {'name': 'illustrate'},
          },
        ],
        hasBuiltInSearch: true,
      );
      expect(prompt, isNull);
    });

    test('forRequest omits the policy when the tool is not advertised', () {
      final prompt = McpToolPrompts.forRequest(
        defs: [
          {
            'type': 'function',
            'function': {'name': 'web_fetch'},
          },
        ],
        hasBuiltInSearch: false,
      );
      expect(prompt, isNull);
    });

    test('only includes policy-backed tools in a mixed list', () {
      final prompt = McpToolPrompts.forDefinitions([
        {
          'type': 'function',
          'function': {'name': 'web_fetch'},
        },
        {
          'type': 'function',
          'function': {'name': 'illustrate'},
        },
        {
          'type': 'function',
          'function': {'name': 'write_todos'},
        },
      ])!;
      expect(prompt, contains('## illustrate usage'));
      expect(prompt, isNot(contains('web_fetch')));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/core/services/agent/subagent_request.dart';

const _tools = <Map<String, dynamic>>[
  {
    'type': 'function',
    'function': {'name': 'file_read'},
  },
];

void main() {
  group('buildSubagentRoundRequest (P1-6)', () {
    test('same-provider helper inherits the parent wire values', () {
      const launch = SubagentLaunchConfig(
        providerKey: 'p1',
        modelId: 'm1',
        tools: _tools,
        extraHeaders: {'X-Parent': '1'},
        extraBody: {'parent_marker': true},
        maxTokens: 4096,
        temperature: 0.3,
        topP: 0.9,
        thinkingBudget: 2048,
        toolImagesEnabled: true,
      );

      final request = buildSubagentRoundRequest(
        const SubagentRoundRequest(
          messages: [
            {'role': 'user', 'content': 'task'},
          ],
          requestId: 'run-1',
          sessionId: 'session-1',
        ),
        launch: launch,
        providerKey: 'p1',
        modelId: 'm1',
        childTools: _tools,
        runId: 'run-1',
        sessionId: 'session-1',
        webFetchEnabled: true,
        extraBody: launch.extraBody,
      );

      expect(request.providerKey, 'p1');
      expect(request.modelId, 'm1');
      expect(request.tools, _tools);
      expect(request.extraHeaders, {'X-Parent': '1'});
      expect(request.extraBody, {'parent_marker': true});
      expect(request.maxTokens, 4096);
      expect(request.temperature, 0.3);
      expect(request.topP, 0.9);
      expect(request.thinkingBudget, 2048);
      expect(request.toolImagesEnabled, isTrue);
      expect(request.webFetchEnabled, isTrue);
      expect(request.requestId, 'run-1');
      expect(request.sessionId, 'session-1');
    });

    test('the text-only wrap-up has no tools, images, or web fetch', () {
      const launch = SubagentLaunchConfig(
        providerKey: 'p1',
        modelId: 'm1',
        tools: _tools,
        temperature: 0.3,
      );

      final request = buildSubagentRoundRequest(
        const SubagentRoundRequest(
          messages: [
            {'role': 'user', 'content': 'summarise'},
          ],
          tools: null,
          textOnly: true,
        ),
        launch: launch,
        providerKey: 'p1',
        modelId: 'm1',
        childTools: _tools,
        runId: 'run-2',
        sessionId: 'session-2',
        webFetchEnabled: true,
        extraBody: null,
      );

      expect(request.textOnly, isTrue);
      expect(request.tools, isNull);
      expect(request.toolImagesEnabled, isFalse);
      expect(request.webFetchEnabled, isFalse);
      expect(request.requestId, 'run-2_summary');
      expect(request.sessionId, 'session-2');
      // A7: sampling is inherited unchanged.
      expect(request.temperature, 0.3);
    });

    test('cross-provider profile drops headers, body, caps and sampling', () {
      const launch = SubagentLaunchConfig(
        providerKey: 'p1',
        modelId: 'm1',
        tools: _tools,
        extraHeaders: {'X-Parent': '1'},
        extraBody: {'parent_marker': true},
        maxTokens: 4096,
        temperature: 0.3,
        topP: 0.9,
        thinkingBudget: 2048,
        toolImagesEnabled: true,
      );
      const profile = SubagentProfile(
        id: 'bound',
        name: 'Bound',
        description: 'd',
        providerKey: 'p2',
        modelId: 'm2',
      );
      final cross = launch.withProfile(profile);

      final request = buildSubagentRoundRequest(
        const SubagentRoundRequest(
          messages: [
            {'role': 'user', 'content': 'task'},
          ],
        ),
        launch: cross,
        providerKey: 'p2',
        modelId: 'm2',
        childTools: _tools,
        runId: 'run-3',
        sessionId: 'session-3',
        webFetchEnabled: true,
        extraBody: cross.extraBody,
      );

      expect(request.providerKey, 'p2');
      expect(request.modelId, 'm2');
      expect(request.extraHeaders, isNull);
      expect(request.extraBody, isNull);
      expect(request.maxTokens, isNull);
      expect(request.temperature, isNull);
      expect(request.topP, isNull);
      expect(request.thinkingBudget, isNull);
      expect(request.toolImagesEnabled, isTrue);
    });
  });
}

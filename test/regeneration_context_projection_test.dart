import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/features/home/controllers/chat_actions.dart';

/// Regression tests for the Phase-1 edit-and-resend fix.
///
/// Before the fix, `projectMessagesForRegenerationContext` collapsed every
/// version group to its NEWEST version. Edit-and-resend appends the new
/// (edited) user version and selects it BEFORE the regeneration context is
/// assembled, so newest-wins should be equivalent in that flow — but when a
/// caller regenerates from a NON-newest version (edit, then manually switch
/// back to the old version), or when the list carries stale branch messages,
/// the projection must follow the recorded selection, not the raw newest.
ChatMessage _msg(
  String role,
  String content,
  String conversationId, {
  String? id,
  String? groupId,
  int version = 0,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: conversationId,
    groupId: groupId,
    version: version,
  );
}

void main() {
  group('projectMessagesForRegenerationContext (edit-and-resend fix)', () {
    const cid = 'c1';

    test('no versions: projection is unchanged', () {
      final messages = [
        _msg('user', 'hello', cid, id: 'u1'),
        _msg('assistant', 'hi there', cid, id: 'a1'),
      ];
      final out = ChatActions.projectMessagesForRegenerationContext(
        messages: messages,
        lastKeep: 1,
        targetGroupId: 'a1',
      );
      expect(out.map((m) => m.id), ['u1', 'a1']);
    });

    test(
      'keeps [0, lastKeep] and the target assistant version group',
      () {
        final messages = [
          _msg('user', 'first question', cid, id: 'u1'),
          _msg('assistant', 'first answer', cid, id: 'a1'),
          _msg('user', 'second question', cid, id: 'u2'),
          // assistant group 'a2' with two versions (old answer v0 + new
          // placeholder v1)
          _msg('assistant', 'old answer', cid, id: 'a2v0',
              groupId: 'a2', version: 0),
          _msg('assistant', 'new placeholder', cid, id: 'a2v1',
              groupId: 'a2', version: 1),
          _msg('user', 'trailing message to drop', cid, id: 'u3'),
        ];
        final out = ChatActions.projectMessagesForRegenerationContext(
          messages: messages,
          lastKeep: 2,
          targetGroupId: 'a2',
        );
        // u1 / a1 / u2 (+ the target group resolved to ONE selected version
        // downstream; the placeholder itself is appended by the caller).
        expect(out.map((m) => m.id), ['u1', 'a1', 'u2', 'a2v1']);
      },
    );

    test(
      'Phase-1 fix: user version group resolves to the SELECTED version, '
      'not the newest',
      () {
        // Edit-and-resend created v1 (edited text) for group 'u1'; the user
        // then switched the visible version back to v0 (pre-edit text). A
        // regeneration from the current view must assemble context from the
        // SELECTED v0 — a newest-wins projection would resurrect the edited
        // v1 text (the exact regression).
        final messages = [
          _msg('user', 'original question', cid, id: 'u1v0',
              groupId: 'u1', version: 0),
          _msg('user', 'edited question', cid, id: 'u1v1',
              groupId: 'u1', version: 1),
          _msg('assistant', 'some answer', cid, id: 'a1'),
        ];
        final out = ChatActions.projectMessagesForRegenerationContext(
          messages: messages,
          lastKeep: 1,
          targetGroupId: 'a1',
          versionSelections: const {'u1': 0},
        );
        expect(out.map((m) => m.id), ['u1v0', 'a1']);
        expect(out.first.content, 'original question');
      },
    );

    test(
      'selection pointing at the newest version keeps edit-and-resend '
      'behavior (edited text wins)',
      () {
        final messages = [
          _msg('user', 'original question', cid, id: 'u1v0',
              groupId: 'u1', version: 0),
          _msg('user', 'edited question', cid, id: 'u1v1',
              groupId: 'u1', version: 1),
          _msg('assistant', 'some answer', cid, id: 'a1'),
        ];
        final out = ChatActions.projectMessagesForRegenerationContext(
          messages: messages,
          lastKeep: 1,
          targetGroupId: 'a1',
          versionSelections: const {'u1': 1},
        );
        expect(out.map((m) => m.id), ['u1v1', 'a1']);
        expect(out.first.content, 'edited question');
      },
    );

    test(
      'groups with no recorded selection fall back to the newest version '
      '(legacy behavior)',
      () {
        final messages = [
          _msg('user', 'original question', cid, id: 'u1v0',
              groupId: 'u1', version: 0),
          _msg('user', 'edited question', cid, id: 'u1v1',
              groupId: 'u1', version: 1),
          _msg('assistant', 'some answer', cid, id: 'a1'),
        ];
        final out = ChatActions.projectMessagesForRegenerationContext(
          messages: messages,
          lastKeep: 1,
          targetGroupId: 'a1',
        );
        expect(out.map((m) => m.id), ['u1v1', 'a1']);
      },
    );

    test('buildRegenerationMessages forwards the selections and appends the '
        'placeholder', () {
      final messages = [
        _msg('user', 'original question', cid, id: 'u1v0',
            groupId: 'u1', version: 0),
        _msg('user', 'edited question', cid, id: 'u1v1',
            groupId: 'u1', version: 1),
        _msg('assistant', 'some answer', cid, id: 'a1v0',
            groupId: 'a1', version: 0),
      ];
      final placeholder = _msg('assistant', '', cid, id: 'a1v1',
          groupId: 'a1', version: 1);
      final out = ChatActions.buildRegenerationMessages(
        messages: messages,
        lastKeep: 1,
        targetGroupId: 'a1',
        assistantPlaceholder: placeholder,
        versionSelections: const {'u1': 0, 'a1': 1},
      );
      // Selected pre-edit user text + the full target version group (the
      // placeholder appended last) — downstream collapseVersions picks the
      // selected a1 version, which is the new placeholder.
      expect(out.map((m) => m.id), ['u1v0', 'a1v0', 'a1v1']);
      expect(out.first.content, 'original question');
      expect(out.last.id, 'a1v1');
    });
  });
}

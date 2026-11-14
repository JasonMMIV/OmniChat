import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';

void main() {
  group('SubagentProfiles (P1-1)', () {
    test('built-ins are present with stable ids', () {
      expect(SubagentProfiles.builtInIds, {
        'general',
        'explore',
        'reviewer',
        'researcher',
        'coder',
      });
      for (final profile in SubagentProfiles.builtIns) {
        expect(profile.builtIn, isTrue);
        expect(profile.name.trim(), isNotEmpty);
      }
    });

    test('resolve maps empty ids to general and unknown ids to null', () {
      expect(
        SubagentProfiles.resolve('', SubagentProfiles.builtIns)?.id,
        'general',
      );
      expect(
        SubagentProfiles.resolve('explore', SubagentProfiles.builtIns)?.id,
        'explore',
      );
      expect(SubagentProfiles.resolve('nope', const []), isNull);
    });

    test('merge keeps built-ins, appends customs and dedupes', () {
      final merged = SubagentProfiles.mergeWithBuiltIns([
        const SubagentProfile(id: 'custom', name: 'Custom', description: 'd'),
        const SubagentProfile(id: 'custom', name: 'Custom 2', description: 'd'),
        const SubagentProfile(id: 'Bad Id', name: 'Bad', description: 'd'),
      ]);
      expect(
        merged.map((p) => p.id).take(5).toList(),
        SubagentProfiles.builtIns.map((p) => p.id).toList(),
      );
      expect(merged.where((p) => p.id == 'custom'), hasLength(1));
      expect(merged.firstWhere((p) => p.id == 'custom').name, 'Custom 2');
      expect(merged.any((p) => p.id == 'Bad Id'), isFalse);
      expect(merged.length, lessThanOrEqualTo(SubagentProfiles.maxProfiles));
    });

    test('a stored built-in override keeps its builtIn flag', () {
      final merged = SubagentProfiles.mergeWithBuiltIns([
        const SubagentProfile(
          id: 'explore',
          name: 'Explore (edited)',
          description: 'd',
        ),
      ]);
      final explore = merged.firstWhere((p) => p.id == 'explore');
      expect(explore.name, 'Explore (edited)');
      expect(explore.builtIn, isTrue);
    });

    test('read-only profiles refuse write tools but allow reads', () {
      const profile = SubagentProfile(
        id: 'ro',
        name: 'RO',
        description: 'd',
        readOnly: true,
      );
      expect(profile.permits('file_read'), isTrue);
      expect(profile.permits('file_write'), isFalse);
      expect(profile.permits('shell_run'), isFalse);
    });

    test('an allowlist limits the child tools', () {
      const profile = SubagentProfile(
        id: 'list',
        name: 'List',
        description: 'd',
        allowedTools: {'file_read', 'file_grep'},
      );
      expect(profile.permits('file_read'), isTrue);
      expect(profile.permits('file_write'), isFalse);
    });

    test('validate rejects half a model pair and bad budgets', () {
      const base = SubagentProfile(
        id: 'x',
        name: 'X',
        description: 'd',
        providerKey: 'openai',
      );
      expect(
        SubagentProfiles.validate(base, isNew: true),
        'model_pair_required',
      );
      expect(
        SubagentProfiles.validate(
          const SubagentProfile(
            id: 'x',
            name: 'X',
            description: 'd',
            maxSteps: 41,
          ),
          isNew: true,
        ),
        'max_steps_out_of_range',
      );
      expect(
        SubagentProfiles.validate(
          const SubagentProfile(
            id: 'x',
            name: 'X',
            description: 'd',
            providerKey: 'openai',
            modelId: 'gpt-4o',
          ),
          isNew: true,
        ),
        isNull,
      );
    });

    test('followsConversationModel is true unless both fields are set', () {
      const follows = SubagentProfile(id: 'a', name: 'A', description: 'd');
      const bound = SubagentProfile(
        id: 'b',
        name: 'B',
        description: 'd',
        providerKey: 'openai',
        modelId: 'gpt-4o',
      );
      expect(follows.followsConversationModel, isTrue);
      expect(bound.followsConversationModel, isFalse);
    });

    test('read-only blocks every write tool, including append and mkdir', () {
      const profile = SubagentProfile(
        id: 'ro',
        name: 'RO',
        description: 'd',
        readOnly: true,
      );
      for (final tool in <String>[
        'file_write',
        'file_append',
        'file_edit',
        'file_patch',
        'file_delete',
        'file_move',
        'file_copy',
        'file_mkdir',
        'file_create_pdf',
        'file_extract_zip',
        'shell_run',
        'shell_exec',
        'memory_update',
        'memory_edit',
        'memory_delete',
        'create_memory',
        'edit_memory',
        'delete_memory',
        'write_todos',
      ]) {
        expect(profile.permits(tool), isFalse, reason: tool);
      }
      expect(profile.permits('file_read'), isTrue);
      expect(profile.permits('memory_read'), isTrue);
    });

    test('the read-only set covers every declared write tool', () {
      expect(
        subagentWriteToolNames,
        containsAll(<String>[
          'file_write',
          'file_append',
          'file_edit',
          'file_patch',
          'file_delete',
          'file_move',
          'file_copy',
          'file_mkdir',
          'file_create_pdf',
          'file_extract_zip',
          'shell_run',
          'shell_exec',
          'memory_update',
          'memory_edit',
          'memory_delete',
          'create_memory',
          'edit_memory',
          'delete_memory',
          'write_todos',
        ]),
      );
    });

    test('explore excludes MCP tools; coder keeps the full child list', () {
      final parent = <Map<String, dynamic>>[
        for (final name in <String>[
          'file_read',
          'file_write',
          'shell_run',
          'mcp_playwright_click',
          spawnSubagentToolName,
        ])
          {
            'type': 'function',
            'function': {'name': name},
          },
      ];
      final explore = SubagentProfiles.resolve(
        'explore',
        SubagentProfiles.builtIns,
      )!;
      final coder = SubagentProfiles.resolve(
        'coder',
        SubagentProfiles.builtIns,
      )!;
      List<String> names(SubagentProfile p) => subagentChildTools(
        parent,
        profile: p,
      ).map((d) => ((d['function'] as Map)['name']).toString()).toList();

      expect(names(explore), <String>['file_read']);
      expect(names(coder), <String>[
        'file_read',
        'file_write',
        'shell_run',
        'mcp_playwright_click',
      ]);
    });

    test('the system prompt carries profile instructions', () {
      final explore = SubagentProfiles.resolve(
        'explore',
        SubagentProfiles.builtIns,
      )!;
      final prompt = buildSubagentSystemPrompt(
        profile: explore,
        brief: 'workspace=/tmp',
      );
      expect(prompt, contains('[Profile: Explore]'));
      expect(prompt, contains(explore.instructions));
      expect(prompt, contains('[Workspace brief]'));
    });

    test('stored read-only profiles drop stale write tools on load', () {
      final profile = SubagentProfile.tryFromJson(<String, dynamic>{
        'id': 'ro',
        'name': 'RO',
        'description': 'd',
        'readOnly': true,
        'allowedTools': <String>['file_read', 'file_append', 'file_write'],
      });
      expect(profile, isNotNull);
      expect(profile!.allowedTools, contains('file_read'));
      expect(profile.allowedTools, isNot(contains('file_append')));
      expect(profile.allowedTools, isNot(contains('file_write')));
      expect(profile.permits('file_read'), isTrue);
      expect(profile.permits('file_append'), isFalse);
    });

    test('a new profile cannot claim a built-in id', () {
      expect(
        SubagentProfiles.validate(
          const SubagentProfile(
            id: 'general',
            name: 'General copy',
            description: 'd',
          ),
          isNew: true,
        ),
        'built_in_id',
      );
      expect(
        SubagentProfiles.validate(
          const SubagentProfile(
            id: 'general',
            name: 'General override',
            description: 'd',
          ),
          isNew: false,
        ),
        isNull,
      );
    });
  });
}

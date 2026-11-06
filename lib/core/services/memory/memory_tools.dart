/// Memory tool surface (V1 tool names) and their JSON schemas.
///
/// Reference: `docs/記憶功能改善實作計畫(已實作).md` M2-4. Pure constants and schema
/// builders so the shape can be unit-tested without a Flutter binding.
class MemoryTools {
  const MemoryTools._();

  static const String read = 'memory_read';
  static const String update = 'memory_update';
  static const String edit = 'memory_edit';
  static const String delete = 'memory_delete';

  /// Legacy names stay resolvable in the handler (history replay safety) but
  /// are never advertised to the model again.
  static const String legacyCreate = 'create_memory';
  static const String legacyEdit = 'edit_memory';
  static const String legacyDelete = 'delete_memory';

  static const Set<String> names = <String>{read, update, edit, delete};

  static const Set<String> legacyNames = <String>{
    legacyCreate,
    legacyEdit,
    legacyDelete,
  };

  static bool isMemoryTool(String name) =>
      names.contains(name) || legacyNames.contains(name);

  static const String sensitiveNote =
      'Never store sensitive attributes: ethnicity, religion, sexual '
      'orientation, political stance, sexual life, criminal record.';

  static List<String> typeNames() =>
      const <String>['identity', 'workflow', 'voice', 'instruction'];

  /// [allowScopeParameter] is true when the assistant write policy is one of
  /// the `toolDefault*` modes (M2-4); otherwise the model must not choose.
  static List<Map<String, dynamic>> definitions({
    required bool allowScopeParameter,
  }) {
    final scopeProperty = allowScopeParameter
        ? <String, dynamic>{
            'type': 'string',
            'enum': <String>['global', 'assistant'],
            'description':
                'global = applies to every assistant; assistant = this '
                'assistant only. Omit to use the default write scope.',
          }
        : null;

    return <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': read,
          'description':
              'List long-term memory entries with pagination. Only needed '
              'when the injected memory block is summarized.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'limit': <String, dynamic>{
                'type': 'integer',
                'description': 'Page size, 1-100. Default 50.',
              },
              'offset': <String, dynamic>{
                'type': 'integer',
                'description': 'Number of entries to skip. Default 0.',
              },
              'type': <String, dynamic>{
                'type': 'string',
                'enum': typeNames(),
                'description': 'Optional type filter.',
              },
            },
          },
        },
      },
      <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': update,
          'description':
              'Add one long-term memory entry. Exact duplicates are skipped. '
              '$sensitiveNote',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'type': <String, dynamic>{
                'type': 'string',
                'enum': typeNames(),
                'description':
                    'identity = user facts; workflow = work/projects; '
                    'voice = tone/style; instruction = standing orders.',
              },
              'content': <String, dynamic>{
                'type': 'string',
                'description':
                    'Self-contained memory text, max 2000 characters. Use '
                    'absolute dates.',
              },
              if (scopeProperty != null) 'scope': scopeProperty,
            },
            'required': <String>['type', 'content'],
          },
        },
      },
      <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': edit,
          'description':
              'Replace the content of one memory entry by id. Use only for '
              'outdated or incorrect entries.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'id': <String, dynamic>{
                'type': 'string',
                'description': 'Memory id, for example mem_1a2b3c4d.',
              },
              'content': <String, dynamic>{
                'type': 'string',
                'description': 'New memory text, max 2000 characters.',
              },
            },
            'required': <String>['id', 'content'],
          },
        },
      },
      <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': delete,
          'description':
              'Archive one memory entry by id (soft delete; the user can '
              'restore it in settings).',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'id': <String, dynamic>{
                'type': 'string',
                'description': 'Memory id, for example mem_1a2b3c4d.',
              },
            },
            'required': <String>['id'],
          },
        },
      },
    ];
  }
}

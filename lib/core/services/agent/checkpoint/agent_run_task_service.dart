import 'agent_run_checkpoint_store.dart';
import 'agent_run_task.dart';

/// Conversation identity used by the task list.
///
/// `known: false` means the lookup could not answer (for example, chat storage
/// is still initializing). It must never be treated as a deleted conversation;
/// `exists: false` is reserved for a confirmed missing row.
class AgentRunConversationInfo {
  const AgentRunConversationInfo({
    required this.exists,
    this.title,
    this.known = true,
  });

  const AgentRunConversationInfo.missing()
    : exists = false,
      title = null,
      known = true;

  const AgentRunConversationInfo.unknown()
    : exists = true,
      title = null,
      known = false;

  final bool exists;
  final String? title;
  final bool known;
}

typedef AgentRunConversationResolver =
    AgentRunConversationInfo Function(String conversationId);

/// Reads the P2-1 journal into the P3-3 "unfinished tasks" list.
///
/// This is deliberately a read-time projection: no second index is written.
/// Stale checkpoints (conversation no longer exists) are deleted as they are
/// found, matching the startup banner's cleanup semantics.
class AgentRunTaskService {
  AgentRunTaskService({
    required this.resolveConversation,
    AgentRunCheckpointStore? store,
  }) : _store = store ?? AgentRunCheckpointStore.instance;

  final AgentRunConversationResolver resolveConversation;
  final AgentRunCheckpointStore _store;

  Future<List<AgentRunTask>> load({
    Set<String> activeConversationIds = const <String>{},
  }) async {
    final checkpoints = await _store.listAll();
    final tasks = <AgentRunTask>[];
    for (final checkpoint in checkpoints) {
      AgentRunConversationInfo info;
      try {
        info = resolveConversation(checkpoint.conversationId);
      } catch (_) {
        // A lookup failure is "unknown", never "deleted": keep the task so a
        // transient storage problem cannot silently discard a resume point.
        info = const AgentRunConversationInfo.unknown();
      }
      if (info.known && !info.exists) {
        try {
          await _store.delete(checkpoint.conversationId);
        } catch (_) {
          // A stale row that cannot be deleted must not hide every other
          // valid checkpoint behind a single storage failure.
        }
        continue;
      }
      tasks.add(
        AgentRunTask.fromCheckpoint(
          checkpoint,
          conversationTitle: info.title,
          isActive: activeConversationIds.contains(checkpoint.conversationId),
        ),
      );
    }
    tasks.sort(AgentRunTask.compareNewestFirst);
    return tasks;
  }
}

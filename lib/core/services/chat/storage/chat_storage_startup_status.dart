import 'package:flutter/foundation.dart';

/// Observable phases of `ChatService.init()` (§9.6).
///
/// The UI uses this to keep chat widgets away from a store that is still
/// migrating and to explain what is happening during the one-time cutover.
enum ChatStorageInitPhase {
  idle,
  preparing,
  checking,
  backingUp,
  migrating,
  validating,
  opening,
  ready,
  failed,

  /// The gate found a recorded installation whose database is missing. The
  /// app must show an explicit restore/reset decision; it must not silently
  /// recreate an empty database or fall back without asking.
  restoreRequired,
}

/// One immutable snapshot of startup progress.
///
/// Counts are intentionally nullable: they are only known after the importer
/// has produced its destination counts. The stage key is the raw stage name
/// reported by `LegacyHiveImporter` so the presentation layer can localize it
/// without baking UI strings into the storage layer.
@immutable
class ChatStorageInitStatus {
  const ChatStorageInitStatus({
    this.phase = ChatStorageInitPhase.idle,
    this.stage,
    this.conversations,
    this.messages,
    this.parts,
    this.quarantined,
    this.message,
    this.isLegacyFallback = false,
    this.canRetry = false,
  });

  final ChatStorageInitPhase phase;
  final String? stage;
  final int? conversations;
  final int? messages;
  final int? parts;
  final int? quarantined;

  /// User-facing detail for a fallback or failure. Migration progress uses
  /// [stage] instead so it stays localizable.
  final String? message;

  /// True when SQLite could not be admitted and the legacy Hive store is
  /// serving the app for this release (§9.6 step 5).
  final bool isLegacyFallback;

  /// True after initialization failed; the retry action is safe because no
  /// data was deleted by the gate.
  final bool canRetry;

  bool get isBusy =>
      phase == ChatStorageInitPhase.preparing ||
      phase == ChatStorageInitPhase.checking ||
      phase == ChatStorageInitPhase.backingUp ||
      phase == ChatStorageInitPhase.migrating ||
      phase == ChatStorageInitPhase.validating ||
      phase == ChatStorageInitPhase.opening;

  bool get hasFailed => phase == ChatStorageInitPhase.failed;

  bool get isRestoreRequired => phase == ChatStorageInitPhase.restoreRequired;

  bool get hasCounts => conversations != null || messages != null;

  @override
  bool operator ==(Object other) {
    return other is ChatStorageInitStatus &&
        other.phase == phase &&
        other.stage == stage &&
        other.conversations == conversations &&
        other.messages == messages &&
        other.parts == parts &&
        other.quarantined == quarantined &&
        other.message == message &&
        other.isLegacyFallback == isLegacyFallback &&
        other.canRetry == canRetry;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    stage,
    conversations,
    messages,
    parts,
    quarantined,
    message,
    isLegacyFallback,
    canRetry,
  );

  ChatStorageInitStatus copyWith({
    ChatStorageInitPhase? phase,
    String? stage,
    int? conversations,
    int? messages,
    int? parts,
    int? quarantined,
    String? message,
    bool? isLegacyFallback,
    bool? canRetry,
    bool clearStage = false,
    bool clearMessage = false,
    bool clearCounts = false,
  }) {
    return ChatStorageInitStatus(
      phase: phase ?? this.phase,
      stage: clearStage ? null : (stage ?? this.stage),
      conversations: clearCounts ? null : (conversations ?? this.conversations),
      messages: clearCounts ? null : (messages ?? this.messages),
      parts: clearCounts ? null : (parts ?? this.parts),
      quarantined: clearCounts ? null : (quarantined ?? this.quarantined),
      message: clearMessage ? null : (message ?? this.message),
      isLegacyFallback: isLegacyFallback ?? this.isLegacyFallback,
      canRetry: canRetry ?? this.canRetry,
    );
  }
}

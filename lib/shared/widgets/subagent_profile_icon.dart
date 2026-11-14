import 'package:flutter/material.dart';

import '../../core/services/agent/subagent_profiles.dart';
import '../../icons/lucide_adapter.dart';

/// Role icon for a subagent profile.
///
/// The umbrella subagent identity is `UserRoundGroup`; each built-in role
/// keeps a distinct glyph so the Add-ons menu and the settings list stay
/// recognizable at a glance. Custom profiles use `ContactRound`.
IconData subagentProfileIcon(String id) {
  switch (id) {
    case 'general':
      return Lucide.UserRoundCheck;
    case 'explore':
      return Lucide.Compass;
    case 'reviewer':
      return Lucide.Eye;
    case 'researcher':
      return Lucide.UserRoundSearch;
    case 'coder':
      return Lucide.Code;
    default:
      return Lucide.ContactRound;
  }
}

/// [subagentProfileIcon] as a widget.
///
/// Read-only profiles use the same role icon as writable ones; read-only
/// state is conveyed by the subtitle text, not by a lock badge.
class SubagentProfileIcon extends StatelessWidget {
  const SubagentProfileIcon({
    super.key,
    required this.profile,
    this.size = 16,
    this.color,
  });

  final SubagentProfile profile;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(subagentProfileIcon(profile.id), size: size, color: color);
  }
}

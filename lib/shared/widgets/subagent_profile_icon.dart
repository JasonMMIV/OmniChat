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

/// [subagentProfileIcon] plus a small lock badge for read-only profiles.
///
/// The icon occupies exactly [size] so read-only and writable rows keep their
/// text aligned; the badge overflows into the row's existing gap.
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
    final cs = Theme.of(context).colorScheme;
    final iconColor = color ?? cs.primary;
    final badgeSize = size * 0.55;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(subagentProfileIcon(profile.id), size: size, color: iconColor),
          if (profile.readOnly)
            Positioned(
              right: -size * 0.18,
              bottom: -size * 0.12,
              child: Container(
                width: badgeSize,
                height: badgeSize,
                decoration: BoxDecoration(
                  color: cs.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: iconColor.withValues(alpha: 0.35),
                    width: 0.8,
                  ),
                ),
                child: Icon(
                  Lucide.Lock,
                  size: badgeSize * 0.68,
                  color: iconColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

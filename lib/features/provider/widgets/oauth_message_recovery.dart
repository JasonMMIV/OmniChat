// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// In-chat recovery card for a subscription account whose credentials stopped
// working. Re-login is manual and the failed turn is NEVER re-sent
// automatically (plan M4/C16): the user signs in, then presses Retry.
//
// Visibility is keyed on [OAuthRecoveryRegistry] (per message), never on the
// localized notice text, so switching the app language cannot orphan the card.
// A background 401 from usage / model sync does not mark a message, so it
// cannot put a Retry affordance under an already-successful answer.

import 'package:flutter/material.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/auth/oauth_recovery_registry.dart';
import '../../../core/services/auth/provider_oauth_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import 'oauth_login_flow.dart';

class OAuthMessageRecovery extends StatefulWidget {
  const OAuthMessageRecovery({
    super.key,
    required this.messageId,
    required this.config,
    this.onRetry,
    this.service,
    this.registry,
  });

  final String messageId;
  final ProviderConfig config;

  /// Regenerates the failed turn. Null when the call site has no retry action.
  final VoidCallback? onRetry;

  /// Test seams; production uses the app-wide singletons.
  final ProviderOAuthService? service;
  final OAuthRecoveryRegistry? registry;

  @override
  State<OAuthMessageRecovery> createState() => _OAuthMessageRecoveryState();
}

class _OAuthMessageRecoveryState extends State<OAuthMessageRecovery> {
  bool _busy = false;

  ProviderOAuthService get _service =>
      widget.service ?? ProviderOAuthService.instance;

  OAuthRecoveryRegistry get _registry =>
      widget.registry ?? OAuthRecoveryRegistry.instance;

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await showOAuthLoginSheet(
        context: context,
        config: widget.config,
        service: _service,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _retry() {
    // Keep the registry entry: Retry creates a new version, and switching back
    // to this failed version must still offer the manual retry. A new auth
    // failure marks its own (new) message.
    widget.onRetry?.call();
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    final registry = _registry;
    // Nested builders avoid allocating a merged Listenable on every build.
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => AnimatedBuilder(
        animation: registry,
        builder: (context, _) {
          if (widget.config.oauthProvider == null ||
              !registry.isFailed(widget.messageId)) {
            return const SizedBox.shrink();
          }

          final l10n = AppLocalizations.of(context)!;
          final cs = Theme.of(context).colorScheme;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final warn = isDark
              ? const Color(0xFFF5A524)
              : const Color(0xFFB25E00);
          final loginRequired = service.isLoginRequired(widget.config.id);
          final ready = !loginRequired;

          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: warn.withValues(alpha: isDark ? 0.12 : 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: warn.withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        ready ? Lucide.CheckCircle : Lucide.KeyRound,
                        size: 18,
                        color: ready ? Colors.green : warn,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          ready
                              ? l10n.oauthChatRecoveryReadyTitle
                              : l10n.oauthLoginRequired,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: ready ? Colors.green : warn,
                          ),
                        ),
                      ),
                      if (ready)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            l10n.oauthConnected,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ready
                        ? l10n.oauthChatRecoveryDone
                        : l10n.oauthChatRecoveryBody(widget.config.name),
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: cs.onSurface.withValues(alpha: 0.78),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (ready)
                    FilledButton.icon(
                      onPressed: widget.onRetry == null ? null : _retry,
                      icon: const Icon(Lucide.RefreshCw, size: 16),
                      label: Text(l10n.oauthChatRecoveryRetry),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _busy ? null : _signIn,
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Lucide.KeyRound, size: 16),
                      label: Text(l10n.oauthChatRecoverySignIn),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

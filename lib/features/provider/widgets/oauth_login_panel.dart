// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Interactive sign-in panel shared by the "Accounts" tab of Add Provider and by
// the account detail page. The layout follows Kelivo: provider rows with an
// inline sign-in button, then a centered waiting state while the provider page
// is open. All protocol work lives in the auth adapters; this widget only
// renders controller state and forwards manual codes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/provider_oauth.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/auth/oauth_errors.dart';
import '../../../core/services/auth/provider_oauth_adapter.dart';
import '../../../core/services/auth/provider_oauth_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../theme/app_font_weights.dart';
import 'provider_avatar.dart';

typedef OAuthLoginCompleted =
    Future<void> Function(
      ProviderOAuthCredentials credentials,
      OAuthProvider provider,
    );

/// Localized "which step failed" text (plan O3). The raw server message stays
/// authoritative; the stage label is prefixed so the user sees both.
String describeOAuthLoginFailure(AppLocalizations? l10n, OAuthException e) {
  final transportText = switch (e.transportFailure) {
    OAuthFailureTransport.dns => l10n?.oauthTransportDns,
    OAuthFailureTransport.tls => l10n?.oauthTransportTls,
    OAuthFailureTransport.proxy => l10n?.oauthTransportProxy,
    OAuthFailureTransport.connection => l10n?.oauthTransportConnection,
    OAuthFailureTransport.connectionTimeout =>
      l10n?.oauthTransportConnectionTimeout,
    OAuthFailureTransport.sendTimeout => l10n?.oauthTransportSendTimeout,
    OAuthFailureTransport.receiveTimeout => l10n?.oauthTransportReceiveTimeout,
    OAuthFailureTransport.requestTimeout => l10n?.oauthTransportRequestTimeout,
    OAuthFailureTransport.unknown => null,
    null => null,
  };
  final message = transportText == null
      ? e.message
      : '${e.message} ($transportText)';
  final stageText = switch (e.stage) {
    OAuthStage.requestDeviceCode => l10n?.oauthStageRequestDeviceCode,
    OAuthStage.waitDeviceAuthorization =>
      l10n?.oauthStageWaitDeviceAuthorization,
    OAuthStage.prepareBrowser => l10n?.oauthStagePrepareBrowser,
    OAuthStage.browserAuthorization => l10n?.oauthStageBrowserAuthorization,
    OAuthStage.exchangeToken => l10n?.oauthStageExchangeToken,
    OAuthStage.refreshToken => l10n?.oauthStageRefreshToken,
    null => null,
  };
  if (stageText == null || stageText.isEmpty) return message;
  return '$stageText: $message';
}

class OAuthLoginPanel extends StatefulWidget {
  const OAuthLoginPanel({
    super.key,
    this.provider,
    this.providerId,
    required this.onSignedIn,
    this.previousDeviceId,
    this.networkConfig,
    this.compact = false,
  });

  /// Null renders every provider as a selectable row (the Add Provider tab).
  final OAuthProvider? provider;
  final String? providerId;
  final OAuthLoginCompleted onSignedIn;
  final String? previousDeviceId;

  /// Existing provider whose proxy settings should be used for login traffic.
  final ProviderConfig? networkConfig;
  final bool compact;

  @override
  State<OAuthLoginPanel> createState() => _OAuthLoginPanelState();
}

class _OAuthLoginPanelState extends State<OAuthLoginPanel> {
  final TextEditingController _manual = TextEditingController();
  OAuthLoginController? _controller;
  OAuthProvider? _activeProvider;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller?.cancel();
    _manual.dispose();
    super.dispose();
  }

  Future<bool> _launch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    // OAuth pages are always HTTPS (loopback callbacks are never opened here);
    // refuse other schemes so a malformed verification URL cannot launch an
    // arbitrary local handler.
    final loopback =
        uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
    if (uri.scheme != 'https' && !loopback) return false;
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
    return false;
  }

  Future<void> _start(OAuthProvider provider) async {
    if (_busy) return;
    final controller = OAuthLoginController(provider: provider)
      ..onChanged = () {
        if (mounted) setState(() {});
      };
    final usesWidgetContext = widget.provider == provider;
    setState(() {
      _busy = true;
      _error = null;
      _activeProvider = provider;
      _controller = controller;
    });
    try {
      final credentials = await ProviderOAuthService.instance.login(
        provider: provider,
        providerId: widget.providerId ?? provider.wireName,
        controller: controller,
        previousDeviceId: usesWidgetContext ? widget.previousDeviceId : null,
        networkConfig: usesWidgetContext ? widget.networkConfig : null,
        launchBrowser: _launch,
      );
      // A cancel followed by a new attempt replaces the controller; the old
      // attempt's completion must not touch the new one's UI state.
      if (!mounted || !identical(_controller, controller)) return;
      await widget.onSignedIn(credentials, provider);
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _busy = false;
        _activeProvider = null;
        _controller = null;
      });
    } on OAuthException catch (e) {
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _busy = false;
        _activeProvider = null;
        _controller = null;
        // Cancelling is a user action, not a failure worth reporting back.
        _error = e is OAuthLoginCancelled
            ? null
            : describeOAuthLoginFailure(
                mounted ? AppLocalizations.of(context) : null,
                e,
              );
      });
    } catch (e) {
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _busy = false;
        _activeProvider = null;
        _controller = null;
        _error = '$e';
      });
    }
  }

  void _cancel() {
    final controller = _controller;
    _controller = null;
    _activeProvider = null;
    controller?.cancel();
    setState(() {
      _busy = false;
      _error = null;
    });
  }

  String _serviceLabel(OAuthProvider provider) {
    return switch (provider) {
      OAuthProvider.chatgpt => 'Codex',
      OAuthProvider.claude => 'Pro / Max',
      OAuthProvider.grok => 'xAI',
      OAuthProvider.kimi => 'Kimi Code',
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = _activeProvider;
    final controller = _controller;

    if (_busy && active != null) {
      return _buildWaiting(l10n, cs, active, controller);
    }

    final providers = widget.provider == null
        ? OAuthProvider.values
        : <OAuthProvider>[widget.provider!];
    final configs = context
        .watch<SettingsProvider>()
        .providerConfigs
        .values
        .toList(growable: false);
    final cardColor = isDark ? Colors.white10 : const Color(0xFFF7F7F9);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.25)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < providers.length; i++) ...[
                _providerRow(l10n, cs, providers[i], configs),
                if (i < providers.length - 1)
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: cs.outlineVariant.withOpacity(0.18),
                  ),
              ],
            ],
          ),
        ),
        if ((_error ?? '').isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '${l10n.oauthSignInFailed}: $_error',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.error),
          ),
        ],
        if (!widget.compact) ...[
          const SizedBox(height: 10),
          Text(
            l10n.oauthRiskNotice,
            style: TextStyle(
              fontSize: 11,
              height: 1.45,
              color: cs.onSurface.withOpacity(0.5),
            ),
          ),
        ],
      ],
    );
  }

  Widget _providerRow(
    AppLocalizations l10n,
    ColorScheme cs,
    OAuthProvider provider,
    List<ProviderConfig> configs,
  ) {
    final service = ProviderOAuthService.instance;
    final accounts = configs
        .where((cfg) => cfg.oauthProvider == provider)
        .toList(growable: false);
    final signedIn = accounts
        .where(
          (cfg) =>
              cfg.oauthCredentialsValue != null &&
              !service.isLoginRequired(cfg.id),
        )
        .length;
    final needsLogin =
        widget.provider != null && widget.previousDeviceId != null;
    final status = signedIn > 0
        ? l10n.oauthSignedIn
        : needsLogin
        ? l10n.oauthLoginRequired
        : null;
    final statusColor = signedIn > 0 ? Colors.green : Colors.orange;
    final addAnother = signedIn > 0;
    final actionLabel = addAnother
        ? l10n.oauthAddAnotherAccount
        : needsLogin
        ? l10n.oauthChatRecoverySignIn
        : l10n.oauthSignInButton;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(
        children: [
          ProviderAvatar(
            providerKey: provider.wireName,
            displayName: provider.displayName,
            size: 36,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _serviceLabel(provider),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.6),
                      ),
                    ),
                    if (status != null) _statusPill(status, statusColor),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          IosTileButton(
            label: actionLabel,
            icon: addAnother ? Icons.add : Icons.login,
            backgroundColor: addAnother ? null : cs.primary,
            fontSize: 13,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            onTap: () => _start(provider),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: AppFontWeights.semibold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildWaiting(
    AppLocalizations l10n,
    ColorScheme cs,
    OAuthProvider provider,
    OAuthLoginController? controller,
  ) {
    final code = controller?.userCode;
    final verificationUrl = controller?.verificationUrl;
    final manualMode = controller?.manualMode == true;
    final authorizeUrl = controller?.authorizeUrl;
    final manualError = controller?.manualError;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ProviderAvatar(
              providerKey: provider.wireName,
              displayName: provider.displayName,
              size: 48,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            provider.displayName,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, fontWeight: AppFontWeights.semibold),
          ),
          const SizedBox(height: 8),
          Text(
            _statusText(l10n, controller),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: cs.onSurface.withOpacity(0.6),
            ),
          ),
          if (code != null) ...[
            const SizedBox(height: 20),
            Text(
              l10n.oauthDeviceCodeHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              code,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: AppFontWeights.semibold,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 12),
            IosTileButton(
              label: l10n.oauthCopyCode,
              icon: Lucide.Copy,
              onTap: () => Clipboard.setData(ClipboardData(text: code)),
            ),
            if ((verificationUrl ?? '').isNotEmpty) ...[
              const SizedBox(height: 12),
              IosTileButton(
                label: l10n.oauthOpenDevicePage,
                icon: Lucide.ExternalLink,
                onTap: () => _launch(verificationUrl!),
              ),
            ],
          ],
          if (manualMode) ...[
            const SizedBox(height: 20),
            Text(
              l10n.oauthManualHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            IosFormTextField(
              label: l10n.oauthAuthorizationCode,
              controller: _manual,
              hintText: l10n.oauthManualHint,
              maxLines: 2,
            ),
            if ((manualError ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                manualError!,
                style: TextStyle(fontSize: 12, color: cs.error),
              ),
            ],
            const SizedBox(height: 12),
            IosTileButton(
              label: l10n.oauthManualSubmit,
              icon: Lucide.Check,
              onTap: () {
                final text = _manual.text.trim();
                if (text.isEmpty) return;
                controller?.submitManualCode(text);
                _manual.clear();
              },
            ),
            if ((authorizeUrl ?? '').isNotEmpty) ...[
              const SizedBox(height: 12),
              IosTileButton(
                label: l10n.oauthOpenBrowserAgain,
                icon: Lucide.ExternalLink,
                onTap: () => _launch(authorizeUrl!),
              ),
            ],
          ] else if ((authorizeUrl ?? '').isNotEmpty) ...[
            const SizedBox(height: 20),
            IosTileButton(
              label: l10n.oauthOpenBrowserAgain,
              icon: Lucide.ExternalLink,
              onTap: () => _launch(authorizeUrl!),
            ),
          ],
          const SizedBox(height: 16),
          IosTileButton(
            label: l10n.oauthCancel,
            icon: Lucide.X,
            foregroundColor: cs.error,
            onTap: _cancel,
          ),
        ],
      ),
    );
  }

  String _statusText(AppLocalizations l10n, OAuthLoginController? controller) {
    switch (controller?.status) {
      case 'device_start':
        return l10n.oauthDeviceRequesting;
      case 'device':
        return l10n.oauthDeviceWaiting;
      case 'manual':
        return l10n.oauthManualWaiting;
      case 'exchanging':
        return l10n.oauthExchanging;
      case 'waiting':
      default:
        return l10n.oauthWaitingBrowser;
    }
  }
}

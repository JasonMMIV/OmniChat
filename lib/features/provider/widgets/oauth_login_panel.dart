// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Interactive sign-in panel shared by the "Account" tab of Add Provider and by
// the account detail page. All protocol work lives in the auth adapters; this
// widget only renders controller state and forwards the manual code.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/provider_oauth.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/auth/oauth_errors.dart';
import '../../../core/services/auth/provider_oauth_adapter.dart';
import '../../../core/services/auth/provider_oauth_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tile_button.dart';

class OAuthLoginPanel extends StatefulWidget {
  const OAuthLoginPanel({
    super.key,
    required this.provider,
    required this.providerId,
    required this.onSignedIn,
    this.previousDeviceId,
    this.networkConfig,
    this.compact = false,
  });

  final OAuthProvider provider;
  final String providerId;
  final void Function(ProviderOAuthCredentials credentials) onSignedIn;
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
  bool _busy = false;
  String? _error;

  bool get _killSwitchOff => !ProviderOAuthService.instance.enabled;

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

  Future<void> _start() async {
    if (_busy || _killSwitchOff) return;
    final controller = OAuthLoginController(provider: widget.provider)
      ..onChanged = () {
        if (mounted) setState(() {});
      };
    setState(() {
      _busy = true;
      _error = null;
      _controller = controller;
    });
    try {
      final credentials = await ProviderOAuthService.instance.login(
        provider: widget.provider,
        providerId: widget.providerId,
        controller: controller,
        previousDeviceId: widget.previousDeviceId,
        networkConfig: widget.networkConfig,
        launchBrowser: _launch,
      );
      // A cancel followed by a new attempt replaces the controller; the old
      // attempt's completion must not touch the new one's UI state.
      if (!mounted || !identical(_controller, controller)) return;
      setState(() => _busy = false);
      widget.onSignedIn(credentials);
    } on OAuthException catch (e) {
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _busy = false;
        // Cancelling is a user action, not a failure worth reporting back.
        _error = e is OAuthLoginCancelled ? null : e.message;
      });
    } catch (e) {
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  void _cancel() {
    final controller = _controller;
    _controller = null;
    controller?.cancel();
    setState(() {
      _busy = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = _controller;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          switch (widget.provider) {
            OAuthProvider.chatgpt => l10n.oauthChatGptIntro,
            OAuthProvider.claude => l10n.oauthClaudeIntro,
            OAuthProvider.grok => l10n.oauthGrokIntro,
            OAuthProvider.kimi => l10n.oauthKimiIntro,
          },
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: cs.onSurface.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 12),
        if (_killSwitchOff)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              l10n.oauthDisabledNotice,
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          )
        else if (!_busy)
          SizedBox(
            width: double.infinity,
            child: IosTileButton(
              icon: Icons.login,
              label: l10n.oauthSignInButton,
              backgroundColor: cs.primary,
              onTap: _start,
            ),
          ),
        if (_busy) ...[
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusText(l10n, controller),
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.75),
                  ),
                ),
              ),
            ],
          ),
          if (controller?.userCode != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.oauthDeviceCodeHint,
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    controller!.userCode!,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  if ((controller.verificationUrl ?? '').isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _launch(controller.verificationUrl!),
                      child: Text(l10n.oauthOpenDevicePage),
                    ),
                ],
              ),
            ),
          ],
          if (controller?.manualMode == true) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _manual,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: l10n.oauthManualHint,
                isDense: true,
                filled: true,
                fillColor: isDark ? Colors.white10 : Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withOpacity(0.4),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withOpacity(0.4),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
              ),
            ),
            if ((controller?.manualError ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                controller!.manualError!,
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    final text = _manual.text.trim();
                    if (text.isEmpty) return;
                    controller?.submitManualCode(text);
                    _manual.clear();
                  },
                  child: Text(l10n.oauthManualSubmit),
                ),
                if ((controller?.authorizeUrl ?? '').isNotEmpty)
                  TextButton(
                    onPressed: () => _launch(controller!.authorizeUrl!),
                    child: Text(l10n.oauthOpenBrowserAgain),
                  ),
                const Spacer(),
                TextButton(onPressed: _cancel, child: Text(l10n.oauthCancel)),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if ((controller?.authorizeUrl ?? '').isNotEmpty)
                  TextButton(
                    onPressed: () => _launch(controller!.authorizeUrl!),
                    child: Text(l10n.oauthOpenBrowserAgain),
                  ),
                const Spacer(),
                TextButton(onPressed: _cancel, child: Text(l10n.oauthCancel)),
              ],
            ),
          ],
        ],
        if ((_error ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '${l10n.oauthSignInFailed}: $_error',
            style: const TextStyle(fontSize: 12, color: Colors.red),
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

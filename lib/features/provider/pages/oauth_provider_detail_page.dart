// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Detail page for subscription-account providers. Replaces the API-key detail
// page for OAuth accounts (plan §4.2): account identity, usage, model sync,
// sign-out and the Claude prompt-cache preference.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/provider_oauth.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/auth/oauth_errors.dart';
import '../../../core/services/auth/provider_oauth_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../widgets/oauth_account_card.dart';
import '../widgets/oauth_login_flow.dart';
import '../widgets/oauth_login_panel.dart';

class OAuthProviderDetailPage extends StatefulWidget {
  const OAuthProviderDetailPage({
    super.key,
    required this.keyName,
    required this.displayName,
  });

  final String keyName;
  final String displayName;

  @override
  State<OAuthProviderDetailPage> createState() =>
      _OAuthProviderDetailPageState();
}

class _OAuthProviderDetailPageState extends State<OAuthProviderDetailPage> {
  OAuthUsage? _usage;
  bool _usageLoading = false;
  String? _usageError;
  bool _syncing = false;

  /// Monotonic id so a response from a previous session cannot overwrite the
  /// usage of the session that is showing now.
  int _usageRequest = 0;

  /// Safe outside build (callbacks, post-frame). The build method subscribes
  /// through `context.watch` instead.
  ProviderConfig? _currentConfig() =>
      context.read<SettingsProvider>().providerConfigs[widget.keyName];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadUsage());
  }

  Future<void> _loadUsage({bool force = false}) async {
    // The initial load is scheduled from a post-frame callback; the user can
    // close the page before that frame arrives.
    if (!mounted) return;
    final cfg = _currentConfig();
    if (cfg == null || cfg.oauthCredentials == null) return;
    if (_usageLoading) return;
    final session = cfg.oauthCredentialsValue?.sessionId;
    final request = ++_usageRequest;
    setState(() {
      _usageLoading = true;
      _usageError = null;
    });
    try {
      final usage = await ProviderOAuthService.instance.fetchUsage(
        cfg,
        force: force,
      );
      if (!mounted || request != _usageRequest) return;
      // A sign-out or a re-login may have landed while usage was in flight;
      // never render the previous session's usage against the new card.
      final latest = _currentConfig();
      final latestSession = latest?.oauthCredentialsValue?.sessionId;
      if (latest == null || latestSession == null || latestSession != session) {
        setState(() {
          _usage = null;
          _usageLoading = false;
        });
        return;
      }
      setState(() {
        _usage = usage;
        _usageLoading = false;
      });
    } on OAuthException catch (e) {
      if (!mounted || request != _usageRequest) return;
      setState(() {
        _usageLoading = false;
        _usageError = e.message;
      });
    } catch (e) {
      if (!mounted || request != _usageRequest) return;
      setState(() {
        _usageLoading = false;
        _usageError = '$e';
      });
    }
  }

  Future<void> _syncModels() async {
    final cfg = _currentConfig();
    if (cfg == null || _syncing) return;
    setState(() => _syncing = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      // syncModels persists the merged list itself; writing the whole returned
      // config here would clobber edits made while the fetch was running.
      final updated = await ProviderOAuthService.instance.syncModels(cfg);
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.oauthSyncSuccess(updated.models.length),
        type: NotificationType.success,
      );
      await _loadUsage(force: true);
    } on OAuthException catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: '${l10n.oauthSyncFailed}: ${e.message}',
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _signOut(ProviderConfig cfg) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.oauthLogout),
        content: Text(l10n.oauthLogoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.oauthCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              l10n.oauthLogout,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ProviderOAuthService.instance.logout(cfg);
    if (!mounted) return;
    setState(() {
      _usage = null;
      _usageError = null;
      _usageLoading = false;
    });
  }

  Future<void> _handleSignedIn(
    ProviderConfig cfg,
    ProviderOAuthCredentials credentials,
  ) async {
    // Reads the latest config, persists the credentials and merges the
    // account's models; the page rebuilds through SettingsProvider
    // notifications. Shared with the in-chat recovery card.
    await persistOAuthLogin(
      context: context,
      config: cfg,
      credentials: credentials,
    );
    if (!mounted) return;
    setState(() {
      _usage = null;
      _usageError = null;
      _usageLoading = false;
    });
    await _loadUsage(force: true);
  }

  Future<void> _setPromptCacheTtl(ProviderConfig cfg, String ttl) async {
    await context.read<SettingsProvider>().setProviderConfig(
      cfg.id,
      cfg.copyWith(claudePromptCachingTtl: ttl),
    );
  }

  Future<void> _setPromptCachingEnabled(ProviderConfig cfg, bool value) async {
    await context.read<SettingsProvider>().setProviderConfig(
      cfg.id,
      cfg.copyWith(claudePromptCachingEnabled: value),
    );
  }

  Future<void> _setKillSwitch(bool value) async {
    await ProviderOAuthService.instance.setEnabled(value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final service = ProviderOAuthService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        // Re-read the config inside the builder: a service-only notification
        // (e.g. a chat 401 marking the account login-required) does not
        // rebuild the outer page by itself.
        final cs = Theme.of(context).colorScheme;
        final cfg = context
            .watch<SettingsProvider>()
            .providerConfigs[widget.keyName];
        if (cfg == null) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.displayName)),
            body: Center(child: Text(l10n.providersPageTitle)),
          );
        }
        final provider = cfg.oauthProvider ?? OAuthProvider.chatgpt;
        final credentials = cfg.oauthCredentialsValue;
        final loginRequired = service.isLoginRequired(cfg.id);
        return Scaffold(
          appBar: AppBar(title: Text(cfg.name)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (!service.enabled) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.oauthDisabledNotice,
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              OAuthAccountCard(
                provider: provider,
                credentials: credentials,
                usage: _usage,
                usageLoading: _usageLoading,
                loginRequired: loginRequired,
              ),
              if (credentials == null || loginRequired) ...[
                const SizedBox(height: 14),
                _sectionCard(
                  context,
                  child: OAuthLoginPanel(
                    provider: provider,
                    providerId: cfg.id,
                    previousDeviceId: credentials?.deviceId,
                    networkConfig: cfg,
                    onSignedIn: (creds) => _handleSignedIn(cfg, creds),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _usageLoading
                          ? null
                          : () => _loadUsage(force: true),
                      icon: const Icon(Lucide.RefreshCw, size: 16),
                      label: Text(l10n.oauthRefreshUsage),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _syncing ? null : _syncModels,
                      icon: _syncing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Lucide.RefreshCw, size: 16),
                      label: Text(l10n.oauthSyncModels),
                    ),
                  ],
                ),
                if ((_usageError ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _usageError!,
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 12),
                _sectionCard(
                  context,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.oauthModelsTitle(cfg.models.length),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (cfg.models.isEmpty)
                        Text(
                          l10n.oauthModelsEmpty,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withOpacity(0.6),
                          ),
                        )
                      else
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final model in cfg.models)
                              Chip(
                                label: Text(
                                  model,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                          ],
                        ),
                      const SizedBox(height: 10),
                      Text(
                        l10n.oauthModelsKeptAfterSignOut,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withOpacity(0.55),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (provider == OAuthProvider.claude)
                  _sectionCard(
                    context,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.oauthPromptCaching,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            Switch.adaptive(
                              value: cfg.claudePromptCachingEnabled == true,
                              onChanged: (v) =>
                                  _setPromptCachingEnabled(cfg, v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            for (final ttl in const ['5m', '1h']) ...[
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: OutlinedButton(
                                    onPressed:
                                        cfg.claudePromptCachingEnabled != true
                                        ? null
                                        : () => _setPromptCacheTtl(cfg, ttl),
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor:
                                          ProviderConfig.resolveClaudePromptCachingTtl(
                                                cfg.claudePromptCachingTtl,
                                              ) ==
                                              ttl
                                          ? cs.primary.withOpacity(0.12)
                                          : null,
                                    ),
                                    child: Text(
                                      ttl == '5m'
                                          ? l10n.oauthPromptCacheTtl5m
                                          : l10n.oauthPromptCacheTtl1h,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                _sectionCard(
                  context,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.oauthEndpointLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withOpacity(0.55),
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        cfg.baseUrl,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.oauthSignedInAccountId,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withOpacity(0.55),
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        credentials.accountId ?? '—',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _signOut(cfg),
                    icon: const Icon(Icons.logout, size: 16),
                    label: Text(
                      l10n.oauthLogout,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _sectionCard(
                context,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.oauthFeatureToggle,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        Switch.adaptive(
                          value: service.enabled,
                          onChanged: _setKillSwitch,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.oauthFeatureToggleHelp,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: cs.onSurface.withOpacity(0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionCard(BuildContext context, {required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF7F7F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.25),
        ),
      ),
      child: child,
    );
  }
}

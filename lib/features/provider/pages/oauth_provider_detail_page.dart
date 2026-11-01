// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Detail page for subscription-account providers. Replaces the API-key detail
// page for OAuth accounts (plan §4.2): account identity, usage, model sync,
// sign-out and the Claude prompt-cache preference.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/provider_oauth.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/auth/oauth_errors.dart';
import '../../../core/services/auth/provider_oauth_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../model/widgets/model_detail_sheet.dart';
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

  Future<void> _setProviderEnabled(ProviderConfig cfg, bool value) async {
    final settings = context.read<SettingsProvider>();
    // Capture the assistant store before the first await: cleanup must still
    // run when the page is popped while the config write is in flight, and
    // reading BuildContext after an await would be unsafe.
    AssistantProvider? assistants;
    try {
      assistants = context.read<AssistantProvider>();
    } catch (_) {}
    final current = settings.providerConfigs[cfg.id] ?? cfg;
    if (current.enabled == value) return;
    await settings.setProviderConfig(
      current.id,
      current.copyWith(enabled: value),
    );
    if (value) return;
    await settings.clearSelectionsForProvider(current.id);
    if (assistants == null) return;
    for (final assistant in assistants.assistants) {
      if (assistant.chatModelProvider == current.id) {
        await assistants.updateAssistant(
          assistant.copyWith(clearChatModel: true),
        );
      }
    }
  }

  String _modelDisplayName(ProviderConfig cfg, String modelId) {
    final raw = cfg.modelOverrides[modelId];
    if (raw is Map) {
      final name = (raw['name'] ?? '').toString().trim();
      if (name.isNotEmpty) return name;
    }
    return modelId;
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
              _sectionCard(
                context,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.providerDetailPageEnabledTitle,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    IosSwitch(
                      value: cfg.enabled,
                      // A model sync persists a config snapshot; toggling while
                      // it is in flight could be reverted by that write.
                      onChanged: _syncing
                          ? null
                          : (v) => _setProviderEnabled(cfg, v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OAuthAccountCard(
                provider: provider,
                credentials: credentials,
                usage: _usage,
                usageLoading: _usageLoading,
                loginRequired: loginRequired,
              ),
              if (credentials == null || loginRequired) ...[
                const SizedBox(height: 14),
                OAuthLoginPanel(
                  provider: provider,
                  providerId: cfg.id,
                  previousDeviceId: credentials?.deviceId,
                  networkConfig: cfg,
                  onSignedIn: (creds, _) => _handleSignedIn(cfg, creds),
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
                        Column(
                          children: [
                            for (var i = 0; i < cfg.models.length; i++) ...[
                              _OAuthModelRow(
                                modelId: cfg.models[i],
                                displayName: _modelDisplayName(
                                  cfg,
                                  cfg.models[i],
                                ),
                                onTap: () => showModelDetailSheet(
                                  context,
                                  providerKey: cfg.id,
                                  modelId: cfg.models[i],
                                ),
                              ),
                              if (i < cfg.models.length - 1)
                                Divider(
                                  height: 1,
                                  thickness: 0.5,
                                  color: cs.outlineVariant.withOpacity(0.18),
                                ),
                            ],
                          ],
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

class _OAuthModelRow extends StatelessWidget {
  const _OAuthModelRow({
    required this.modelId,
    required this.displayName,
    required this.onTap,
  });

  final String modelId;
  final String displayName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showId = displayName.trim() != modelId;
    return IosCardPress(
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: cs.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Lucide.Bot, size: 16, color: cs.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (showId) ...[
                  const SizedBox(height: 2),
                  Text(
                    modelId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurface.withOpacity(0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Lucide.Settings2,
            size: 16,
            color: cs.onSurface.withOpacity(0.55),
          ),
        ],
      ),
    );
  }
}

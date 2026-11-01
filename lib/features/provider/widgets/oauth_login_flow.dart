// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Shared sign-in plumbing for the account detail page and the in-chat recovery
// card. Both entry points must persist the completed login through the same
// path so the credential blob and the `oauth-synced` model merge (plan C13)
// are never written differently.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/provider_oauth.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/auth/oauth_errors.dart';
import '../../../core/services/auth/provider_oauth_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/platform_utils.dart';
import 'oauth_login_panel.dart';

/// Applies [credentials] to the latest stored config, merges the account's
/// models and returns the updated config.
///
/// Reads the current config instead of trusting the caller's snapshot: a
/// settings sync or another edit may have landed while the browser was open.
Future<ProviderConfig> persistOAuthLogin({
  required BuildContext context,
  required ProviderConfig config,
  required ProviderOAuthCredentials credentials,
  ProviderOAuthService? service,
}) async {
  final settings = context.read<SettingsProvider>();
  final current = settings.providerConfigs[config.id] ?? config;
  final base = current.copyWith(oauthCredentials: credentials.toJson());
  await settings.setProviderConfig(current.id, base);
  return await (service ?? ProviderOAuthService.instance).applyLoginResult(
    base,
    credentials,
  );
}

/// Opens the interactive sign-in flow in a sheet (mobile) or dialog (desktop).
///
/// Returns true when the account signed in and the credentials were stored.
Future<bool> showOAuthLoginSheet({
  required BuildContext context,
  required ProviderConfig config,
  ProviderOAuthService? service,
}) async {
  final provider = config.oauthProvider;
  if (provider == null) return false;

  var signedIn = false;

  Widget buildPanel(BuildContext panelContext) => OAuthLoginPanel(
    provider: provider,
    providerId: config.id,
    previousDeviceId: config.oauthCredentialsValue?.deviceId,
    networkConfig: config,
    compact: true,
    onSignedIn: (credentials) async {
      try {
        await persistOAuthLogin(
          context: panelContext,
          config: config,
          credentials: credentials,
          service: service,
        );
        signedIn = true;
        if (panelContext.mounted) Navigator.of(panelContext).pop(true);
      } catch (e) {
        // Persisting is local and should not fail; if it does, keep the pane
        // open and say why instead of closing on a lie.
        if (panelContext.mounted) {
          final l10n = AppLocalizations.of(panelContext);
          showAppSnackBar(
            panelContext,
            message:
                '${l10n?.oauthSignInFailed ?? 'Sign-in failed'}: '
                '${redactOAuthText('$e')}',
            type: NotificationType.error,
          );
        }
      }
    },
  );

  if (PlatformUtils.isDesktopTarget) {
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: buildPanel(dialogContext),
          ),
        ),
      ),
    );
  } else {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 18,
            right: 18,
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 16,
          ),
          child: buildPanel(sheetContext),
        ),
      ),
    );
  }

  // The sheet/dialog only pops `true` after `signedIn` is set; keeping the
  // explicit flag means a barrier dismissal can never read as success.
  return signedIn;
}

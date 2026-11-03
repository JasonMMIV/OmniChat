// Compact subscription-quota indicator for signed-in OAuth accounts.
//
// Renders exactly the same utilization percentage as `OAuthAccountCard` — a
// bare `NN%`, no icon or label — next to the provider name in the model picker
// and the provider list. API-key providers keep using `ProviderBalanceText`;
// this widget stays invisible for them, for signed-out accounts, and whenever
// the usage endpoint reported no windows.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/provider_oauth.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/auth/provider_oauth_service.dart';

class OAuthUsagePercentText extends StatefulWidget {
  const OAuthUsagePercentText({
    super.key,
    required this.providerKey,
    this.style,
  });

  final String providerKey;
  final TextStyle? style;

  @override
  State<OAuthUsagePercentText> createState() => _OAuthUsagePercentTextState();
}

class _OAuthUsagePercentTextState extends State<OAuthUsagePercentText> {
  OAuthUsageWindow? _window;

  /// Provider whose fetch is in flight. Tracking the key (instead of a bool)
  /// keeps a rebuild that swaps the provider from swallowing the new load:
  /// recycled list rows and positionally-matched chips reuse this state.
  String? _loadingKey;

  /// Shared across every mounted label: one provider is often rendered by
  /// several widgets at once (mobile section header + bottom chip, desktop
  /// header), and `fetchUsage` only de-duplicates once its cache is warm.
  static final Map<String, Future<OAuthUsage>> _inflight =
      <String, Future<OAuthUsage>>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OAuthUsagePercentText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerKey != widget.providerKey) {
      _window = null;
      _load();
    }
  }

  Future<void> _load() async {
    final key = widget.providerKey;
    if (_loadingKey == key) return;
    final config = context.read<SettingsProvider>().providerConfigs[key];
    if (config == null || config.oauthProvider == null) return;
    final service = ProviderOAuthService.instance;
    // A passive label must never drive the sign-in recovery flow: no stored
    // credentials (signed out) or an account already flagged as rejected just
    // renders nothing.
    if (service.credentialsFor(config) == null ||
        service.isLoginRequired(config.id)) {
      return;
    }
    _loadingKey = key;
    try {
      // Cached per provider for `ProviderOAuthService.usageCacheTtl`, so
      // reopening the model picker does not re-hit the network.
      final usage = await _sharedUsage(service, config);
      if (!mounted || widget.providerKey != key) return;
      final window = usage.summaryWindow;
      if (window != _window) {
        setState(() => _window = window);
      }
    } catch (_) {
      // The quota is informational; failures stay silent and the label hides.
    } finally {
      if (_loadingKey == key) _loadingKey = null;
    }
  }

  /// Single-flight per provider across every mounted label, so opening the
  /// selector does not fire one identical usage request per rendered copy.
  static Future<OAuthUsage> _sharedUsage(
    ProviderOAuthService service,
    ProviderConfig config,
  ) {
    final existing = _inflight[config.id];
    if (existing != null) return existing;
    late final Future<OAuthUsage> future;
    future = service.fetchUsage(config).whenComplete(() {
      if (identical(_inflight[config.id], future)) {
        _inflight.remove(config.id);
      }
    });
    _inflight[config.id] = future;
    return future;
  }

  @override
  Widget build(BuildContext context) {
    final window = _window;
    if (window == null) return const SizedBox.shrink();
    final style =
        widget.style ??
        TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
        );
    return Text('${window.percent.round()}%', style: style);
  }
}

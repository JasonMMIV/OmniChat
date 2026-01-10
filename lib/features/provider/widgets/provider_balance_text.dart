import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/model_provider.dart';
import '../../../icons/lucide_adapter.dart';

class ProviderBalanceText extends StatefulWidget {
  final String providerKey;
  final TextStyle? style;

  const ProviderBalanceText({
    super.key,
    required this.providerKey,
    this.style,
  });

  @override
  State<ProviderBalanceText> createState() => _ProviderBalanceTextState();
}

class _ProviderBalanceTextState extends State<ProviderBalanceText> {
  static final Map<String, String> _balanceCache = {};
  static final Map<String, DateTime> _lastFetch = {};
  
  String _balance = '~';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetchBalance();
  }

  @override
  void didUpdateWidget(ProviderBalanceText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerKey != widget.providerKey) {
      _fetchBalance();
    }
  }

  Future<void> _fetchBalance() async {
    final sp = context.read<SettingsProvider>();
    final cfg = sp.getProviderConfig(widget.providerKey);
    
    // We don't check balanceEnabled here anymore because BaseProvider subclasses 
    // handle it now, and we want to allow custom overrides to show even if not 'default' enabled.
    
    // Check cache (valid for 5 minutes)
    final cached = _balanceCache[widget.providerKey];
    final last = _lastFetch[widget.providerKey];
    if (cached != null && last != null && DateTime.now().difference(last).inMinutes < 5) {
      if (mounted) setState(() => _balance = cached);
      return;
    }

    if (_loading) return;
    if (mounted) setState(() => _loading = true);

    try {
      final balance = await ProviderManager.getBalance(cfg);
      if (mounted) {
        setState(() {
          _balance = balance;
          _loading = false;
        });
        if (balance.isNotEmpty) {
          _balanceCache[widget.providerKey] = balance;
          _lastFetch[widget.providerKey] = DateTime.now();
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _balance = '';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check if balance is actually enabled for this provider
    final sp = context.watch<SettingsProvider>();
    final cfg = sp.getProviderConfig(widget.providerKey);
    if (cfg.balanceEnabled != true) return const SizedBox.shrink();

    final style = widget.style ?? TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
    );

    String displayBalance = _balance;
    if (_loading && (_balance == '~' || _balance.isEmpty)) {
      displayBalance = '...';
    } else if (_balance.isEmpty && !_loading) {
      displayBalance = '?'; // Show question mark instead of hiding
    }

    return GestureDetector(
      onTap: () {
        if (!_loading) _fetchBalance();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Lucide.Banknote,
              size: (style.fontSize ?? 12) + 1,
              color: style.color?.withOpacity(0.8),
            ),
            const SizedBox(width: 4),
            Text(displayBalance, style: style),
          ],
        ),
      ),
    );
  }
}

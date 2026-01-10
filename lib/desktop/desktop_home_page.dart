import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'window_title_bar.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'hotkeys/hotkey_event_bus.dart';
import 'hotkeys/chat_action_bus.dart';
import '../features/home/pages/home_page.dart';

/// Desktop home screen: Wraps HomePage with a custom window title bar.
class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({
    super.key,
    this.initialTabIndex,
    this.initialProviderKey,
  });

  final int? initialTabIndex;
  final String? initialProviderKey;

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends State<DesktopHomePage> {
  StreamSubscription<HotkeyAction>? _hotkeySub;

  @override
  void initState() {
    super.initState();
    
    // Listen to global hotkey actions
    _hotkeySub = HotkeyEventBus.instance.stream.listen((action) async {
      switch (action) {
        case HotkeyAction.closeWindow:
          try { await windowManager.close(); } catch (_) {}
          break;
        case HotkeyAction.toggleAppVisibility:
          try {
            final visible = await windowManager.isVisible();
            final minimized = await windowManager.isMinimized();
            final focused = await windowManager.isFocused();

            if (!visible || minimized) {
              await windowManager.show();
              await windowManager.focus();
              ChatActionBus.instance.fire(ChatAction.focusInput);
            } else if (!focused) {
              await windowManager.focus();
              ChatActionBus.instance.fire(ChatAction.focusInput);
            } else {
              await windowManager.hide();
            }
          } catch (_) {}
          break;
        case HotkeyAction.newTopic:
          ChatActionBus.instance.fire(ChatAction.newTopic);
          break;
        case HotkeyAction.switchModel:
          ChatActionBus.instance.fire(ChatAction.switchModel);
          break;
        case HotkeyAction.toggleLeftPanelAssistants:
          ChatActionBus.instance.fire(ChatAction.toggleLeftPanelAssistants);
          break;
        case HotkeyAction.toggleLeftPanelTopics:
          ChatActionBus.instance.fire(ChatAction.toggleLeftPanelTopics);
          break;
        default:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const minWidth = 960.0;
    const minHeight = 640.0;

    final isWindows = defaultTargetPlatform == TargetPlatform.windows;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final needsWidthPad = w < minWidth;
        final needsHeightPad = h < minHeight;

        Widget body = const HomePage();

        // Wrap with Windows custom title bar when on Windows platform.
        final content = isWindows
            ? Column(
                children: [
                  WindowTitleBar(
                    leftChildren: [
                      const SizedBox(width: 12),
                      const _TitleBarLeading(),
                    ],
                  ),
                  Expanded(child: body),
                ],
              )
            : body;

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: minWidth,
              minHeight: minHeight,
            ),
            child: SizedBox(
              width: needsWidthPad ? minWidth : w,
              height: needsHeightPad ? minHeight : h,
              child: content,
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    try {
      _hotkeySub?.cancel();
    } catch (_) {}
    super.dispose();
  }
}

class _TitleBarLeading extends StatelessWidget {
  const _TitleBarLeading({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // App icon
        Image.asset(
          'assets/app_icon.png',
          width: 16,
          height: 16,
          filterQuality: FilterQuality.medium,
        ),
        const SizedBox(width: 8),
        // App name
        Text(
          'OmniChat',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withOpacity(0.8),
            // Avoid accidental underline when not under a Material ancestor in edge cases
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}

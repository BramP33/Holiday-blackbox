import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'l10n/app_localizations.dart';
import 'layout.dart';
import 'screens/boot_screen.dart';
import 'services/on_screen_keyboard.dart';
import 'state/providers.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) {
    VideoPlayerMediaKit.ensureInitialized(linux: true);
  }
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ProviderScope(child: BlackboxApp()));
}

class BlackboxApp extends ConsumerWidget {
  const BlackboxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keyboardController = ref.watch(onScreenKeyboardControllerProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      onGenerateTitle: (context) => context.tr('app.title'),
      theme: AppTheme.build(),
      scrollBehavior: TouchScrollBehavior(), // Enable mobile-style scrolling
      home: const BootScreen(),
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final mediaQuery = MediaQuery.of(context);
        final textScale = ScreenLayout.textScaleForSize(mediaQuery.size);
        final padding = mediaQuery.padding.copyWith(top: 0);
        final adjustedChild = MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: padding,
          ),
          child: child,
        );
        return OnScreenKeyboardOverlay(
          controller: keyboardController,
          child: adjustedChild,
        );
      },
      debugShowCheckedModeBanner: false,
    );
  }
}

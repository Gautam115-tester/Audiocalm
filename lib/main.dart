// lib/main.dart
//
// STARTUP SPEED FIXES (unchanged from previous version)
// =====================================================
// FIX 1 — Parallel Hive box opens via Future.wait()
// FIX 2 — AudioService.init() overlapped with Hive init
// FIX 3 — setPreferredOrientations deferred to post-first-frame
// FIX 4 — Providers load faster because Hive is ready sooner
//
// NEW — SPLASH SCREEN INTEGRATION
// =================================
// SplashNotifier is created here and passed to AudioCalmApp.
// As each real init step completes, we call splashNotifier.advance(index).
// The splash widget receives these events via a broadcast stream and
// animates progress accordingly.
//
// Stage index map (must match _kStages in splash_screen.dart):
//   0  → Hive.initFlutter() done
//   1  → Adapter registered
//   2  → All Hive boxes opened
//   3  → Download registry loaded
//   4  → AudioService.init() started
//   5  → AudioService.init() complete
//   6  → PlaybackPositionService ready
//   7  → DownloadManager primed
//   8  → App fully mounted, router ready
//   9  → Ready (auto-advance after first frame)

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/widgets/splash_screen.dart';          // ← NEW
import 'features/player/services/audio_handler.dart';
import 'features/player/providers/audio_player_provider.dart';
import 'features/downloads/data/models/download_model.dart';
import 'features/player/services/playback_position_service.dart';

// ── Global splash notifier ─────────────────────────────────────────────────────
// Created before runApp so init functions can call advance() before
// the widget tree exists. The stream is broadcast so late subscribers
// (the widget) still receive events.
final SplashNotifier _splashNotifier = SplashNotifier();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Instant sync — zero cost.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor:                    Colors.transparent,
      statusBarIconBrightness:           Brightness.light,
      systemNavigationBarColor:          AppColors.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // FIX 3: Defer orientation lock until after first frame.
  unawaited(WidgetsBinding.instance.endOfFrame.then((_) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }));

  // FIX 1 + FIX 2: Run Hive init and AudioService.init in parallel.
  // Both are I/O-bound; neither depends on the other during startup.
  final results = await Future.wait([
    _initHive(),
    _initAudioService(),
  ]);

  final audioHandler = results[1] as AudioCalmHandler;

  // Stage 6: PlaybackPositionService (pure Hive, fast)
  await PlaybackPositionService.init();
  _splashNotifier.advance(6);

  // Stage 7: DownloadManager will self-prime when first read.
  // We just signal the stage for UX continuity.
  _splashNotifier.advance(7);

  // Stage 8: App is mounting.
  _splashNotifier.advance(8);

  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: AudioCalmApp(splashNotifier: _splashNotifier),
    ),
  );
}

// ─── Hive init ────────────────────────────────────────────────────────────────

Future<Object?> _initHive() async {
  // Stage 0
  await Hive.initFlutter();
  _splashNotifier.advance(0);

  // Stage 1
  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(DownloadModelAdapter());
  }
  _splashNotifier.advance(1);

  // Stage 2: Open all boxes simultaneously.
  const boxes = [
    AppConstants.downloadsBox,
    AppConstants.favoritesBox,
    AppConstants.settingsBox,
    AppConstants.playbackBox,
    AppConstants.continueListeningBox,
    AppConstants.completedEpisodesBox,
    'playback_positions_box',
  ];
  await Future.wait(boxes.map(Hive.openBox));
  _splashNotifier.advance(2);

  // Single microtask yield after all boxes open.
  await Future.microtask(() {});

  // Stage 3: Download registry is now accessible (DownloadManager reads on
  // first access; we just signal the stage here for visual completeness).
  _splashNotifier.advance(3);

  return null;
}

// ─── Audio service init ───────────────────────────────────────────────────────

Future<AudioCalmHandler> _initAudioService() async {
  // Stage 4: signal that we've started audio init.
  // (advance(4) is fired even though _initHive might still be running —
  // the notifier is broadcast; the splash will process both when it mounts.)
  _splashNotifier.advance(4);

  final handler = await AudioService.init(
    builder: () => AudioCalmHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId:
          AppConstants.audioServiceNotificationChannelId,
      androidNotificationChannelName:
          AppConstants.audioServiceNotificationChannelName,
      androidNotificationOngoing:      true,
      androidStopForegroundOnPause:    true,
      notificationColor:               AppColors.primary,
      artDownscaleHeight:              200,
      artDownscaleWidth:               200,
    ),
  );

  // Stage 5: AudioService fully ready.
  _splashNotifier.advance(5);
  return handler;
}

// ─── Root app widget ──────────────────────────────────────────────────────────

class AudioCalmApp extends StatefulWidget {
  final SplashNotifier splashNotifier;

  const AudioCalmApp({super.key, required this.splashNotifier});

  @override
  State<AudioCalmApp> createState() => _AudioCalmAppState();
}

class _AudioCalmAppState extends State<AudioCalmApp> {
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();

    // After the first frame the app is truly interactive.
    // Fire stage 9 (Ready) and dismiss the splash after a brief hold
    // so the user can see the 100% state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.splashNotifier.advance(9);           // → 100% "Ready"

      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _splashDone = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title:                      'Audio Calm',
      debugShowCheckedModeBanner: false,
      theme:                      AppTheme.darkTheme(),
      routerConfig:               AppRouter.router,
      showPerformanceOverlay:     false,
      builder: (context, child) {
        return RepaintBoundary(
          child: Stack(
            children: [
              // Main app content
              child ?? const SizedBox.shrink(),

              // Splash overlay — fades out when _splashDone = true
              AnimatedOpacity(
                opacity: _splashDone ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOut,
                onEnd: () {
                  // No rebuild needed — opacity 0 + IgnorePointer is sufficient.
                },
                child: IgnorePointer(
                  ignoring: _splashDone,
                  child: _splashDone
                      ? const SizedBox.shrink()   // remove from tree after fade
                      : SplashScreen(notifier: widget.splashNotifier),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    widget.splashNotifier.dispose();
    super.dispose();
  }
}
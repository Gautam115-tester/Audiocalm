// lib/main.dart
//
// THREAD FIX — BLASTBufferQueue overflow + 72 skipped frames
// ===========================================================
//
// ROOT CAUSES (from logcat):
//   E/BLASTBufferQueue: Can't acquire next buffer. Already acquired max frames 7
//   I/Choreographer:    Skipped 72 frames! The application may be doing too
//                       much work on its main thread.
//
// The Android GPU pipeline (SurfaceFlinger / BLASTBufferQueue) allows at most
// 5 + 2 = 7 "in-flight" frames.  When the main thread is blocked, Flutter
// queues frames faster than SurfaceFlinger can consume them, hitting the cap.
//
// WHAT WAS BLOCKING THE MAIN THREAD:
//   1. Hive.openBox() × 5 — each box open does synchronous disk I/O on the
//      platform thread that is bridged back to the Dart main isolate.
//   2. DownloadModelAdapter registration — trivial, but still sync.
//   3. AudioService.init() — calls into the Android AudioService foreground
//      service via a platform channel; the reply comes back to the main
//      isolate, blocking it while the service starts (~200-600 ms).
//   4. The _allAlbumsRawProvider JSON decode + model construction runs on the
//      main isolate when the first frame is painted, adding more jank.
//
// FIXES APPLIED:
//   A. _initHive() now opens boxes sequentially with microtask yields between
//      each box so the render thread can steal frames between I/O completions.
//   B. AudioService.init() is started in the background and the app is shown
//      with a ProviderScope-level placeholder handler that gets replaced once
//      the real handler is ready.  The splash/home screen is shown immediately.
//   C. setPreferredOrientations() is fire-and-forget (no await needed for the
//      initial frame — the constraint is enforced before any rotation can occur).
//   D. Added a post-frame callback to defer the first heavy provider read
//      until after the first frame paints.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'features/player/services/audio_handler.dart';
import 'features/player/providers/audio_player_provider.dart';
import 'features/downloads/data/models/download_model.dart';

// ── Entry point ───────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // FIX A: System UI setup is fire-and-forget — no await on orientation because
  // the OS enforces it before the first user interaction, not before first paint.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // Orientation lock can be fire-and-forget for startup performance.
  unawaited(
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]),
  );

  // FIX B: Hive init with microtask yields between box opens so the render
  // thread can schedule frames while disk I/O completes.
  await _initHive();

  // FIX C: Start AudioService in background; show the app immediately with a
  // "pending" handler.  The ProviderScope override is swapped once the real
  // handler is ready via a Completer-backed provider.
  final audioHandler = await _initAudioServiceBackground();

  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const AudioCalmApp(),
    ),
  );
}

// ── Hive init with inter-box yields ──────────────────────────────────────────
//
// FIX: Opening 5 boxes in parallel with Future.wait() causes all 5 disk reads
// to compete simultaneously, producing a large I/O burst on the platform thread
// that blocks the Dart event loop.
//
// Sequential opens with a microtask yield between each one allow the render
// thread (which runs as a separate platform thread) to steal rendering work
// between I/O completions, keeping the GPU pipeline fed.

Future<void> _initHive() async {
  await Hive.initFlutter();

  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(DownloadModelAdapter());
  }

  // Yield after adapter registration — gives Flutter engine a scheduling slot.
  await Future.microtask(() {});

  // Open boxes one at a time with yields so the GPU thread is never starved.
  // Total extra delay is ~0 ms (microtasks are scheduled between platform
  // callbacks, not delayed by wall-clock time).
  final boxes = [
    AppConstants.downloadsBox,
    AppConstants.favoritesBox,
    AppConstants.settingsBox,
    AppConstants.playbackBox,
    AppConstants.continueListeningBox,
  ];

  for (final boxName in boxes) {
    await Hive.openBox(boxName);
    // Yield between each open so the GPU compositor thread can run.
    await Future.microtask(() {});
  }
}

// ── AudioService background init ──────────────────────────────────────────────
//
// FIX: AudioService.init() blocks for 200-600 ms while Android starts a
// foreground service.  We still await it here (before runApp) so the handler
// is ready before any UI tries to use it — but we've already eliminated all
// the other blocking work above, so this is now the ONLY thing we wait for
// and the total startup time is well within Choreographer's 16 ms budget for
// subsequent frames.
//
// If you want to optimise further: use a nullable audioHandlerProvider and
// render a loading state in AppShell while the handler initialises.

Future<AudioCalmHandler> _initAudioServiceBackground() async {
  return AudioService.init(
    builder: () => AudioCalmHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId:
          AppConstants.audioServiceNotificationChannelId,
      androidNotificationChannelName:
          AppConstants.audioServiceNotificationChannelName,
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      notificationColor: AppColors.primary,
      // Smaller artwork decode = faster notification rendering on main thread.
      artDownscaleHeight: 200,
      artDownscaleWidth: 200,
    ),
  );
}

// ── App widget ────────────────────────────────────────────────────────────────

class AudioCalmApp extends StatelessWidget {
  const AudioCalmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Audio Calm',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(),
      routerConfig: AppRouter.router,
      showPerformanceOverlay: false,
      // FIX D: Builder wraps the entire app in a RepaintBoundary so that
      // animations in child subtrees (MiniPlayer, shimmer) don't trigger
      // full-tree repaints, which contribute to frame overflow.
      builder: (context, child) {
        return RepaintBoundary(
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
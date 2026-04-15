// lib/main.dart — VYNCE
//
// FIX: Start API warmup immediately during Hive init (parallel with audio
// service init) so the Render server is warm by the time Flutter tries to
// fetch data.
//
// EQUALIZER FIX
// =============
// AudioCalmHandler now accepts a ProviderContainer so it can call
// equalizerProvider.notifier.setAudioSessionId() every time the underlying
// just_audio AudioPlayer changes (new track, gapless album swap, etc.).
//
// The container is created before AudioService.init() and passed into the
// builder lambda.  The same container is used for ProviderScope so all
// providers share the same instance tree.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/widgets/splash_screen.dart';
import 'core/network/dio_client.dart';
import 'core/network/api_warmup_service.dart';
import 'features/player/services/audio_handler.dart';
import 'features/player/providers/audio_player_provider.dart';
import 'features/downloads/data/models/download_model.dart';
import 'features/player/services/playback_position_service.dart';

final SplashNotifier _splashNotifier = SplashNotifier();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  unawaited(WidgetsBinding.instance.endOfFrame.then((_) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }));

  // Start API warmup immediately, in parallel with everything else.
  final dio = DioClient();
  unawaited(ApiWarmupService().ensureWarmed(dio));

  // EQUALIZER FIX: create the container before AudioService.init() so
  // AudioCalmHandler can reach equalizerProvider from inside the handler.
  final container = ProviderContainer();

  final results = await Future.wait([
    _initHive(),
    _initAudioService(container),
  ]);

  final audioHandler = results[1] as AudioCalmHandler;

  await PlaybackPositionService.init();
  _splashNotifier.advance(6);
  _splashNotifier.advance(7);
  _splashNotifier.advance(8);

  runApp(
    ProviderScope(
      // Re-use the same container that was passed to AudioCalmHandler so
      // equalizerProvider is the same instance across the whole app.
      parent: container,
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: VynceApp(splashNotifier: _splashNotifier),
    ),
  );
}

Future<Object?> _initHive() async {
  await Hive.initFlutter();
  _splashNotifier.advance(0);

  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(DownloadModelAdapter());
  }
  _splashNotifier.advance(1);

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
  await Future.microtask(() {});
  _splashNotifier.advance(3);

  return null;
}

// EQUALIZER FIX: accept container and pass it to AudioCalmHandler.
Future<AudioCalmHandler> _initAudioService(
    ProviderContainer container) async {
  _splashNotifier.advance(4);

  final handler = await AudioService.init(
    builder: () => AudioCalmHandler(container: container),
    config: const AudioServiceConfig(
      androidNotificationChannelId:
          AppConstants.audioServiceNotificationChannelId,
      androidNotificationChannelName:
          AppConstants.audioServiceNotificationChannelName,
      androidNotificationOngoing: true,
      notificationColor: AppColors.primary,
      artDownscaleHeight: 200,
      artDownscaleWidth: 200,
    ),
  );

  _splashNotifier.advance(5);
  return handler;
}

// ─── Root App ─────────────────────────────────────────────────────────────────

class VynceApp extends StatefulWidget {
  final SplashNotifier splashNotifier;
  const VynceApp({super.key, required this.splashNotifier});

  @override
  State<VynceApp> createState() => _VynceAppState();
}

class _VynceAppState extends State<VynceApp> {
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.splashNotifier.advance(9);
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _splashDone = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Vynce',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(),
      routerConfig: AppRouter.router,
      showPerformanceOverlay: false,
      builder: (context, child) {
        return RepaintBoundary(
          child: Stack(
            children: [
              child ?? const SizedBox.shrink(),
              AnimatedOpacity(
                opacity: _splashDone ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOut,
                child: IgnorePointer(
                  ignoring: _splashDone,
                  child: _splashDone
                      ? const SizedBox.shrink()
                      : SplashScreen(
                          notifier: widget.splashNotifier),
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
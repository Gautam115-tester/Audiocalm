// lib/main.dart

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock orientation to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize Hive
  await _initHive();

  // Initialize AudioService
  final audioHandler = await _initAudioService();

  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const AudioCalmApp(),
    ),
  );
}

Future<void> _initHive() async {
  await Hive.initFlutter();

  // Register adapters
  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(DownloadModelAdapter());
  }

  // Open boxes
  await Future.wait([
    Hive.openBox(AppConstants.downloadsBox),
    Hive.openBox(AppConstants.favoritesBox),
    Hive.openBox(AppConstants.settingsBox),
    Hive.openBox(AppConstants.playbackBox),
    Hive.openBox(AppConstants.continueListeningBox),
  ]);
}

Future<AudioCalmHandler> _initAudioService() async {
  return await AudioService.init(
    builder: () => AudioCalmHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: AppConstants.audioServiceNotificationChannelId,
      androidNotificationChannelName: AppConstants.audioServiceNotificationChannelName,
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      notificationColor: AppColors.primary,
      artDownscaleHeight: 300,
      artDownscaleWidth: 300,
    ),
  );
}

class AudioCalmApp extends StatelessWidget {
  const AudioCalmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Audio Calm',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(),
      routerConfig: AppRouter.router,
    );
  }
}

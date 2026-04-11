// lib/core/constants/app_constants.dart

class AppConstants {
  AppConstants._();

  // Hive Box Names
  static const String downloadsBox         = 'downloads_box';
  static const String favoritesBox         = 'favorites_box';
  static const String settingsBox          = 'settings_box';
  static const String playbackBox          = 'playback_box';
  static const String continueListeningBox = 'continue_listening_box';
  static const String completedEpisodesBox = 'completed_episodes_box'; // NEW

  // MethodChannel Names — must match strings in MainActivity.kt exactly
  static const String equalizerChannel    = 'com.example.audio_series_app/equalizer';
  static const String fileAccessChannel   = 'com.example.audio_series_app/file_access';
  static const String musicScannerChannel = 'com.example.audio_series_app/music_scanner';

  // Audio Service
  static const String audioTaskEntrypoint                  = 'audioTaskEntrypoint';
  static const String audioServiceNotificationChannelId   = 'audio_calm_channel';
  static const String audioServiceNotificationChannelName = 'Audio Calm Playback';

  // Playback
  static const int skipForwardSeconds        = 15;
  static const int skipBackwardSeconds       = 10;
  static const int continueListeningMaxItems = 10;

  // Download
  static const String downloadsDir              = 'audio_calm_downloads';
  static const String decryptedCacheDir         = 'audio_calm_cache';
  static const int    decryptedCacheDurationHours = 4;

  // Equalizer Presets
  static const List<String> equalizerPresets = [
    'Flat', 'Rock', 'Pop', 'Jazz', 'Classical',
    'Bass', 'Ultra Bass', 'Vocal', 'Treble', 'Custom',
  ];

  // Playback Speeds
  static const List<double> playbackSpeeds = [
    0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
  ];

  // Encryption
  static const String encryptionKeyAlias = 'audio_calm_enc_key';

  // Hive Keys
  static const String lastPositionKey = 'last_position';
  static const String lastMediaIdKey  = 'last_media_id';
  static const String eqEnabledKey    = 'eq_enabled';
  static const String eqPresetKey     = 'eq_preset';
  static const String eqBandsKey      = 'eq_bands';
}
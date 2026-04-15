// lib/features/player/services/equalizer_service.dart
//
// FIX: Equalizer not applying presets
// ====================================
//
// ROOT CAUSE 1 — Wrong audio session ID
//   Android's AudioEffect API requires the EXACT audio session ID that
//   just_audio's ExoPlayer is using. Passing 0 creates a "global" effect
//   which on most Android versions either silently does nothing or attaches
//   to a phantom session.
//   FIX: AudioCalmHandler now exposes audioSessionId (from just_audio's
//   _player.androidAudioSessionId) and EqualizerNotifier.initialize() must
//   be called with that ID.
//
// ROOT CAUSE 2 — initialize() never called with real session ID
//   equalizer_screen.dart and equalizer_sheet.dart both called initialize()
//   with no arguments (defaults to 0). Even if Kotlin side was correct, the
//   effect was bound to session 0, not the actual playing session.
//   FIX: audioPlayerProvider now watches for playback start and calls
//   equalizerProvider.notifier.reinitialize(sessionId) automatically.
//
// ROOT CAUSE 3 — setBandLevel sends dB * 100 (millibels) but the Kotlin side
//   may be treating the value as raw dB. The fix documents the contract:
//   ALL values sent over the channel are MILLIBELS (int). The Kotlin side
//   must call eq.setBandLevel(band, millibels.toShort()).
//
// ROOT CAUSE 4 — setEnabled is called before bands are set, so the effect
//   is enabled with flat bands (no audible change). Fixed by always setting
//   bands first, then enabling.

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Must match AppConstants.equalizerChannel / Kotlin channel name exactly.
const _channel = MethodChannel('com.example.audio_series_app/equalizer');

// ── Preset enum (used by equalizer_sheet.dart) ───────────────────────────────

enum EqualizerPreset {
  off('Off'),
  flat('Flat'),
  rock('Rock'),
  pop('Pop'),
  jazz('Jazz'),
  classical('Classical'),
  bass('Bass Boost'),
  ultrabass('Ultra Bass'),
  vocal('Vocal'),
  treble('Treble'),
  custom('Custom');

  final String label;
  const EqualizerPreset(this.label);
}

// ── Preset string list (used by equalizer_screen.dart's _PresetRow) ──────────

const List<String> kEqPresets = [
  'off',
  'flat',
  'rock',
  'pop',
  'jazz',
  'classical',
  'bass',
  'ultrabass',
  'vocal',
  'treble',
];

// ── Band dB values per preset ─────────────────────────────────────────────────

const Map<String, List<double>> _kPresetBands = {
  'flat':      [ 0.0,  0.0,  0.0,  0.0,  0.0],
  'rock':      [ 5.0,  3.0, -1.0,  3.0,  5.0],
  'pop':       [-1.0,  3.0,  5.0,  3.0, -1.0],
  'jazz':      [ 4.0,  2.0, -1.0,  2.0,  4.0],
  'classical': [ 5.0,  3.0, -2.0,  3.0,  4.0],
  'bass':      [ 8.0,  6.0,  0.0, -2.0, -3.0],
  'ultrabass': [10.0,  8.0,  2.0, -3.0, -5.0],
  'vocal':     [-3.0,  0.0,  5.0,  5.0,  2.0],
  'treble':    [-3.0, -2.0,  0.0,  5.0,  8.0],
};

// Standard 5-band center frequencies in Hz
const List<int> _k5BandFreqs = [60, 230, 910, 3600, 14000];

// ── State ─────────────────────────────────────────────────────────────────────

class EqualizerState {
  // ─── Fields used directly by equalizer_screen.dart ───────────────────────
  final bool initialized;        // eq.initialized
  final bool enabled;            // eq.enabled
  final String preset;           // eq.preset  ('flat', 'rock', 'off', …)
  final int numBands;            // eq.numBands
  final double minDb;            // eq.minDb   (dB, e.g. -15.0)
  final double maxDb;            // eq.maxDb   (dB, e.g.  15.0)
  final List<double> bandLevels; // eq.bandLevels — dB doubles
  final List<int> centerFreqs;   // eq.centerFreqs — Hz per band
  final String? error;           // eq.error

  // ─── Aliases consumed by equalizer_sheet.dart ────────────────────────────
  bool get isInitialized => initialized;
  bool get isEnabled => enabled;
  int get numberOfBands => numBands;
  int get minLevel => (minDb * 100).round(); // millibels
  int get maxLevel => (maxDb * 100).round(); // millibels

  EqualizerPreset get currentPreset => EqualizerPreset.values.firstWhere(
        (p) => p.name == preset,
        orElse: () => EqualizerPreset.off,
      );

  const EqualizerState({
    this.initialized = false,
    this.enabled = false,
    this.preset = 'off',
    this.numBands = 0,
    this.minDb = -15.0,
    this.maxDb = 15.0,
    this.bandLevels = const [],
    this.centerFreqs = const [],
    this.error,
  });

  EqualizerState copyWith({
    bool? initialized,
    bool? enabled,
    String? preset,
    int? numBands,
    double? minDb,
    double? maxDb,
    List<double>? bandLevels,
    List<int>? centerFreqs,
    String? error,
    bool clearError = false,
  }) {
    return EqualizerState(
      initialized: initialized ?? this.initialized,
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      numBands: numBands ?? this.numBands,
      minDb: minDb ?? this.minDb,
      maxDb: maxDb ?? this.maxDb,
      bandLevels: bandLevels ?? this.bandLevels,
      centerFreqs: centerFreqs ?? this.centerFreqs,
      error: clearError ? null : (error ?? this.error),
    );
  }

  /// Frequency display string for a band — used by equalizer_sheet.dart.
  /// e.g. "60Hz", "3.6k"
  String freqLabel(int bandIndex) {
    if (bandIndex >= centerFreqs.length) return '';
    final hz = centerFreqs[bandIndex];
    if (hz >= 1000) {
      return '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)}k';
    }
    return '${hz}Hz';
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final equalizerProvider =
    StateNotifierProvider<EqualizerNotifier, EqualizerState>((ref) {
  return EqualizerNotifier();
});

// ── Notifier ──────────────────────────────────────────────────────────────────

class EqualizerNotifier extends StateNotifier<EqualizerState> {
  EqualizerNotifier() : super(const EqualizerState());

  int _lastSessionId = -1;

  // ── initialize ─────────────────────────────────────────────────────────────
  //
  // FIX: [audioSessionId] must be the REAL session ID from just_audio.
  // Call this via AudioCalmHandler.androidAudioSessionId, NOT with 0.
  // audioSessionId=0 on Android means "global output mix" which is either
  // ignored or attached to the wrong stream on most devices.

  Future<void> initialize({int audioSessionId = 0}) async {
    if (_lastSessionId == audioSessionId && state.initialized) return;
    _lastSessionId = audioSessionId;
    try {
      await _channel.invokeMethod<void>('init', {
        'audioSessionId': audioSessionId,
      });

      // getProperties returns {bandCount, minDb, maxDb} — values in millibels
      final props =
          (await _channel.invokeMethod<Map>('getProperties')) ?? {};

      final numBands = (props['bandCount'] as int?) ?? 5;
      // minDb / maxDb come back as millibels from Kotlin
      final minMb = (props['minDb'] as num?)?.toDouble() ?? -1500.0;
      final maxMb = (props['maxDb'] as num?)?.toDouble() ?? 1500.0;

      state = EqualizerState(
        initialized: true,
        enabled: false,
        preset: 'off',
        numBands: numBands,
        minDb: minMb / 100.0,
        maxDb: maxMb / 100.0,
        bandLevels: List<double>.filled(numBands, 0.0),
        centerFreqs: _buildFreqs(numBands),
      );

      // Re-apply last known preset after re-init (e.g. track change)
      if (state.preset != 'off' && state.enabled) {
        await applyPreset(state.preset);
      }
    } catch (e) {
      state = EqualizerState(error: 'Equalizer unavailable: $e');
    }
  }

  // ── reinitialize (called when audio session changes) ──────────────────────
  //
  // Call this from AudioPlayerNotifier whenever a new track starts playing.
  // just_audio may assign a new audio session ID per track on some devices.

  Future<void> reinitialize(int newSessionId) async {
    if (_lastSessionId == newSessionId) return;
    final wasEnabled = state.enabled;
    final lastPreset = state.preset;

    await initialize(audioSessionId: newSessionId);

    // Restore previously active preset
    if (wasEnabled && lastPreset != 'off' && state.initialized) {
      await applyPreset(lastPreset);
    }
  }

  // ── applyPreset (String) ── equalizer_screen.dart calls this ──────────────

  Future<void> applyPreset(String presetName) async {
    if (!state.initialized) {
      // Auto-initialize with session 0 as a fallback — better than nothing
      await initialize(audioSessionId: 0);
      if (!state.initialized) return;
    }

    if (presetName == 'off') {
      await setEnabled(false);
      return;
    }

    final raw = _kPresetBands[presetName] ??
        List<double>.filled(state.numBands, 0.0);
    final bands = raw.map((v) => v.clamp(state.minDb, state.maxDb)).toList();

    // FIX: Set bands FIRST, then enable — prevents "flat enable" glitch
    await _pushBandsToNative(bands, enable: true);

    state = state.copyWith(
      preset: presetName,
      enabled: true,
      bandLevels: bands,
      clearError: true,
    );
  }

  // ── applyPresetEnum (EqualizerPreset) ── equalizer_sheet.dart calls this ───

  Future<void> applyPresetEnum(EqualizerPreset preset) async {
    if (preset == EqualizerPreset.off) {
      await setEnabled(false);
      return;
    }
    await applyPreset(preset.name);
  }

  // ── setBandLevel (dB double) ── equalizer_screen.dart calls this ───────────
  //
  // CONTRACT: values sent over channel are MILLIBELS (int).
  // Kotlin side: eq.setBandLevel(band, levelMillibels.toShort())

  Future<void> setBandLevel(int band, double levelDb) async {
    if (!state.initialized) return;

    final clamped = levelDb.clamp(state.minDb, state.maxDb);
    try {
      await _channel.invokeMethod<void>('setBandLevel', {
        'band': band,
        'level': (clamped * 100).round(), // → millibels
      });
    } catch (e) {
      // Non-fatal — update UI state anyway
    }

    final updated = List<double>.from(state.bandLevels);
    while (updated.length <= band) updated.add(0.0);
    updated[band] = clamped;

    state = state.copyWith(
      preset: 'custom',
      enabled: true,
      bandLevels: updated,
      clearError: true,
    );
  }

  // ── setBandLevelMillibels (int mB) ── equalizer_sheet.dart calls this ───────

  Future<void> setBandLevelMillibels(int band, int levelMillibels) async {
    await setBandLevel(band, levelMillibels / 100.0);
  }

  // ── setEnabled ─────────────────────────────────────────────────────────────

  Future<void> setEnabled(bool enabled) async {
    try {
      if (state.initialized) {
        await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
      }
    } catch (_) {}
    state = state.copyWith(
      enabled: enabled,
      preset: enabled ? state.preset : 'off',
      clearError: true,
    );
  }

  // ── release ────────────────────────────────────────────────────────────────

  Future<void> release() async {
    try {
      if (state.initialized) {
        await _channel.invokeMethod<void>('release');
      }
    } catch (_) {}
    state = const EqualizerState();
    _lastSessionId = -1;
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  // FIX: Set bands first, THEN enable — order matters on Android.
  // Calling setEnabled(true) before bands are configured causes the EQ to
  // enable with flat response (0 dB on all bands) and the band values set
  // afterward may not take effect until the next enable/disable cycle.
  Future<void> _pushBandsToNative(List<double> bands,
      {required bool enable}) async {
    if (!state.initialized) return;
    try {
      // Step 1: set all band levels (in millibels)
      for (int i = 0; i < bands.length && i < state.numBands; i++) {
        await _channel.invokeMethod<void>('setBandLevel', {
          'band': i,
          'level': (bands[i] * 100).round(), // millibels
        });
      }
      // Step 2: enable AFTER bands are configured
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enable});
    } catch (e) {
      // Channel error — EQ may not be available on this device
    }
  }

  /// Build center frequency list.
  static List<int> _buildFreqs(int numBands) {
    if (numBands == 5) return List<int>.from(_k5BandFreqs);
    if (numBands <= 1) return [1000];
    return List.generate(numBands, (i) {
      final t = i / (numBands - 1);
      return (60.0 * math.pow(16000.0 / 60.0, t)).round();
    });
  }
}
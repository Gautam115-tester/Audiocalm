// lib/features/player/services/equalizer_service.dart
//
// Bridges to Android's native AudioEffect equalizer via MethodChannel.
// State fields satisfy BOTH equalizer_screen.dart AND equalizer_sheet.dart.
//
// FIXES
// =====
// FIX 1 — setAudioSessionId(int id)
//   New public method called by AudioCalmHandler whenever the underlying
//   just_audio AudioPlayer changes (new track, player swap after gapless
//   transition). Re-initialises the native AudioEffect on the correct session.
//   Without this the EQ binds to session 0 (global mix) which silently fails
//   on Android 10+.
//
// FIX 2 — initialize() now awaits re-enable after re-init
//   When called with a real session ID after a previous init, it releases the
//   old effect, re-inits, and re-applies the last preset so the user doesn't
//   have to toggle the switch again.
//
// FIX 3 — release() guard
//   Only calls the native 'release' channel if actually initialised, avoiding
//   a crash when the sheet opens before the first track starts.

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
  final bool initialized;
  final bool enabled;
  final String preset;
  final int numBands;
  final double minDb;
  final double maxDb;
  final List<double> bandLevels;
  final List<int> centerFreqs;
  final String? error;

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
      enabled:     enabled     ?? this.enabled,
      preset:      preset      ?? this.preset,
      numBands:    numBands    ?? this.numBands,
      minDb:       minDb       ?? this.minDb,
      maxDb:       maxDb       ?? this.maxDb,
      bandLevels:  bandLevels  ?? this.bandLevels,
      centerFreqs: centerFreqs ?? this.centerFreqs,
      error:       clearError ? null : (error ?? this.error),
    );
  }

  /// Frequency display string for a band — used by equalizer_sheet.dart.
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

  // Tracks the last real session ID so we can re-init on player swap.
  int _lastSessionId = 0;

  // ── FIX 1 — setAudioSessionId ─────────────────────────────────────────────
  //
  // Called by AudioCalmHandler whenever its underlying AudioPlayer changes.
  // Re-initialises the native AudioEffect on the new session and re-applies
  // whatever preset the user had selected.

  Future<void> setAudioSessionId(int sessionId) async {
    if (sessionId <= 0) return;
    if (sessionId == _lastSessionId && state.initialized) return;

    _lastSessionId = sessionId;

    // Remember current settings so we can restore them after re-init.
    final wasEnabled = state.enabled;
    final lastPreset = state.preset;
    final lastBands  = List<double>.from(state.bandLevels);

    // FIX 3 — only release if we were actually initialised.
    if (state.initialized) {
      try {
        await _channel.invokeMethod<void>('release');
      } catch (_) {}
    }

    // Re-initialise on the new session.
    await initialize(audioSessionId: sessionId);

    // FIX 2 — restore previous EQ state after re-init.
    if (!mounted) return;
    if (wasEnabled && lastPreset != 'off' && lastPreset != 'custom') {
      await applyPreset(lastPreset);
    } else if (wasEnabled && lastPreset == 'custom' && lastBands.isNotEmpty) {
      await _pushBandsToNative(lastBands, enable: true);
      state = state.copyWith(
        preset:     'custom',
        enabled:    true,
        bandLevels: lastBands,
        clearError: true,
      );
    }
    // If it was off, leave it off — no need to do anything.
  }

  // ── initialize ─────────────────────────────────────────────────────────────

  Future<void> initialize({int audioSessionId = 0}) async {
    // Use the last known real session if called with 0.
    final sessionId = audioSessionId > 0 ? audioSessionId : _lastSessionId;

    try {
      await _channel.invokeMethod<void>('init', {
        'audioSessionId': sessionId,
      });

      final props =
          (await _channel.invokeMethod<Map>('getProperties')) ?? {};

      final numBands = (props['bandCount'] as int?) ?? 5;
      final minMb    = (props['minDb']     as num?)?.toDouble() ?? -1500.0;
      final maxMb    = (props['maxDb']     as num?)?.toDouble() ??  1500.0;

      state = EqualizerState(
        initialized: true,
        enabled:     false,
        preset:      'off',
        numBands:    numBands,
        minDb:       minMb / 100.0,
        maxDb:       maxMb / 100.0,
        bandLevels:  List<double>.filled(numBands, 0.0),
        centerFreqs: _buildFreqs(numBands),
      );
    } catch (e) {
      state = EqualizerState(error: 'Equalizer unavailable: $e');
    }
  }

  // ── applyPreset (String) ── equalizer_screen.dart calls this ──────────────

  Future<void> applyPreset(String presetName) async {
    if (presetName == 'off') {
      await setEnabled(false);
      return;
    }
    final raw = _kPresetBands[presetName] ??
        List<double>.filled(state.numBands, 0.0);
    final bands =
        raw.map((v) => v.clamp(state.minDb, state.maxDb)).toList();

    await _pushBandsToNative(bands, enable: true);

    state = state.copyWith(
      preset:     presetName,
      enabled:    true,
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

  Future<void> setBandLevel(int band, double levelDb) async {
    final clamped = levelDb.clamp(state.minDb, state.maxDb);
    try {
      if (state.initialized) {
        await _channel.invokeMethod<void>('setBandLevel', {
          'band':  band,
          'level': (clamped * 100).round(),
        });
      }
    } catch (_) {}

    final updated = List<double>.from(state.bandLevels);
    while (updated.length <= band) updated.add(0.0);
    updated[band] = clamped;

    state = state.copyWith(
      preset:     'custom',
      enabled:    true,
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
        await _channel.invokeMethod<void>('setEnabled',
            {'enabled': enabled});
      }
    } catch (_) {}
    state = state.copyWith(
      enabled:    enabled,
      preset:     enabled ? state.preset : 'off',
      clearError: true,
    );
  }

  // ── release ────────────────────────────────────────────────────────────────

  Future<void> release() async {
    // FIX 3 — guard against releasing when never initialised.
    if (!state.initialized) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
    state = const EqualizerState();
    _lastSessionId = 0;
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  Future<void> _pushBandsToNative(List<double> bands,
      {required bool enable}) async {
    if (!state.initialized) return;
    try {
      for (int i = 0; i < bands.length && i < state.numBands; i++) {
        await _channel.invokeMethod<void>('setBandLevel', {
          'band':  i,
          'level': (bands[i] * 100).round(),
        });
      }
      await _channel.invokeMethod<void>('setEnabled',
          {'enabled': enable});
    } catch (_) {}
  }

  static List<int> _buildFreqs(int numBands) {
    if (numBands == 5) return List<int>.from(_k5BandFreqs);
    if (numBands <= 1) return [1000];
    return List.generate(numBands, (i) {
      final t = i / (numBands - 1);
      return (60.0 * math.pow(16000.0 / 60.0, t)).round();
    });
  }
}
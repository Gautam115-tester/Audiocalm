// lib/features/player/services/equalizer_service.dart

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../../core/constants/app_constants.dart';

class EqualizerState {
  final bool enabled;
  final int presetIndex;
  final List<double> bands; // dB values per band
  final int bandCount;
  final double minDb;
  final double maxDb;

  const EqualizerState({
    this.enabled = false,
    this.presetIndex = 0,
    this.bands = const [0, 0, 0, 0, 0],
    this.bandCount = 5,
    this.minDb = -15.0,
    this.maxDb = 15.0,
  });

  EqualizerState copyWith({
    bool? enabled,
    int? presetIndex,
    List<double>? bands,
    int? bandCount,
    double? minDb,
    double? maxDb,
  }) =>
      EqualizerState(
        enabled: enabled ?? this.enabled,
        presetIndex: presetIndex ?? this.presetIndex,
        bands: bands ?? this.bands,
        bandCount: bandCount ?? this.bandCount,
        minDb: minDb ?? this.minDb,
        maxDb: maxDb ?? this.maxDb,
      );
}

// Preset band values [60Hz, 230Hz, 910Hz, 3.6kHz, 14kHz]
const Map<String, List<double>> _presetValues = {
  'Flat': [0, 0, 0, 0, 0],
  'Rock': [5, 3, -1, 3, 5],
  'Pop': [-1, 3, 5, 3, -1],
  'Jazz': [4, 2, -1, 2, 4],
  'Classical': [5, 3, -2, 3, 4],
  'Bass': [8, 6, 0, -2, -3],
  'Ultra Bass': [10, 8, 2, -3, -5],
  'Vocal': [-3, 0, 5, 5, 2],
  'Treble': [-3, -2, 0, 5, 8],
  'Custom': [0, 0, 0, 0, 0],
};

class EqualizerService extends StateNotifier<EqualizerState> {
  static const _channel =
      MethodChannel(AppConstants.equalizerChannel);

  EqualizerService() : super(const EqualizerState()) {
    _loadSavedState();
  }

  Future<void> _loadSavedState() async {
    try {
      final box = Hive.box(AppConstants.settingsBox);
      final enabled = box.get(AppConstants.eqEnabledKey, defaultValue: false) as bool;
      final presetIndex = box.get(AppConstants.eqPresetKey, defaultValue: 0) as int;
      final savedBands = box.get(AppConstants.eqBandsKey) as List?;
      final bands = savedBands?.cast<double>() ?? List.filled(5, 0.0);

      // Try to get band count from native
      try {
        final result = await _channel.invokeMethod<Map>('getProperties');
        if (result != null) {
          final bandCount = result['bandCount'] as int? ?? 5;
          final minDb = (result['minDb'] as num?)?.toDouble() ?? -15.0;
          final maxDb = (result['maxDb'] as num?)?.toDouble() ?? 15.0;
          state = EqualizerState(
            enabled: enabled,
            presetIndex: presetIndex,
            bands: bands,
            bandCount: bandCount,
            minDb: minDb,
            maxDb: maxDb,
          );
        }
      } catch (_) {
        state = EqualizerState(
          enabled: enabled,
          presetIndex: presetIndex,
          bands: bands,
        );
      }

      if (enabled) {
        await _applyBands(bands);
      }
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': value});
      state = state.copyWith(enabled: value);
      Hive.box(AppConstants.settingsBox).put(AppConstants.eqEnabledKey, value);
    } catch (_) {
      state = state.copyWith(enabled: value);
    }
  }

  Future<void> applyPreset(int index) async {
    final presetName = AppConstants.equalizerPresets[index];
    final bands = List<double>.from(
      _presetValues[presetName] ?? List.filled(state.bandCount, 0.0),
    );

    state = state.copyWith(presetIndex: index, bands: bands);
    await _applyBands(bands);

    final box = Hive.box(AppConstants.settingsBox);
    box.put(AppConstants.eqPresetKey, index);
    box.put(AppConstants.eqBandsKey, bands);
  }

  Future<void> setBandDb(int bandIndex, double db) async {
    final newBands = List<double>.from(state.bands);
    if (bandIndex < newBands.length) {
      newBands[bandIndex] = db.clamp(state.minDb, state.maxDb);
    }

    // Switch to custom preset when manually adjusting
    final customIndex = AppConstants.equalizerPresets.indexOf('Custom');
    state = state.copyWith(
      bands: newBands,
      presetIndex: customIndex >= 0 ? customIndex : state.presetIndex,
    );

    await _applyBands(newBands);
    Hive.box(AppConstants.settingsBox).put(AppConstants.eqBandsKey, newBands);
  }

  Future<void> _applyBands(List<double> bands) async {
    try {
      for (int i = 0; i < bands.length; i++) {
        await _channel.invokeMethod('setBandLevel', {
          'band': i,
          'level': (bands[i] * 100).toInt(), // millibels
        });
      }
    } catch (_) {
      // iOS no-op or equalizer not available
    }
  }

  Future<void> reset() async {
    await applyPreset(0); // Flat
  }
}

final equalizerServiceProvider =
    StateNotifierProvider<EqualizerService, EqualizerState>(
  (ref) => EqualizerService(),
);

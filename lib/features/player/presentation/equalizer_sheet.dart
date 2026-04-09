// lib/features/player/presentation/equalizer_sheet.dart
//
// Bottom sheet equalizer UI for music playback.
// Shows preset chips + vertical band sliders.
// Matches the existing AppColors-based theme of the project.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../services/equalizer_service.dart';

class EqualizerSheet extends ConsumerStatefulWidget {
  const EqualizerSheet({super.key});

  @override
  ConsumerState<EqualizerSheet> createState() => _EqualizerSheetState();
}

class _EqualizerSheetState extends ConsumerState<EqualizerSheet> {
  bool _initializing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureInitialized());
  }

  Future<void> _ensureInitialized() async {
    final eq = ref.read(equalizerProvider);
    if (!eq.isInitialized && !_initializing) {
      setState(() => _initializing = true);
      await ref.read(equalizerProvider.notifier).initialize();
      if (mounted) setState(() => _initializing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(equalizerProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.50,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // ── Handle ──────────────────────────────────────────────────
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // ── Header ──────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.equalizer_rounded,
                        color: AppColors.primary, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      'Equalizer',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Spacer(),
                    if (eq.isInitialized) ...[
                      Text(
                        eq.isEnabled ? 'ON' : 'OFF',
                        style: TextStyle(
                          color: eq.isEnabled
                              ? AppColors.primary
                              : AppColors.textTertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Switch(
                        value: eq.isEnabled,
                        activeColor: AppColors.primary,
                        inactiveThumbColor: AppColors.textTertiary,
                        inactiveTrackColor: AppColors.surfaceVariant,
                        onChanged: (v) {
                          if (v) {
                            // Re-enable with last preset, or fall back to flat
                            final p = eq.currentPreset == EqualizerPreset.off
                                ? EqualizerPreset.flat
                                : eq.currentPreset;
                            ref
                                .read(equalizerProvider.notifier)
                                .applyPresetEnum(p);
                          } else {
                            ref
                                .read(equalizerProvider.notifier)
                                .applyPresetEnum(EqualizerPreset.off);
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),

              const Divider(height: 1),

              // ── Body ─────────────────────────────────────────────────────
              if (_initializing || !eq.isInitialized)
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: AppColors.primary),
                        SizedBox(height: 16),
                        Text(
                          'Initializing equalizer…',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    children: [
                      // Preset chips
                      _PresetChips(
                        currentPreset: eq.currentPreset,
                        isEnabled: eq.isEnabled,
                        onPreset: (p) => ref
                            .read(equalizerProvider.notifier)
                            .applyPresetEnum(p),
                      ),

                      const SizedBox(height: 24),

                      // Band sliders
                      if (eq.numberOfBands > 0)
                        _BandSliders(
                          eqState: eq,
                          isEnabled: eq.isEnabled,
                          // sheet passes millibels → service converts to dB
                          onBandChanged: (band, levelMb) => ref
                              .read(equalizerProvider.notifier)
                              .setBandLevelMillibels(band, levelMb),
                        )
                      else
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No equalizer bands available on this device.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: AppColors.textTertiary, fontSize: 13),
                            ),
                          ),
                        ),

                      const SizedBox(height: 16),

                      // Range info
                      Center(
                        child: Text(
                          'Range: ${(eq.minLevel / 100).toStringAsFixed(0)} dB '
                          'to ${(eq.maxLevel / 100).toStringAsFixed(0)} dB',
                          style: const TextStyle(
                              color: AppColors.textTertiary, fontSize: 11),
                        ),
                      ),

                      const SizedBox(height: 24),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ── Preset chips ──────────────────────────────────────────────────────────────

class _PresetChips extends StatelessWidget {
  final EqualizerPreset currentPreset;
  final bool isEnabled;
  final void Function(EqualizerPreset) onPreset;

  const _PresetChips({
    required this.currentPreset,
    required this.isEnabled,
    required this.onPreset,
  });

  @override
  Widget build(BuildContext context) {
    // Show all except 'custom' — that's set via manual band drag.
    final presets =
        EqualizerPreset.values.where((p) => p != EqualizerPreset.custom).toList();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: presets.map((preset) {
        final isSelected = currentPreset == preset &&
            (isEnabled || preset == EqualizerPreset.off);
        return GestureDetector(
          onTap: () => onPreset(preset),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : AppColors.cardColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected
                    ? AppColors.primary
                    : AppColors.textTertiary.withOpacity(0.3),
                width: 1.5,
              ),
            ),
            child: Text(
              preset.label,
              style: TextStyle(
                color: isSelected ? Colors.white : AppColors.textSecondary,
                fontSize: 12,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Band sliders ──────────────────────────────────────────────────────────────

class _BandSliders extends StatelessWidget {
  final EqualizerState eqState;
  final bool isEnabled;
  // levelMillibels is int (sheet sends mB to service)
  final void Function(int band, int levelMillibels) onBandChanged;

  const _BandSliders({
    required this.eqState,
    required this.isEnabled,
    required this.onBandChanged,
  });

  @override
  Widget build(BuildContext context) {
    final numBands = eqState.numberOfBands;
    // Slider works in millibels (int range)
    final minLevel = eqState.minLevel.toDouble();
    final maxLevel = eqState.maxLevel.toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'BANDS',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(
          height: 220,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List.generate(numBands, (bandIdx) {
              // bandLevels stores dB; convert to mB for the slider
              final levelDb = bandIdx < eqState.bandLevels.length
                  ? eqState.bandLevels[bandIdx]
                  : 0.0;
              final levelMb = (levelDb * 100).round().toDouble();
              final freqLabel = eqState.freqLabel(bandIdx);
              // Display label in dB
              final dbLabel = levelDb.toStringAsFixed(1);

              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    children: [
                      // dB label at top
                      Text(
                        '${levelDb >= 0 ? '+' : ''}$dbLabel',
                        style: TextStyle(
                          color: isEnabled
                              ? AppColors.primary
                              : AppColors.textTertiary,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Vertical slider (rotated)
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              activeTrackColor: isEnabled
                                  ? AppColors.primary
                                  : AppColors.textTertiary,
                              inactiveTrackColor: AppColors.surfaceVariant,
                              thumbColor: isEnabled
                                  ? Colors.white
                                  : AppColors.textTertiary,
                              overlayColor:
                                  AppColors.primary.withOpacity(0.2),
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7),
                            ),
                            child: Slider(
                              value: levelMb.clamp(minLevel, maxLevel),
                              min: minLevel,
                              max: maxLevel,
                              divisions:
                                  ((maxLevel - minLevel) / 100).round(),
                              onChanged: isEnabled
                                  ? (v) =>
                                      onBandChanged(bandIdx, v.round())
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Frequency label at bottom
                      Text(
                        freqLabel,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 9,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}
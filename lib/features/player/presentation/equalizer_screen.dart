// lib/features/player/presentation/equalizer_screen.dart
//
// Full-screen equalizer UI (opened from player options menu).
// Uses AppColors from the project theme — NOT AppTheme.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../services/equalizer_service.dart';

class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});

  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final eq = ref.read(equalizerProvider);
      if (!eq.initialized) {
        ref.read(equalizerProvider.notifier).initialize();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(equalizerProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded,
              color: AppColors.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: const Text('Equalizer'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  eq.enabled ? 'ON' : 'OFF',
                  style: TextStyle(
                    color: eq.enabled
                        ? AppColors.primary
                        : AppColors.textTertiary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 6),
                Switch(
                  value: eq.enabled,
                  activeColor: AppColors.primary,
                  onChanged: (v) =>
                      ref.read(equalizerProvider.notifier).setEnabled(v),
                ),
              ],
            ),
          ),
        ],
      ),
      body: eq.initialized ? _EqBody(eq: eq) : _LoadingBody(eq: eq),
    );
  }
}

// ── Loading / error state ─────────────────────────────────────────────────────

class _LoadingBody extends ConsumerWidget {
  final EqualizerState eq;
  const _LoadingBody({required this.eq});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (eq.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: AppColors.error, size: 48),
            const SizedBox(height: 12),
            Text(
              eq.error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () =>
                  ref.read(equalizerProvider.notifier).initialize(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    return const Center(
      child: CircularProgressIndicator(color: AppColors.primary),
    );
  }
}

// ── Main body ─────────────────────────────────────────────────────────────────

class _EqBody extends ConsumerWidget {
  final EqualizerState eq;
  const _EqBody({required this.eq});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Preset chips ────────────────────────────────────────────────
          const _SectionLabel(text: 'PRESETS'),
          const SizedBox(height: 10),
          _PresetRow(currentPreset: eq.preset, enabled: eq.enabled),
          const SizedBox(height: 28),

          // ── Band sliders ────────────────────────────────────────────────
          const _SectionLabel(text: 'FREQUENCY BANDS'),
          const SizedBox(height: 4),
          if (eq.numBands == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'No EQ bands available on this device',
                  style: TextStyle(color: AppColors.textTertiary),
                ),
              ),
            )
          else
            _BandSliders(eq: eq),

          const SizedBox(height: 20),

          // ── Active preset badge ─────────────────────────────────────────
          if (eq.enabled)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: AppColors.primary.withOpacity(0.4)),
                ),
                child: Text(
                  'Active: ${eq.preset.toUpperCase()}',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ── Preset chips ──────────────────────────────────────────────────────────────

class _PresetRow extends ConsumerWidget {
  final String currentPreset;
  final bool enabled;
  const _PresetRow({required this.currentPreset, required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: kEqPresets.map((preset) {
        final isOff = preset == 'off';
        final isSelected = (currentPreset == preset) &&
            (isOff ? !enabled : enabled);

        return GestureDetector(
          onTap: () async {
            if (isOff) {
              await ref.read(equalizerProvider.notifier).setEnabled(false);
            } else {
              await ref.read(equalizerProvider.notifier).applyPreset(preset);
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: isSelected
                  ? (isOff ? AppColors.cardColor : AppColors.primary)
                  : AppColors.cardColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isSelected
                    ? (isOff
                        ? AppColors.textTertiary
                        : AppColors.primary)
                    : AppColors.surfaceVariant,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Text(
              _presetLabel(preset),
              style: TextStyle(
                color: isSelected
                    ? (isOff ? AppColors.textPrimary : Colors.white)
                    : AppColors.textSecondary,
                fontSize: 13,
                fontWeight:
                    isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  String _presetLabel(String p) {
    switch (p) {
      case 'off':       return '✕ Off';
      case 'flat':      return '▬ Flat';
      case 'bass':      return '🔊 Bass';
      case 'ultrabass': return '💥 Ultra Bass';
      case 'rock':      return '🎸 Rock';
      case 'pop':       return '🎵 Pop';
      case 'jazz':      return '🎷 Jazz';
      case 'classical': return '🎻 Classical';
      case 'vocal':     return '🎤 Vocal';
      case 'treble':    return '🔔 Treble';
      default:          return p;
    }
  }
}

// ── Band sliders ──────────────────────────────────────────────────────────────

class _BandSliders extends ConsumerStatefulWidget {
  final EqualizerState eq;
  const _BandSliders({required this.eq});

  @override
  ConsumerState<_BandSliders> createState() => _BandSlidersState();
}

class _BandSlidersState extends ConsumerState<_BandSliders> {
  // Local drag state so the UI is snappy; committed to native on drag end.
  late List<double> _localLevels;

  @override
  void initState() {
    super.initState();
    // bandLevels are already in dB; copy directly.
    _localLevels = List<double>.from(widget.eq.bandLevels);
  }

  @override
  void didUpdateWidget(_BandSliders old) {
    super.didUpdateWidget(old);
    if (old.eq.bandLevels != widget.eq.bandLevels) {
      _localLevels = List<double>.from(widget.eq.bandLevels);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eq = widget.eq;
    if (eq.numBands == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 20),
      decoration: BoxDecoration(
        color: AppColors.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surfaceVariant),
      ),
      child: Column(
        children: [
          // dB ruler labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${eq.maxDb.toStringAsFixed(0)} dB',
                  style: const TextStyle(
                      color: AppColors.textTertiary, fontSize: 10)),
              const Text('0 dB',
                  style: TextStyle(
                      color: AppColors.textTertiary, fontSize: 10)),
              Text('${eq.minDb.toStringAsFixed(0)} dB',
                  style: const TextStyle(
                      color: AppColors.textTertiary, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 8),

          // Band sliders in a row
          SizedBox(
            height: 200,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(eq.numBands, (i) {
                final freqLabel = _freqLabel(
                  i < eq.centerFreqs.length ? eq.centerFreqs[i] : 0,
                );
                final level =
                    i < _localLevels.length ? _localLevels[i] : 0.0;
                final isActive = eq.enabled && level != 0.0;

                return Expanded(
                  child: Column(
                    children: [
                      // dB value above slider
                      Text(
                        '${level >= 0 ? '+' : ''}${level.toStringAsFixed(1)}',
                        style: TextStyle(
                          color: isActive
                              ? AppColors.primary
                              : AppColors.textTertiary,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // Vertical slider
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              activeTrackColor: isActive
                                  ? AppColors.primary
                                  : AppColors.surfaceVariant,
                              inactiveTrackColor: AppColors.surfaceVariant,
                              thumbColor: isActive
                                  ? AppColors.primary
                                  : AppColors.textTertiary,
                              overlayColor:
                                  AppColors.primary.withOpacity(0.2),
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7),
                              trackShape:
                                  const RoundedRectSliderTrackShape(),
                            ),
                            child: Slider(
                              min: eq.minDb,
                              max: eq.maxDb,
                              value: level.clamp(eq.minDb, eq.maxDb),
                              onChanged: eq.enabled
                                  ? (v) => setState(() {
                                        if (i < _localLevels.length) {
                                          _localLevels[i] = v;
                                        }
                                      })
                                  : null,
                              onChangeEnd: eq.enabled
                                  ? (v) => ref
                                      .read(equalizerProvider.notifier)
                                      // screen works in dB (double)
                                      .setBandLevel(i, v)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      // Frequency label
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
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  String _freqLabel(int hz) {
    if (hz == 0) return '?';
    if (hz >= 1000) {
      return '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)}k';
    }
    return '$hz';
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textTertiary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    );
  }
}

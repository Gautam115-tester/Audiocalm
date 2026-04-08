// lib/features/player/presentation/equalizer_sheet.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/equalizer_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/constants/app_constants.dart';

class EqualizerSheet extends ConsumerWidget {
  const EqualizerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eqState = ref.watch(equalizerServiceProvider);
    final eqService = ref.read(equalizerServiceProvider.notifier);

    final bandLabels = ['60Hz', '230Hz', '910Hz', '3.6K', '14K'];

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      decoration: const BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textTertiary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                const Icon(Icons.equalizer_rounded, color: AppColors.primary),
                const SizedBox(width: 10),
                Text(
                  'Equalizer',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const Spacer(),
                Switch(
                  value: eqState.enabled,
                  onChanged: eqService.setEnabled,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Presets horizontal scroll
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: AppConstants.equalizerPresets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final preset = AppConstants.equalizerPresets[i];
                final selected = eqState.presetIndex == i;
                return GestureDetector(
                  onTap: () => eqService.applyPreset(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primary
                          : AppColors.cardColor,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected
                            ? AppColors.primary
                            : AppColors.textTertiary.withOpacity(0.3),
                      ),
                    ),
                    child: Text(
                      preset,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: selected
                                ? Colors.white
                                : AppColors.textSecondary,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 24),

          // Band sliders
          AbsorbPointer(
            absorbing: !eqState.enabled,
            child: AnimatedOpacity(
              opacity: eqState.enabled ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 200),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(
                    eqState.bandCount.clamp(0, bandLabels.length),
                    (i) => Expanded(
                      child: _BandSlider(
                        label: i < bandLabels.length ? bandLabels[i] : '?',
                        value: i < eqState.bands.length ? eqState.bands[i] : 0,
                        minDb: eqState.minDb,
                        maxDb: eqState.maxDb,
                        onChanged: (v) => eqService.setBandDb(i, v),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Reset button
          TextButton.icon(
            onPressed: eqService.reset,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset to Flat'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
          ),

          SizedBox(
              height: MediaQuery.of(context).padding.bottom +
                  16),
        ],
      ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  final String label;
  final double value;
  final double minDb;
  final double maxDb;
  final void Function(double) onChanged;

  const _BandSlider({
    required this.label,
    required this.value,
    required this.minDb,
    required this.maxDb,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.primary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 140,
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: AppColors.cardColor,
                thumbColor: Colors.white,
                overlayColor: AppColors.primary.withOpacity(0.15),
              ),
              child: Slider(
                value: value.clamp(minDb, maxDb),
                min: minDb,
                max: maxDb,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 9,
                color: AppColors.textTertiary,
              ),
        ),
      ],
    );
  }
}

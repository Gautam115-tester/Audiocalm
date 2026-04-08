// lib/features/player/presentation/mini_player.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/audio_player_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(audioPlayerProvider);

    if (!playerState.hasMedia) return const SizedBox.shrink();

    final item = playerState.currentItem!;

    return GestureDetector(
      onTap: () => AppRouter.navigateToPlayer(context),
      child: Container(
        height: 68,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.primary.withOpacity(0.2),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            // Progress bar
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: LinearProgressIndicator(
                value: playerState.duration != null &&
                        playerState.duration!.inMilliseconds > 0
                    ? playerState.position.inMilliseconds /
                        playerState.duration!.inMilliseconds
                    : 0,
                backgroundColor: Colors.transparent,
                color: AppColors.primary,
                minHeight: 2,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    // Cover
                    CoverImage(
                      url: item.artworkUrl,
                      size: 42,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 12),

                    // Title and subtitle
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (item.subtitle != null)
                            Text(
                              item.subtitle!,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontSize: 11),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),

                    // Controls
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MiniControlButton(
                          icon: Icons.skip_previous_rounded,
                          onTap: () => ref
                              .read(audioPlayerProvider.notifier)
                              .skipToPrevious(),
                          size: 20,
                        ),
                        const SizedBox(width: 4),
                        _PlayPauseButton(
                          isPlaying: playerState.isPlaying,
                          isLoading: playerState.isLoading,
                          onTap: () => ref
                              .read(audioPlayerProvider.notifier)
                              .togglePlayPause(),
                        ),
                        const SizedBox(width: 4),
                        _MiniControlButton(
                          icon: Icons.skip_next_rounded,
                          onTap: () => ref
                              .read(audioPlayerProvider.notifier)
                              .skipToNext(),
                          size: 20,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onTap;

  const _PlayPauseButton({
    required this.isPlaying,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: isLoading
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 20,
              ),
      ),
    );
  }
}

class _MiniControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _MiniControlButton({
    required this.icon,
    required this.onTap,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: size, color: AppColors.textSecondary),
      ),
    );
  }
}
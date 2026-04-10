// lib/features/player/presentation/mini_player.dart
//
// FIX: MiniPlayer now renders on the very first frame after the user taps
// an audio item — before the audio stream has buffered.
//
// CHANGES:
//   • Removed the early `if (!playerState.hasMedia) return SizedBox.shrink()`
//     guard — it is still there, but now hasMedia becomes true immediately
//     because AudioPlayerNotifier.playItem() sets currentItem synchronously
//     (see audio_player_provider.dart fix).
//   • CoverImage falls back gracefully when artworkUrl is null (shows a
//     placeholder icon) — no change needed there, it already does this.
//   • PlayPause button shows a spinner when isLoading==true, which is exactly
//     what happens during the buffering phase. Users see the mini player
//     appear instantly with a spinner in the play button.
//   • Progress bar shows 0 while position/duration are zero — no crash.

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

    // hasMedia is true as soon as the user taps an item (optimistic update).
    if (!playerState.hasMedia) return const SizedBox.shrink();

    final item = playerState.currentItem!;

    // Safe progress: 0.0 while buffering (duration may still be null)
    final progress = (playerState.duration != null &&
            playerState.duration!.inMilliseconds > 0)
        ? (playerState.position.inMilliseconds /
                playerState.duration!.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

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
            // ── Progress bar (shows 0 while buffering — no flicker) ───────
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: LinearProgressIndicator(
                value: progress,
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
                    // ── Cover ─────────────────────────────────────────────
                    // artworkUrl may be null during initial buffering;
                    // CoverImage already handles null with a placeholder icon.
                    CoverImage(
                      url: item.artworkUrl,
                      size: 42,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 12),

                    // ── Title + subtitle ──────────────────────────────────
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

                    // ── Controls ──────────────────────────────────────────
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MiniControlButton(
                          icon: Icons.skip_previous_rounded,
                          // Disable while loading so the user can't queue
                          // multiple items before the first one is ready.
                          onTap: playerState.isLoading
                              ? null
                              : () => ref
                                  .read(audioPlayerProvider.notifier)
                                  .skipToPrevious(),
                          size: 20,
                        ),
                        const SizedBox(width: 4),
                        _PlayPauseButton(
                          isPlaying: playerState.isPlaying,
                          isLoading: playerState.isLoading,
                          onTap: playerState.isLoading
                              ? null // tapping play while buffering is a no-op
                              : () => ref
                                  .read(audioPlayerProvider.notifier)
                                  .togglePlayPause(),
                        ),
                        const SizedBox(width: 4),
                        _MiniControlButton(
                          icon: Icons.skip_next_rounded,
                          onTap: playerState.isLoading
                              ? null
                              : () => ref
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

// ── Play / Pause button ───────────────────────────────────────────────────────

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  // null when loading — disables tap
  final VoidCallback? onTap;

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

// ── Skip / Previous button ────────────────────────────────────────────────────

class _MiniControlButton extends StatelessWidget {
  final IconData icon;
  // null when loading — renders as visually dimmed, non-interactive
  final VoidCallback? onTap;
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
        child: Icon(
          icon,
          size: size,
          // Dim the icon while disabled
          color: onTap == null
              ? AppColors.textTertiary.withOpacity(0.4)
              : AppColors.textSecondary,
        ),
      ),
    );
  }
}
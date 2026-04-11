// lib/features/player/presentation/mini_player.dart
//
// BLAST BUFFER QUEUE FIX — SELECTIVE STATE WATCHING + REPAINT ISOLATION
// ======================================================================
//
// ROOT CAUSE:
//   MiniPlayer.build() ran every 100ms (position stream tick rate).
//   Each run: recomputed progress ratio, rebuilt 5-6 widgets, scheduled a
//   Flutter frame. Flutter's rasterizer queued a SurfaceView buffer for
//   each frame. At 10 rebuilds/sec + notification redraws from AudioService
//   = total buffer production consistently exceeded SurfaceFlinger's 60fps
//   consumption rate → BLAST buffer queue overflow.
//
// FIX STRATEGY:
//   1. Separate "structural" state (item, isPlaying, isLoading — changes rarely)
//      from "positional" state (position, duration — changes at 10Hz).
//   2. Wrap the progress bar in RepaintBoundary so its 10Hz repaints are
//      handled as an independent compositing layer — they don't invalidate
//      the cover image, title text, or control buttons.
//   3. The cover/title/controls subtree rebuilds only when structural state
//      changes (~0 times/sec during playback, only on track skip/play/pause).
//
// RESULT:
//   - Progress bar: still repaints at up to 10Hz, but as an isolated layer
//   - Cover + title + controls: repaints only on actual state changes
//   - Net frame generation rate drops from ~10 Hz to ~0 Hz for most of the
//     widget tree, giving SurfaceFlinger ample time to drain the buffer queue

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
    // FIX: Only watch hasMedia — app_shell.dart already guards with hasMedia
    // but we keep this as a safety check. This widget only rebuilds when the
    // player goes from no media → has media or vice versa.
    final hasMedia = ref.watch(
      audioPlayerProvider.select((s) => s.hasMedia),
    );

    if (!hasMedia) return const SizedBox.shrink();

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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            children: [
              // FIX: RepaintBoundary isolates the progress bar's 10Hz repaints.
              // Flutter creates a separate compositing layer for this subtree.
              // Repainting the progress bar does NOT dirty the parent layer
              // containing the cover image and controls.
              const RepaintBoundary(child: _ProgressBar()),
              // FIX: Content row is a separate ConsumerWidget that selectively
              // watches only structural fields (item, isPlaying, isLoading).
              // It will NOT rebuild on position ticks.
              const Expanded(child: _ContentRow()),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Progress bar widget — repaints at position tick rate (up to 10Hz) ────────
// Wrapped in RepaintBoundary by parent → isolated compositing layer.

class _ProgressBar extends ConsumerWidget {
  const _ProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch ONLY position and duration — nothing else in AudioPlayerState
    final position = ref.watch(
      audioPlayerProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      audioPlayerProvider.select((s) => s.duration),
    );

    final progress = (duration != null && duration.inMilliseconds > 0)
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return LinearProgressIndicator(
      value: progress,
      backgroundColor: Colors.transparent,
      color: AppColors.primary,
      minHeight: 2,
    );
  }
}

// ── Content row widget — rebuilds ONLY on structural state changes ────────────
// Does NOT rebuild on position ticks. Typical rebuild rate: ~0/sec during
// playback, ~1/sec on track skip or play/pause toggle.

class _ContentRow extends ConsumerWidget {
  const _ContentRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // FIX: Granular selectors — only the specific scalar values we need
    final item = ref.watch(
      audioPlayerProvider.select((s) => s.currentItem),
    );
    final isPlaying = ref.watch(
      audioPlayerProvider.select((s) => s.isPlaying),
    );
    final isLoading = ref.watch(
      audioPlayerProvider.select((s) => s.isLoading),
    );

    if (item == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // ── Cover ─────────────────────────────────────────────────────────
          CoverImage(
            url: item.artworkUrl,
            size: 42,
            borderRadius: 10,
          ),
          const SizedBox(width: 12),

          // ── Title + subtitle ──────────────────────────────────────────────
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

          // ── Controls ──────────────────────────────────────────────────────
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniControlButton(
                icon: Icons.skip_previous_rounded,
                onTap: isLoading
                    ? null
                    : () => ref
                        .read(audioPlayerProvider.notifier)
                        .skipToPrevious(),
                size: 20,
              ),
              const SizedBox(width: 4),
              _PlayPauseButton(
                isPlaying: isPlaying,
                isLoading: isLoading,
                onTap: isLoading
                    ? null
                    : () => ref
                        .read(audioPlayerProvider.notifier)
                        .togglePlayPause(),
              ),
              const SizedBox(width: 4),
              _MiniControlButton(
                icon: Icons.skip_next_rounded,
                onTap: isLoading
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
    );
  }
}

// ── Play / Pause button ───────────────────────────────────────────────────────

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
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
          color: onTap == null
              ? AppColors.textTertiary.withOpacity(0.4)
              : AppColors.textSecondary,
        ),
      ),
    );
  }
}
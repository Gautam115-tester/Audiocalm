// lib/features/player/presentation/mini_player.dart
// VYNCE MINI PLAYER — gradient progress bar, purple/cyan identity

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
    final hasMedia = ref.watch(audioPlayerProvider.select((s) => s.hasMedia));
    if (!hasMedia) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => AppRouter.navigateToPlayer(context),
      child: Container(
        height: 66,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF7C3AED).withOpacity(0.2)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF7C3AED).withOpacity(0.15),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            children: const [
              RepaintBoundary(child: _VynceProgressBar()),
              Expanded(child: _ContentRow()),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Gradient Progress Bar ────────────────────────────────────────────────────

class _VynceProgressBar extends ConsumerWidget {
  const _VynceProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(audioPlayerProvider.select((s) => s.position));
    final duration = ref.watch(audioPlayerProvider.select((s) => s.duration));

    final progress = (duration != null && duration.inMilliseconds > 0)
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return LayoutBuilder(builder: (_, constraints) {
      return Stack(children: [
        Container(height: 2, color: const Color(0xFF1A1A2E)),
        Container(
          height: 2,
          width: constraints.maxWidth * progress,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
            ),
          ),
        ),
      ]);
    });
  }
}

// ─── Content Row ──────────────────────────────────────────────────────────────

class _ContentRow extends ConsumerWidget {
  const _ContentRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item      = ref.watch(audioPlayerProvider.select((s) => s.currentItem));
    final isPlaying = ref.watch(audioPlayerProvider.select((s) => s.isPlaying));
    final isLoading = ref.watch(audioPlayerProvider.select((s) => s.isLoading));

    if (item == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          CoverImage(url: item.artworkUrl, size: 40, borderRadius: 9),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFFF0F0FF)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (item.subtitle != null)
                  Text(item.subtitle!,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          // Controls
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniBtn(
                icon: Icons.skip_previous_rounded,
                onTap: isLoading ? null : () => ref.read(audioPlayerProvider.notifier).skipToPrevious(),
              ),
              const SizedBox(width: 2),
              _PlayPauseBtn(isPlaying: isPlaying, isLoading: isLoading,
                  onTap: isLoading ? null : () => ref.read(audioPlayerProvider.notifier).togglePlayPause()),
              const SizedBox(width: 2),
              _MiniBtn(
                icon: Icons.skip_next_rounded,
                onTap: isLoading ? null : () => ref.read(audioPlayerProvider.notifier).skipToNext(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayPauseBtn extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback? onTap;
  const _PlayPauseBtn({required this.isPlaying, required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
          ),
        ),
        child: isLoading
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              )
            : Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 18,
              ),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _MiniBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Icon(
          icon,
          size: 18,
          color: onTap == null
              ? const Color(0xFF4B5563)
              : const Color(0xFF9CA3AF),
        ),
      ),
    );
  }
}
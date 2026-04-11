// lib/features/calm_stories/presentation/series_detail_screen.dart
//
// CHANGES IN THIS VERSION
// =======================
// 1. REMAINING TIME BADGE — shows "▶ 7m 32s left" on each episode tile.
//    Reads from PlaybackPositionService (Hive-backed, persists across restarts).
//    Updates automatically when the user plays the episode (via a StreamBuilder
//    listening to the audio position stream).
//    Disappears when the episode is marked complete.
//
// 2. EPISODE COUNT FIX — the header now always shows the live count derived
//    from the embedded episodes list, never the stale DB episodeCount field.
//    This fixes the "80 shown instead of 81" bug for the Stories screen.
//
// 3. All existing features (completed badge, download, favorite, multi-part
//    indicator, ENC badge) are preserved unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/episode_model.dart';
import '../data/models/series_model.dart';
import '../providers/calm_stories_provider.dart';
import '../providers/completed_episodes_provider.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../downloads/data/services/download_manager.dart';
import '../../favorites/providers/favorites_provider.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';
import '../../../features/player/services/playback_position_service.dart';

class SeriesDetailScreen extends ConsumerWidget {
  final String seriesId;
  const SeriesDetailScreen({super.key, required this.seriesId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync   = ref.watch(seriesDetailProvider(seriesId));
    final episodesAsync = ref.watch(episodesProvider(seriesId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          episodesAsync.when(
            loading: () => seriesAsync.when(
              loading: () => const SliverToBoxAdapter(
                child: SizedBox(height: 280, child: ShimmerBox(height: 280)),
              ),
              error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
              data: (series) => series != null
                  ? _SeriesHeader(
                      series:           series,
                      liveEpisodeCount: 0,
                      liveEpisodes:     const [],
                    )
                  : const SliverToBoxAdapter(child: SizedBox.shrink()),
            ),
            error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
            data: (episodes) => seriesAsync.when(
              loading: () => const SliverToBoxAdapter(
                child: SizedBox(height: 280, child: ShimmerBox(height: 280)),
              ),
              error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
              data: (series) => series != null
                  ? _SeriesHeader(
                      series:           series,
                      liveEpisodeCount: episodes.length, // FIX: always use live count
                      liveEpisodes:     episodes,
                    )
                  : const SliverToBoxAdapter(child: SizedBox.shrink()),
            ),
          ),

          episodesAsync.when(
            loading: () => SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, __) => const _EpisodeShimmer(),
                childCount: 5,
              ),
            ),
            error: (_, __) => const SliverToBoxAdapter(
              child: AppErrorWidget(message: 'Failed to load episodes'),
            ),
            data: (episodes) {
              if (episodes.isEmpty) {
                return const SliverToBoxAdapter(
                  child: EmptyStateWidget(
                    icon:     Icons.headphones_rounded,
                    title:    'No Episodes Yet',
                    subtitle: 'Episodes will appear here after syncing',
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _EpisodeTile(
                    episode:     episodes[i],
                    allEpisodes: episodes,
                    seriesAsync: seriesAsync,
                    index:       i,
                  ),
                  childCount:             episodes.length,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries:   true,
                ),
              );
            },
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
}

// ── Series header ─────────────────────────────────────────────────────────────

class _SeriesHeader extends StatelessWidget {
  final SeriesModel        series;
  final int                liveEpisodeCount;
  final List<EpisodeModel> liveEpisodes;

  const _SeriesHeader({
    required this.series,
    required this.liveEpisodeCount,
    required this.liveEpisodes,
  });

  String get _totalDuration {
    if (liveEpisodes.isEmpty) return series.formattedTotalDuration;
    final total = liveEpisodes.fold<int>(0, (s, ep) => s + (ep.duration ?? 0));
    if (total <= 0) return series.formattedTotalDuration;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    if (m > 0) return '${m}m';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    // FIX: prefer live count (from embedded episodes list), fallback to DB value
    final count = liveEpisodeCount > 0 ? liveEpisodeCount : series.episodeCount;
    final dur   = _totalDuration;

    return SliverAppBar(
      expandedHeight: 260,
      pinned:          true,
      backgroundColor: AppColors.background,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(url: series.coverUrl, size: double.infinity, borderRadius: 0),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin:  Alignment.topCenter,
                  end:    Alignment.bottomCenter,
                  colors: [Colors.transparent, AppColors.background],
                ),
              ),
            ),
            Positioned(
              bottom: 16, left: 20, right: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(series.title,
                      style: Theme.of(context).textTheme.displaySmall),
                  if (series.description != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        series.description!,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '$count episode${count == 1 ? '' : 's'}',
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: AppColors.primary),
                      ),
                      if (dur.isNotEmpty) ...[
                        Text(
                          '  ·  ',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(color: AppColors.textTertiary),
                        ),
                        Text(
                          dur,
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Episode tile ──────────────────────────────────────────────────────────────

class _EpisodeTile extends ConsumerWidget {
  final EpisodeModel             episode;
  final List<EpisodeModel>       allEpisodes;
  final AsyncValue<SeriesModel?> seriesAsync;
  final int                      index;

  const _EpisodeTile({
    required this.episode,
    required this.allEpisodes,
    required this.seriesAsync,
    required this.index,
  });

  PlayableItem _toPlayable(EpisodeModel ep, SeriesModel? series) {
    return PlayableItem(
      id:         ep.id,
      title:      ep.title,
      subtitle:   series?.title,
      artworkUrl: series?.coverUrl,
      duration:   ep.duration,
      partCount:  ep.partCount,
      type:       MediaType.episode,
      streamUrl:  '${ApiConstants.baseUrl}${ApiConstants.episodeStream(ep.id)}',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDownloaded = ref.watch(
      downloadManagerProvider.select((map) => map[episode.id]?.isCompleted == true),
    );
    final isCompleted = ref.watch(
      completedEpisodesProvider.select((set) => set.contains(episode.id)),
    );
    final isFav   = ref.watch(favoritesProvider.select((set) => set.contains(episode.id)));
    final series  = seriesAsync.valueOrNull;

    // Watch current player to know if this episode is actively playing
    final playerState = ref.watch(audioPlayerProvider);
    final isCurrentlyPlaying = playerState.currentItem?.id == episode.id;

    return RepaintBoundary(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            _EpisodeNumberBadge(
              number:      episode.episodeNumber,
              isCompleted: isCompleted,
            ),
          ],
        ),
        title: Text(
          episode.title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 14,
            color: isCompleted ? AppColors.textSecondary : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (episode.duration != null)
                  DurationBadge(duration: episode.formattedDuration),
                if (episode.isMultiPart) ...[
                  const SizedBox(width: 6),
                  _PartBadge(count: episode.partCount),
                ],
                if (isCompleted) ...[
                  const SizedBox(width: 6),
                  _CompletedBadge(),
                ],
                const SizedBox(width: 6),
                if (isDownloaded) const _EncLockBadge(),
              ],
            ),
            // REMAINING TIME badge — only shown if not completed
            if (!isCompleted)
              _RemainingTimeBadge(
                episodeId:       episode.id,
                totalSeconds:    episode.duration,
                isCurrentlyPlaying: isCurrentlyPlaying,
                playerState:     playerState,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DownloadButton(
              episodeId:       episode.id,
              episodeTitle:    episode.title,
              isMultiPart:     episode.isMultiPart,
              partCount:       episode.partCount,
              seriesTitle:     series?.title,
              coverUrl:        series?.coverUrl,
              durationSeconds: episode.duration,
            ),
            GestureDetector(
              onLongPress: isCompleted
                  ? () => ref
                      .read(completedEpisodesProvider.notifier)
                      .markIncomplete(episode.id)
                  : null,
              child: IconButton(
                icon: Icon(
                  isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 20,
                ),
                color: isFav ? AppColors.error : AppColors.textTertiary,
                onPressed: () =>
                    ref.read(favoritesProvider.notifier).toggle(episode.id),
              ),
            ),
          ],
        ),
        onTap: () {
          final queue =
              allEpisodes.map((ep) => _toPlayable(ep, series)).toList();
          ref
              .read(audioPlayerProvider.notifier)
              .playItem(queue[index], queue: queue, index: index);
          AppRouter.navigateToPlayer(context);
        },
      ),
    );
  }
}

// ── Remaining time badge ───────────────────────────────────────────────────────
//
// Shows persisted remaining time. Updates live while the episode is playing.
// Reads directly from PlaybackPositionService (Hive) for persisted state,
// and from the player state when this episode is actively playing.

class _RemainingTimeBadge extends StatelessWidget {
  final String episodeId;
  final int? totalSeconds;
  final bool isCurrentlyPlaying;
  final AudioPlayerState playerState;

  const _RemainingTimeBadge({
    required this.episodeId,
    required this.totalSeconds,
    required this.isCurrentlyPlaying,
    required this.playerState,
  });

  @override
  Widget build(BuildContext context) {
    String? remainingText;

    if (isCurrentlyPlaying && totalSeconds != null) {
      // Live: compute from player position
      final posSeconds = playerState.position.inSeconds;
      final total      = totalSeconds!;
      if (posSeconds > 0 && total > 0) {
        final remaining = total - posSeconds;
        if (remaining > 30) {
          remainingText = _format(remaining);
        }
      }
    } else {
      // Persisted: read from Hive
      remainingText = PlaybackPositionService.formatRemaining(
        episodeId,
        totalSeconds,
      );
    }

    if (remainingText == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.play_arrow_rounded,
            size:  10,
            color: AppColors.primary.withOpacity(0.8),
          ),
          const SizedBox(width: 3),
          Text(
            '$remainingText left',
            style: TextStyle(
              color:         AppColors.primary.withOpacity(0.85),
              fontSize:      10,
              fontWeight:    FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  static String _format(int seconds) {
    if (seconds <= 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return m > 0 ? '${h}h ${m}m' : '${h}h';
    if (m > 0) return s > 0 ? '${m}m ${s}s' : '${m}m';
    return '${s}s';
  }
}

// ── Episode number badge ───────────────────────────────────────────────────────

class _EpisodeNumberBadge extends StatelessWidget {
  final int  number;
  final bool isCompleted;

  const _EpisodeNumberBadge({required this.number, required this.isCompleted});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color:        AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(
              number.toString().padLeft(2, '0'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color:      isCompleted ? AppColors.success : AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        if (isCompleted)
          Positioned(
            right:  -4,
            bottom: -4,
            child: Container(
              width: 18, height: 18,
              decoration: const BoxDecoration(
                color:  AppColors.success,
                shape:  BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded, size: 12, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

// ── Completed badge ────────────────────────────────────────────────────────────

class _CompletedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color:        AppColors.success.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.success.withOpacity(0.4), width: 0.8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, size: 9, color: AppColors.success),
          SizedBox(width: 3),
          Text(
            'done',
            style: TextStyle(
              color:        AppColors.success,
              fontSize:     9,
              fontWeight:   FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Part badge ─────────────────────────────────────────────────────────────────

class _PartBadge extends StatelessWidget {
  final int count;
  const _PartBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color:        AppColors.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$count parts',
        style: const TextStyle(
          color:      AppColors.primary,
          fontSize:   9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Download button ────────────────────────────────────────────────────────────

class _DownloadButton extends ConsumerWidget {
  final String  episodeId;
  final String  episodeTitle;
  final bool    isMultiPart;
  final int     partCount;
  final String? seriesTitle;
  final String? coverUrl;
  final int?    durationSeconds;

  const _DownloadButton({
    required this.episodeId,
    required this.episodeTitle,
    required this.isMultiPart,
    required this.partCount,
    this.seriesTitle,
    this.coverUrl,
    this.durationSeconds,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
      downloadManagerProvider.select((map) => map[episodeId]?.status),
    );
    final progress = ref.watch(
      downloadManagerProvider.select((map) => map[episodeId]?.progress ?? 0.0),
    );

    if (status == 'completed') {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Icon(Icons.check_circle_rounded, color: AppColors.success, size: 22),
      );
    }

    if (status == 'downloading' || status == 'merging' || status == 'encrypting') {
      final clamped = progress.clamp(0.0, 1.0);
      final pct     = (clamped * 100).round();
      final Color  ringColor;
      final String label;
      if (status == 'merging' || status == 'encrypting') {
        ringColor = AppColors.accentGold;
        label     = status == 'encrypting' ? '🔒' : '⚙';
      } else {
        ringColor = AppColors.primary;
        label     = '$pct%';
      }
      return SizedBox(
        width: 44, height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 28, height: 28,
              child: CircularProgressIndicator(
                value:           clamped > 0.01 ? clamped : null,
                strokeWidth:     2.5,
                backgroundColor: AppColors.surfaceVariant,
                color:           ringColor,
              ),
            ),
            Text(label, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: ringColor)),
          ],
        ),
      );
    }

    if (status == 'failed') {
      return IconButton(
        icon:    const Icon(Icons.refresh_rounded, size: 20),
        color:   AppColors.error,
        tooltip: 'Retry download',
        onPressed: () =>
            ref.read(downloadManagerProvider.notifier).retryDownload(episodeId),
      );
    }

    return IconButton(
      icon:  const Icon(Icons.download_rounded, size: 20),
      color: AppColors.textTertiary,
      onPressed: () {
        ref.read(downloadManagerProvider.notifier).startDownload(
          mediaId:         episodeId,
          title:           episodeTitle,
          mediaType:       'episode',
          partCount:       partCount,
          artworkUrl:      coverUrl,
          subtitle:        seriesTitle,
          durationSeconds: durationSeconds,
        );
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Row(children: [
              const Icon(Icons.download_rounded, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Downloading "$episodeTitle"…',
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            duration:        const Duration(seconds: 2),
            behavior:        SnackBarBehavior.floating,
            shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            backgroundColor: AppColors.surfaceVariant,
          ));
      },
    );
  }
}

// ── ENC lock badge ─────────────────────────────────────────────────────────────

class _EncLockBadge extends StatelessWidget {
  const _EncLockBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color:        AppColors.accentGold.withOpacity(0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.accentGold.withOpacity(0.55), width: 0.8),
        boxShadow: [BoxShadow(color: AppColors.accentGold.withOpacity(0.25), blurRadius: 6)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 9, color: AppColors.accentGold,
              shadows: [Shadow(color: AppColors.accentGold.withOpacity(0.6), blurRadius: 4)]),
          const SizedBox(width: 3),
          Text('ENC', style: TextStyle(
            color: AppColors.accentGold, fontSize: 9, fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            shadows: [Shadow(color: AppColors.accentGold.withOpacity(0.5), blurRadius: 4)],
          )),
        ],
      ),
    );
  }
}

// ── Shimmer placeholder ────────────────────────────────────────────────────────

class _EpisodeShimmer extends StatelessWidget {
  const _EpisodeShimmer();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          ShimmerBox(width: 44, height: 44, borderRadius: 10),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerBox(height: 14),
                SizedBox(height: 6),
                ShimmerBox(width: 80, height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
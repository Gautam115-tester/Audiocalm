// lib/features/calm_stories/presentation/series_detail_screen.dart
//
// MULTI-PART DISPLAY FIX:
// Episodes can be single-file or multi-part (partCount > 1).
// The DB stores:
//   duration  = TOTAL seconds across all parts (e.g. 446+347 = 793)
//   partCount = number of parts
//   title     = "Episode 1"  (NOT "Episode 1 Part 1/2")
//
// This screen shows:
//   • "Episode 1"  as the title (clean, no part suffix)
//   • "13:13"      as the duration (combined)
//   • No visual indication of parts — the player handles seamless playback
//
// Download / favorites / progress ring fixes are unchanged from previous version.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/episode_model.dart';
import '../data/models/series_model.dart';
import '../providers/calm_stories_provider.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../downloads/data/services/download_manager.dart';
import '../../favorites/providers/favorites_provider.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

class SeriesDetailScreen extends ConsumerWidget {
  final String seriesId;
  const SeriesDetailScreen({super.key, required this.seriesId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync  = ref.watch(seriesDetailProvider(seriesId));
    final episodesAsync = ref.watch(episodesProvider(seriesId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          seriesAsync.when(
            loading: () => const SliverToBoxAdapter(
              child: SizedBox(height: 280, child: ShimmerBox(height: 280)),
            ),
            error: (_, __) =>
                const SliverToBoxAdapter(child: SizedBox.shrink()),
            data: (series) => series != null
                ? _SeriesHeader(series: series)
                : const SliverToBoxAdapter(child: SizedBox.shrink()),
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
                    icon: Icons.headphones_rounded,
                    title: 'No Episodes Yet',
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
                  childCount:            episodes.length,
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
  final SeriesModel series;
  const _SeriesHeader({required this.series});

  @override
  Widget build(BuildContext context) {
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
                  begin: Alignment.topCenter,
                  end:   Alignment.bottomCenter,
                  colors: [Colors.transparent, AppColors.background],
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              left:   20,
              right:  20,
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
                  Text(
                    '${series.episodeCount} episode${series.episodeCount == 1 ? '' : 's'}',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: AppColors.primary),
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
  final EpisodeModel         episode;
  final List<EpisodeModel>   allEpisodes;
  final AsyncValue<SeriesModel?> seriesAsync;
  final int                  index;

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
      duration:   ep.duration,      // COMBINED duration already in DB
      partCount:  ep.partCount,     // tells audio_handler how many ?part=N URLs
      type:       MediaType.episode,
      streamUrl:  '${ApiConstants.baseUrl}${ApiConstants.episodeStream(ep.id)}',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCompleted = ref.watch(
      downloadManagerProvider.select((map) => map[episode.id]?.isCompleted == true),
    );
    final isFav = ref.watch(
      favoritesProvider.select((set) => set.contains(episode.id)),
    );
    final series = seriesAsync.valueOrNull;

    return RepaintBoundary(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: _EpisodeNumberBadge(number: episode.episodeNumber),
        title: Text(
          episode.title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14),
        ),
        subtitle: Row(
          children: [
            // Show combined duration (already summed in DB)
            if (episode.duration != null)
              DurationBadge(duration: episode.formattedDuration),

            // Multi-part indicator — subtle, just shows part count
            if (episode.isMultiPart) ...[
              const SizedBox(width: 6),
              _PartBadge(count: episode.partCount),
            ],

            const SizedBox(width: 6),
            if (isCompleted) const _EncLockBadge(),
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
              durationSeconds: episode.duration, // FIX: needed for offline seekbar
            ),
            IconButton(
              icon: Icon(
                isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: 20,
              ),
              color: isFav ? AppColors.error : AppColors.textTertiary,
              onPressed: () =>
                  ref.read(favoritesProvider.notifier).toggle(episode.id),
            ),
          ],
        ),
        onTap: () {
          final queue = allEpisodes.map((ep) => _toPlayable(ep, series)).toList();
          ref
              .read(audioPlayerProvider.notifier)
              .playItem(queue[index], queue: queue, index: index);
          AppRouter.navigateToPlayer(context);
        },
      ),
    );
  }
}

// ── Episode number badge ──────────────────────────────────────────────────────

class _EpisodeNumberBadge extends StatelessWidget {
  final int number;
  const _EpisodeNumberBadge({required this.number});

  @override
  Widget build(BuildContext context) {
    return Container(
      width:  44,
      height: 44,
      decoration: BoxDecoration(
        color:        AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          number.toString().padLeft(2, '0'),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color:      AppColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ── Part count badge (subtle) ─────────────────────────────────────────────────

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
        style: TextStyle(
          color:      AppColors.primary,
          fontSize:   9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Download button ───────────────────────────────────────────────────────────

class _DownloadButton extends ConsumerWidget {
  final String  episodeId;
  final String  episodeTitle;
  final bool    isMultiPart;
  final int     partCount;
  final String? seriesTitle;
  final String? coverUrl;
  // FIX: pass combined duration so it's stored in DownloadModel and available
  // for offline playback — prevents position > duration on the seekbar.
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
      final pct = (clamped * 100).round();

      final Color  ringColor;
      final String label;
      if (status == 'merging' || status == 'encrypting') {
        ringColor = AppColors.accentGold;
        label = status == 'encrypting' ? '🔒' : '⚙';
      } else {
        ringColor = AppColors.primary;
        label = '$pct%';
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
            Text(label, style: TextStyle(
              fontSize:   8,
              fontWeight: FontWeight.w700,
              color:      ringColor,
              letterSpacing: -0.3,
            )),
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
          mediaId:    episodeId,
          title:      episodeTitle,
          mediaType:  'episode',
          partCount:        partCount,   // pass actual part count for correct download
          artworkUrl:       coverUrl,
          subtitle:         seriesTitle,
          durationSeconds:  durationSeconds, // FIX: store for offline seekbar
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
            duration:  const Duration(seconds: 2),
            behavior:  SnackBarBehavior.floating,
            shape:     RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            backgroundColor: AppColors.surfaceVariant,
          ));
      },
    );
  }
}

// ── ENC lock badge ────────────────────────────────────────────────────────────

class _EncLockBadge extends StatelessWidget {
  const _EncLockBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color:        AppColors.accentGold.withOpacity(0.18),
        borderRadius: BorderRadius.circular(4),
        border:       Border.all(color: AppColors.accentGold.withOpacity(0.55), width: 0.8),
        boxShadow: [BoxShadow(color: AppColors.accentGold.withOpacity(0.25), blurRadius: 6)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 9, color: AppColors.accentGold,
              shadows: [Shadow(color: AppColors.accentGold.withOpacity(0.6), blurRadius: 4)]),
          const SizedBox(width: 3),
          Text('ENC', style: TextStyle(
            color:       AppColors.accentGold,
            fontSize:    9,
            fontWeight:  FontWeight.w800,
            letterSpacing: 0.6,
            shadows: [Shadow(color: AppColors.accentGold.withOpacity(0.5), blurRadius: 4)],
          )),
        ],
      ),
    );
  }
}

// ── Shimmer placeholder ───────────────────────────────────────────────────────

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
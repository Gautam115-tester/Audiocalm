// lib/features/calm_stories/presentation/series_detail_screen.dart
//
// FIX: Download progress ring was frozen / not updating.
//
// ROOT CAUSE: DownloadModel is mutable — its fields (status, progress) are
// mutated in-place inside DownloadManager. Riverpod's `.select((map) => map[id])`
// returns the SAME object reference before and after the mutation, so
// `identical(prev, next)` is true → Riverpod skips the rebuild → the ring
// never moved.
//
// FIX: _DownloadButton is now a ConsumerWidget that watches the provider
// directly and selects the specific scalar fields it needs (status + progress).
// Because scalars are compared by value, any change triggers a rebuild.

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
    final seriesAsync = ref.watch(seriesDetailProvider(seriesId));
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
                    title: 'No Episodes',
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _EpisodeTile(
                    episode: episodes[i],
                    allEpisodes: episodes,
                    seriesAsync: seriesAsync,
                    index: i,
                  ),
                  childCount: episodes.length,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: true,
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

class _SeriesHeader extends StatelessWidget {
  final SeriesModel series;
  const _SeriesHeader({required this.series});

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 260,
      pinned: true,
      backgroundColor: AppColors.background,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(
                url: series.coverUrl, size: double.infinity, borderRadius: 0),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, AppColors.background],
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              left: 20,
              right: 20,
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
                    '${series.episodeCount} episodes',
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

class _EpisodeTile extends ConsumerWidget {
  final EpisodeModel episode;
  final List<EpisodeModel> allEpisodes;
  final AsyncValue<SeriesModel?> seriesAsync;
  final int index;

  const _EpisodeTile({
    required this.episode,
    required this.allEpisodes,
    required this.seriesAsync,
    required this.index,
  });

  PlayableItem _toPlayable(EpisodeModel ep, SeriesModel? series) {
    return PlayableItem(
      id: ep.id,
      title: ep.title,
      subtitle: series?.title,
      artworkUrl: series?.coverUrl,
      duration: ep.duration,
      partCount: ep.partCount,
      type: MediaType.episode,
      streamUrl: '${ApiConstants.baseUrl}${ApiConstants.episodeStream(ep.id)}',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // FIX: only watch the scalar `isCompleted` bool — value comparison works.
    final isCompleted = ref.watch(
      downloadManagerProvider
          .select((map) => map[episode.id]?.isCompleted == true),
    );
    final isFav = ref.watch(
      favoritesProvider.select((set) => set.contains(episode.id)),
    );
    final series = seriesAsync.valueOrNull;

    return RepaintBoundary(
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(
              episode.episodeNumber.toString().padLeft(2, '0'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ),
        title: Text(
          episode.title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontSize: 14),
        ),
        subtitle: Row(
          children: [
            if (episode.duration != null)
              DurationBadge(duration: episode.formattedDuration),
            const SizedBox(width: 6),
            if (isCompleted) const _EncLockBadge(),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // FIX: pass IDs not the model — _DownloadButton watches internally
            _DownloadButton(
              episodeId: episode.id,
              episodeTitle: episode.title,
              isMultiPart: episode.isMultiPart,
              seriesTitle: series?.title,
              coverUrl: series?.coverUrl,
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

// ── Download button — watches provider directly by episodeId ──────────────────
//
// KEY FIX: We select individual scalar fields (status string + progress double)
// rather than the whole DownloadModel object. Because DownloadModel is mutable,
// selecting the object itself returns the same reference every time (no rebuild).
// Selecting scalars lets Riverpod compare by value → rebuilds on every tick.

class _DownloadButton extends ConsumerWidget {
  final String episodeId;
  final String episodeTitle;
  final bool isMultiPart;
  final String? seriesTitle;
  final String? coverUrl;

  const _DownloadButton({
    required this.episodeId,
    required this.episodeTitle,
    required this.isMultiPart,
    this.seriesTitle,
    this.coverUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch scalar fields so Riverpod can detect value-level changes.
    final status = ref.watch(
      downloadManagerProvider.select((map) => map[episodeId]?.status),
    );
    final progress = ref.watch(
      downloadManagerProvider.select((map) => map[episodeId]?.progress ?? 0.0),
    );

    // ── Completed ──────────────────────────────────────────────────────────
    if (status == 'completed') {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Icon(Icons.check_circle_rounded,
            color: AppColors.success, size: 22),
      );
    }

    // ── Downloading / merging / encrypting ──────────────────────────────────
    if (status == 'downloading' || status == 'merging' || status == 'encrypting') {
      final clampedProgress = progress.clamp(0.0, 1.0);
      final pct = (clampedProgress * 100).round();

      final Color ringColor;
      final String label;
      if (status == 'merging' || status == 'encrypting') {
        ringColor = AppColors.accentGold;
        label = status == 'encrypting' ? '🔒' : '⚙';
      } else {
        ringColor = AppColors.primary;
        label = '$pct%';
      }

      return SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                value: clampedProgress > 0.01 ? clampedProgress : null,
                strokeWidth: 2.5,
                backgroundColor: AppColors.surfaceVariant,
                color: ringColor,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: ringColor,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      );
    }

    // ── Failed — retry button ──────────────────────────────────────────────
    if (status == 'failed') {
      return IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 20),
        color: AppColors.error,
        tooltip: 'Retry download',
        onPressed: () {
          ref.read(downloadManagerProvider.notifier).retryDownload(episodeId);
        },
      );
    }

    // ── Not downloaded — show download arrow ───────────────────────────────
    return IconButton(
      icon: const Icon(Icons.download_rounded, size: 20),
      color: AppColors.textTertiary,
      onPressed: () {
        ref.read(downloadManagerProvider.notifier).startDownload(
              mediaId: episodeId,
              title: episodeTitle,
              mediaType: 'episode',
              partCount: isMultiPart ? 2 : 1,
              artworkUrl: coverUrl,
              subtitle: seriesTitle,
            );

        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.download_rounded,
                    color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Downloading "$episodeTitle"…',
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            backgroundColor: AppColors.surfaceVariant,
          ),
        );
      },
    );
  }
}

// ── Polished ENC lock badge ────────────────────────────────────────────────────

class _EncLockBadge extends StatelessWidget {
  const _EncLockBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accentGold.withOpacity(0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: AppColors.accentGold.withOpacity(0.55),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.accentGold.withOpacity(0.25),
            blurRadius: 6,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_rounded,
            size: 9,
            color: AppColors.accentGold,
            shadows: [
              Shadow(
                  color: AppColors.accentGold.withOpacity(0.6), blurRadius: 4),
            ],
          ),
          const SizedBox(width: 3),
          Text(
            'ENC',
            style: TextStyle(
              color: AppColors.accentGold,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              shadows: [
                Shadow(
                    color: AppColors.accentGold.withOpacity(0.5),
                    blurRadius: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
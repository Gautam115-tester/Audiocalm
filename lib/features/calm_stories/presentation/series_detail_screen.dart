// lib/features/calm_stories/presentation/series_detail_screen.dart

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
            error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
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
                  (context, i) {
                    final ep = episodes[i];
                    return _EpisodeTile(
                      episode: ep,
                      allEpisodes: episodes,
                      seriesAsync: seriesAsync,
                      index: i,
                    );
                  },
                  childCount: episodes.length,
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
              url: series.coverUrl,
              size: double.infinity,
              borderRadius: 0,
            ),
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
    final downloads = ref.watch(downloadManagerProvider);
    final isFav = ref.watch(favoritesProvider).contains(episode.id);
    final dl = downloads[episode.id];
    final isDownloaded = dl?.isCompleted ?? false;
    final isDownloading = dl?.isInProgress ?? false;
    final series = seriesAsync.valueOrNull;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
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
      title: Text(episode.title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontSize: 14)),
      subtitle: Row(
        children: [
          if (episode.duration != null)
            DurationBadge(duration: episode.formattedDuration),
          const SizedBox(width: 6),
          if (isDownloaded) const EncryptedBadge(),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDownloading)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                value: dl?.progress,
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            )
          else if (!isDownloaded)
            IconButton(
              icon: const Icon(Icons.download_rounded, size: 20),
              color: AppColors.textTertiary,
              onPressed: () {
                ref.read(downloadManagerProvider.notifier).startDownload(
                      mediaId: episode.id,
                      title: episode.title,
                      mediaType: 'episode',
                      partCount: episode.partCount,
                      artworkUrl: series?.coverUrl,
                      subtitle: series?.title,
                    );
              },
            )
          else
            const Icon(Icons.check_circle_rounded,
                color: AppColors.success, size: 20),
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
        final queue = allEpisodes
            .map((ep) => _toPlayable(ep, series))
            .toList();
        ref
            .read(audioPlayerProvider.notifier)
            .playItem(queue[index], queue: queue, index: index);
        AppRouter.navigateToPlayer(context);
      },
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

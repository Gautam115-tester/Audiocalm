// lib/features/calm_music/presentation/album_detail_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/song_model.dart';
import '../data/models/album_model.dart';
import '../providers/calm_music_provider.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../downloads/data/services/download_manager.dart';
import '../../favorites/providers/favorites_provider.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

class AlbumDetailScreen extends ConsumerWidget {
  final String albumId;
  const AlbumDetailScreen({super.key, required this.albumId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumAsync = ref.watch(albumDetailProvider(albumId));
    final songsAsync = ref.watch(songsProvider(albumId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          albumAsync.when(
            loading: () => const SliverAppBar(
              expandedHeight: 240,
              pinned: true,
              backgroundColor: AppColors.background,
            ),
            error: (_, __) => const SliverAppBar(pinned: true),
            data: (album) => album != null
                ? _AlbumHeader(album: album, songsAsync: songsAsync)
                : const SliverAppBar(pinned: true),
          ),
          songsAsync.when(
            loading: () => SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, __) => const _SongShimmer(),
                childCount: 6,
              ),
            ),
            error: (_, __) => const SliverToBoxAdapter(
              child: AppErrorWidget(message: 'Failed to load songs'),
            ),
            data: (songs) {
              if (songs.isEmpty) {
                return const SliverToBoxAdapter(
                  child: EmptyStateWidget(
                    icon: Icons.music_note_rounded,
                    title: 'No Songs',
                  ),
                );
              }
              final album = albumAsync.valueOrNull;
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _SongTile(
                    song: songs[i],
                    allSongs: songs,
                    album: album,
                    index: i,
                  ),
                  childCount: songs.length,
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

class _AlbumHeader extends StatelessWidget {
  final AlbumModel album;
  final AsyncValue<List<SongModel>> songsAsync;

  const _AlbumHeader({required this.album, required this.songsAsync});

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
              url: album.coverUrl,
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
                  Text(album.title,
                      style: Theme.of(context).textTheme.displaySmall),
                  if (album.artist != null)
                    Text(
                      album.artist!,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    '${album.trackCount} tracks',
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

class _SongTile extends ConsumerWidget {
  final SongModel song;
  final List<SongModel> allSongs;
  final AlbumModel? album;
  final int index;

  const _SongTile({
    required this.song,
    required this.allSongs,
    this.album,
    required this.index,
  });

  PlayableItem _toPlayable(SongModel s, AlbumModel? album) {
  return PlayableItem(
    id: s.id,
    title: s.title,
    subtitle: album?.title,
    artworkUrl: s.coverUrl ?? album?.coverUrl, // ← song has its own cover now
    duration: s.duration,
    partCount: s.isMultiPart ? 2 : 1,
    type: MediaType.song,
    streamUrl: '${ApiConstants.baseUrl}${ApiConstants.songStream(s.id)}',
  );
}

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadManagerProvider);
    final isFav = ref.watch(favoritesProvider).contains(song.id);
    final dl = downloads[song.id];
    final isDownloaded = dl?.isCompleted ?? false;
    final isDownloading = dl?.isInProgress ?? false;

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            song.trackNumber.toString().padLeft(2, '0'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
      ),
      title: Text(song.title,
          style:
              Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14)),
      subtitle: Row(
        children: [
          if (song.duration != null)
            DurationBadge(duration: song.formattedDuration),
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
    mediaId: song.id,
    title: song.title,
    mediaType: 'song',
    partCount: song.isMultiPart ? 2 : 1,
    artworkUrl: song.coverUrl ?? album?.coverUrl,
    subtitle: album?.title,
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
                ref.read(favoritesProvider.notifier).toggle(song.id),
          ),
        ],
      ),
      onTap: () {
        final queue = allSongs.map((s) => _toPlayable(s, album)).toList();
        ref
            .read(audioPlayerProvider.notifier)
            .playItem(queue[index], queue: queue, index: index);
        AppRouter.navigateToPlayer(context);
      },
    );
  }
}

class _SongShimmer extends StatelessWidget {
  const _SongShimmer();

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
                ShimmerBox(width: 60, height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

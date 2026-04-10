// lib/features/calm_music/presentation/album_detail_screen.dart
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
    final combinedAsync = ref.watch(albumWithSongsProvider(albumId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: combinedAsync.when(
        loading: () => _AlbumDetailSkeleton(),
        error: (_, __) => Scaffold(
          appBar: AppBar(backgroundColor: AppColors.background),
          body: const AppErrorWidget(message: 'Failed to load album'),
        ),
        data: (data) => CustomScrollView(
          cacheExtent: 500,
          slivers: [
            if (data.album != null)
              _AlbumHeader(album: data.album!, songCount: data.songs.length)
            else
              const SliverAppBar(pinned: true),
            if (data.songs.isEmpty)
              const SliverToBoxAdapter(
                child: EmptyStateWidget(
                  icon: Icons.music_note_rounded,
                  title: 'No Songs',
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _SongTile(
                    song: data.songs[i],
                    allSongs: data.songs,
                    album: data.album,
                    index: i,
                  ),
                  childCount: data.songs.length,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: true,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ),
    );
  }
}

class _AlbumDetailSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 260,
          pinned: true,
          backgroundColor: AppColors.background,
          flexibleSpace: FlexibleSpaceBar(
            background: Container(color: AppColors.surfaceVariant),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, __) => const Padding(
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
            ),
            childCount: 8,
          ),
        ),
      ],
    );
  }
}

class _AlbumHeader extends StatelessWidget {
  final AlbumModel album;
  final int songCount;

  const _AlbumHeader({required this.album, required this.songCount});

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
              memCacheWidth: 800,
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
                    '$songCount tracks',
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

// ── Song tile ──────────────────────────────────────────────────────────────────

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
      artworkUrl: s.coverUrl ?? album?.coverUrl,
      duration: s.duration,
      partCount: s.isMultiPart ? 2 : 1,
      type: MediaType.song,
      streamUrl: '${ApiConstants.baseUrl}${ApiConstants.songStream(s.id)}',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // FIX: only watch the scalar `isCompleted` bool — this selects by VALUE
    // so Riverpod correctly detects the change when the download finishes.
    final isCompleted = ref.watch(
      downloadManagerProvider.select((map) => map[song.id]?.isCompleted == true),
    );
    final isFav = ref.watch(
      favoritesProvider.select((set) => set.contains(song.id)),
    );

    return RepaintBoundary(
      child: ListTile(
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
        title: Text(
          song.title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontSize: 14),
        ),
        subtitle: Row(
          children: [
            if (song.duration != null)
              DurationBadge(duration: song.formattedDuration),
            const SizedBox(width: 6),
            if (isCompleted) const _EncLockBadge(),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // FIX: pass IDs not the model — _DownloadButton watches internally
            _DownloadButton(
              songId: song.id,
              songTitle: song.title,
              isMultiPart: song.isMultiPart,
              albumTitle: album?.title,
              coverUrl: song.coverUrl ?? album?.coverUrl,
            ),
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
          final queue =
              allSongs.map((s) => _toPlayable(s, album)).toList();
          ref
              .read(audioPlayerProvider.notifier)
              .playItem(queue[index], queue: queue, index: index);
          AppRouter.navigateToPlayer(context);
        },
      ),
    );
  }
}

// ── Download button — watches provider directly by songId ─────────────────────
//
// KEY FIX: We select individual scalar fields (status string + progress double)
// rather than the whole DownloadModel object. Because DownloadModel is mutable,
// selecting the object itself returns the same reference every time (no rebuild).
// Selecting scalars lets Riverpod compare by value → rebuilds on every tick.

class _DownloadButton extends ConsumerWidget {
  final String songId;
  final String songTitle;
  final bool isMultiPart;
  final String? albumTitle;
  final String? coverUrl;

  const _DownloadButton({
    required this.songId,
    required this.songTitle,
    required this.isMultiPart,
    this.albumTitle,
    this.coverUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch scalar fields so Riverpod can detect value-level changes.
    final status = ref.watch(
      downloadManagerProvider.select((map) => map[songId]?.status),
    );
    final progress = ref.watch(
      downloadManagerProvider.select((map) => map[songId]?.progress ?? 0.0),
    );

    // ── Completed ──────────────────────────────────────────────────────────
    if (status == 'completed') {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Icon(
          Icons.check_circle_rounded,
          color: AppColors.success,
          size: 22,
        ),
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

    // ── Failed — show retry ────────────────────────────────────────────────
    if (status == 'failed') {
      return IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 20),
        color: AppColors.error,
        tooltip: 'Retry download',
        onPressed: () {
          ref.read(downloadManagerProvider.notifier).retryDownload(songId);
        },
      );
    }

    // ── Not downloaded — show download arrow ───────────────────────────────
    return IconButton(
      icon: const Icon(Icons.download_rounded, size: 20),
      color: AppColors.textTertiary,
      onPressed: () {
        ref.read(downloadManagerProvider.notifier).startDownload(
              mediaId: songId,
              title: songTitle,
              mediaType: 'song',
              partCount: isMultiPart ? 2 : 1,
              artworkUrl: coverUrl,
              subtitle: albumTitle,
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
                    'Downloading "$songTitle"…',
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            backgroundColor: AppColors.surfaceVariant,
          ),
        );
      },
    );
  }
}

// ── Polished ENC lock badge ───────────────────────────────────────────────────

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
            spreadRadius: 0,
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
                color: AppColors.accentGold.withOpacity(0.6),
                blurRadius: 4,
              ),
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
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
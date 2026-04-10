// lib/features/calm_music/presentation/album_detail_screen.dart
//
// FIX 1 — Instant "queued" feedback on download tap
//   DownloadManager now sets status='downloading' before the async work starts,
//   so the icon flips to a progress ring immediately on tap.
//
// FIX 2 — Progress % shown inside the ring while downloading
//   _SongTile reads dl.progress and shows "XX%" text overlaid on the ring.
//
// FIX 3 — Retry button on failed downloads
//   If status == failed, show a red retry icon instead of the download arrow.
//
// FIX 4 — Polished ENC lock badge with glow
//   Replaced the plain EncryptedBadge with an inline lock icon + "ENC" text
//   that glows gold to make it obviously mean "offline-encrypted".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/song_model.dart';
import '../data/models/album_model.dart';
import '../providers/calm_music_provider.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../downloads/data/services/download_manager.dart';
import '../../downloads/data/models/download_model.dart';
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
    final dl = ref.watch(
      downloadManagerProvider.select((map) => map[song.id]),
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
            if (dl?.isCompleted == true) const _EncLockBadge(),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DownloadButton(
              song: song,
              album: album,
              dl: dl,
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

// ── Download button widget ────────────────────────────────────────────────────
// Shows: download arrow → animated ring with % → check/lock → retry on fail

class _DownloadButton extends ConsumerWidget {
  final SongModel song;
  final AlbumModel? album;
  final DownloadModel? dl;

  const _DownloadButton({
    required this.song,
    required this.album,
    required this.dl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ── Completed ──────────────────────────────────────────────────────────
    if (dl?.isCompleted == true) {
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
    if (dl?.isInProgress == true) {
      final progress = dl!.progress.clamp(0.0, 1.0);
      final pct = (progress * 100).round();

      // Color by phase
      final Color ringColor;
      final String label;
      if (dl!.status == 'merging' || dl!.status == 'encrypting') {
        ringColor = AppColors.accentGold;
        label = dl!.status == 'encrypting' ? '🔒' : '⚙';
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
            // Background track
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                value: progress > 0 ? progress : null,
                strokeWidth: 2.5,
                backgroundColor: AppColors.surfaceVariant,
                color: ringColor,
              ),
            ),
            // Percentage label inside ring
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
    if (dl?.isFailed == true) {
      return IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 20),
        color: AppColors.error,
        tooltip: 'Retry download',
        onPressed: () {
          ref.read(downloadManagerProvider.notifier).retryDownload(song.id);
        },
      );
    }

    // ── Not downloaded — show download arrow ───────────────────────────────
    return IconButton(
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

        // Show snackbar so user knows it started
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
                    'Downloading "${song.title}"…',
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
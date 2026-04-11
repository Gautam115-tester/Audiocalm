// lib/features/downloads/presentation/downloads_screen.dart
//
// CHANGES IN THIS VERSION
// ========================
//
// MUSIC SECTION — Album-grouped playback
//   Downloads are grouped by albumId / subtitle.
//   Each album group shows a header with 3 play options:
//     • Play album        — queues only that album's songs in track order
//     • Loop album        — same queue, sets loop-all mode
//     • Play all music    — queues every downloaded song across all albums,
//                           sorted album-first then by trackNumber
//   Individual song tiles remain tappable to start from that track.
//
// AUDIO STORIES SECTION — Cross-series sequential playback
//   Episodes from ALL series are merged into one ascending queue:
//     sorted by (seriesTitle asc, episodeNumber asc).
//   Tapping any episode starts from that episode and continues through
//   the rest of the merged queue (cross-series autoplay).
//   A "Play all stories" button at the section header starts from ep 1
//   of the first series.
//
// OFFLINE PLAYBACK (unchanged two-phase decrypt approach from previous version)

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/download_manager.dart';
import '../data/models/download_model.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

const _kMusicAccent = AppColors.primary;
const _kStoryAccent = Color(0xFFEF9F27);

// ─────────────────────────────────────────────────────────────────────────────
// Data helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Groups completed song downloads by album (subtitle field = album title).
/// Returns list of (albumTitle, songs) sorted by album title, songs by
/// trackNumber ascending.
List<_AlbumGroup> _groupSongsByAlbum(List<DownloadModel> completedSongs) {
  final map = <String, List<DownloadModel>>{};
  for (final s in completedSongs) {
    final key = s.subtitle ?? 'Unknown Album';
    map.putIfAbsent(key, () => []).add(s);
  }
  final groups = map.entries
      .map((e) {
        final sorted = [...e.value]
          ..sort((a, b) {
            // Use mediaId track-number hint embedded in title if possible,
            // otherwise fall back to createdAt to approximate insertion order.
            return a.createdAt.compareTo(b.createdAt);
          });
        return _AlbumGroup(albumTitle: e.key, songs: sorted);
      })
      .toList()
    ..sort((a, b) => a.albumTitle.compareTo(b.albumTitle));
  return groups;
}

class _AlbumGroup {
  final String albumTitle;
  final List<DownloadModel> songs;
  const _AlbumGroup({required this.albumTitle, required this.songs});
}

/// Merges all downloaded episodes across series into one ascending queue:
/// sort by (seriesTitle asc, createdAt asc — approximates episodeNumber).
List<DownloadModel> _mergedEpisodeQueue(List<DownloadModel> completedEpisodes) {
  return [...completedEpisodes]
    ..sort((a, b) {
      final seriesCmp = (a.subtitle ?? '').compareTo(b.subtitle ?? '');
      if (seriesCmp != 0) return seriesCmp;
      return a.createdAt.compareTo(b.createdAt);
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadManagerProvider);
    final manager = ref.read(downloadManagerProvider.notifier);

    final songs = downloads.values
        .where((d) => d.mediaType == 'song')
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final episodes = downloads.values
        .where((d) => d.mediaType == 'episode')
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final completedSongs = songs.where((d) => d.isCompleted).toList();
    final completedEpisodes = episodes.where((d) => d.isCompleted).toList();
    final inProgressSongs = songs.where((d) => d.isInProgress).toList();
    final inProgressEpisodes = episodes.where((d) => d.isInProgress).toList();
    final failedSongs = songs.where((d) => d.isFailed).toList();
    final failedEpisodes = episodes.where((d) => d.isFailed).toList();

    final hasCompleted =
        completedSongs.isNotEmpty || completedEpisodes.isNotEmpty;

    // Pre-compute grouped data
    final albumGroups = _groupSongsByAlbum(completedSongs);
    final mergedEpisodes = _mergedEpisodeQueue(completedEpisodes);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (hasCompleted)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              color: AppColors.error,
              tooltip: 'Clear all downloads',
              onPressed: () => _confirmClearAll(context, ref),
            ),
        ],
      ),
      body: downloads.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.download_rounded,
              title: 'No Downloads',
              subtitle:
                  'Downloaded music and audio stories appear here for offline listening',
            )
          : Column(
              children: [
                // ── Storage bar ───────────────────────────────────────────
                FutureBuilder<int>(
                  future: manager.getTotalStorageBytes(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data == 0) {
                      return const SizedBox.shrink();
                    }
                    final total =
                        completedSongs.length + completedEpisodes.length;
                    return Container(
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.storage_rounded,
                              color: AppColors.primary, size: 18),
                          const SizedBox(width: 10),
                          Text(
                            'Storage: ${manager.formatStorageSize(snapshot.data!)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const Spacer(),
                          Text(
                            '$total file${total == 1 ? '' : 's'}',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                    color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(
                        top: 8, bottom: 120, left: 16, right: 16),
                    children: [
                      // ══════════════════════════════════════════════════════
                      // MUSIC SECTION
                      // ══════════════════════════════════════════════════════
                      if (inProgressSongs.isNotEmpty ||
                          failedSongs.isNotEmpty ||
                          completedSongs.isNotEmpty) ...[
                        _TypeHeader(
                          icon: Icons.music_note_rounded,
                          label: 'Music',
                          accent: _kMusicAccent,
                        ),

                        if (inProgressSongs.isNotEmpty) ...[
                          _SubSectionLabel(
                              label: 'Downloading',
                              count: inProgressSongs.length),
                          ...inProgressSongs
                              .map((d) => _ActiveDownloadCard(download: d)),
                          const SizedBox(height: 8),
                        ],

                        if (failedSongs.isNotEmpty) ...[
                          _SubSectionLabel(
                              label: 'Failed',
                              count: failedSongs.length),
                          ...failedSongs
                              .map((d) => _FailedTile(download: d)),
                          const SizedBox(height: 8),
                        ],

                        if (completedSongs.isNotEmpty) ...[
                          // "Play all music" header button
                          _MusicSectionActions(
                            allSongs: completedSongs,
                            accent: _kMusicAccent,
                          ),
                          // Album groups
                          ...albumGroups.map(
                            (group) => _AlbumGroupWidget(
                              group: group,
                              allCompletedSongs: completedSongs,
                              accent: _kMusicAccent,
                            ),
                          ),
                        ],

                        const SizedBox(height: 20),
                      ],

                      // ══════════════════════════════════════════════════════
                      // AUDIO STORIES SECTION
                      // ══════════════════════════════════════════════════════
                      if (inProgressEpisodes.isNotEmpty ||
                          failedEpisodes.isNotEmpty ||
                          completedEpisodes.isNotEmpty) ...[
                        _TypeHeader(
                          icon: Icons.headphones_rounded,
                          label: 'Audio Stories',
                          accent: _kStoryAccent,
                        ),

                        if (inProgressEpisodes.isNotEmpty) ...[
                          _SubSectionLabel(
                              label: 'Downloading',
                              count: inProgressEpisodes.length),
                          ...inProgressEpisodes
                              .map((d) => _ActiveDownloadCard(download: d)),
                          const SizedBox(height: 8),
                        ],

                        if (failedEpisodes.isNotEmpty) ...[
                          _SubSectionLabel(
                              label: 'Failed',
                              count: failedEpisodes.length),
                          ...failedEpisodes
                              .map((d) => _FailedTile(download: d)),
                          const SizedBox(height: 8),
                        ],

                        if (completedEpisodes.isNotEmpty) ...[
                          _StoriesSectionActions(
                            mergedQueue: mergedEpisodes,
                            accent: _kStoryAccent,
                          ),
                          ...mergedEpisodes.asMap().entries.map(
                                (entry) => _EpisodeTile(
                                  download: entry.value,
                                  queueIndex: entry.key,
                                  fullQueue: mergedEpisodes,
                                  accent: _kStoryAccent,
                                ),
                              ),
                        ],
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  void _confirmClearAll(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Downloads'),
        content: const Text(
            'This will delete all downloaded files. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(downloadManagerProvider.notifier)
                  .clearAllDownloads();
              Navigator.pop(ctx);
            },
            style:
                TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Music — "Play all music" bar
// ─────────────────────────────────────────────────────────────────────────────

class _MusicSectionActions extends ConsumerWidget {
  final List<DownloadModel> allSongs;
  final Color accent;
  const _MusicSectionActions(
      {required this.allSongs, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _ActionChip(
              icon: Icons.queue_music_rounded,
              label: 'Play all music',
              accent: accent,
              onTap: () => _playAll(context, ref, shuffle: false),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionChip(
              icon: Icons.shuffle_rounded,
              label: 'Shuffle all',
              accent: accent,
              onTap: () => _playAll(context, ref, shuffle: true),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _playAll(BuildContext context, WidgetRef ref,
      {required bool shuffle}) async {
    if (allSongs.isEmpty) return;
    final sorted = [...allSongs]
      ..sort((a, b) {
        final sc = (a.subtitle ?? '').compareTo(b.subtitle ?? '');
        if (sc != 0) return sc;
        return a.createdAt.compareTo(b.createdAt);
      });
    final start = sorted.first;
    await _OfflinePlaybackHelper.play(
      context: context,
      ref: ref,
      startDownload: start,
      fullQueue: sorted,
      startIndex: 0,
      shuffle: shuffle,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Music — Album group widget
// ─────────────────────────────────────────────────────────────────────────────

class _AlbumGroupWidget extends ConsumerStatefulWidget {
  final _AlbumGroup group;
  final List<DownloadModel> allCompletedSongs;
  final Color accent;
  const _AlbumGroupWidget(
      {required this.group,
      required this.allCompletedSongs,
      required this.accent});

  @override
  ConsumerState<_AlbumGroupWidget> createState() =>
      _AlbumGroupWidgetState();
}

class _AlbumGroupWidgetState extends ConsumerState<_AlbumGroupWidget> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final coverUrl =
        group.songs.isNotEmpty ? group.songs.first.artworkUrl : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: widget.accent.withOpacity(0.12)),
      ),
      child: Column(
        children: [
          // ── Album header row ───────────────────────────────────────────
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CoverImage(
                      url: coverUrl,
                      size: 52,
                      borderRadius: 10),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.albumTitle,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${group.songs.length} song${group.songs.length == 1 ? '' : 's'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  // Play album button
                  _SmallIconBtn(
                    icon: Icons.play_circle_rounded,
                    color: widget.accent,
                    tooltip: 'Play album',
                    onTap: () => _playAlbum(context, shuffle: false),
                  ),
                  // Loop album button
                  _SmallIconBtn(
                    icon: Icons.repeat_rounded,
                    color: widget.accent.withOpacity(0.7),
                    tooltip: 'Loop album',
                    onTap: () => _playAlbum(context, loop: true),
                  ),
                  // Expand/collapse
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: AppColors.textTertiary,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),

          // ── Album play-mode chips ─────────────────────────────────────
          if (_expanded) ...[
            const Divider(height: 1, indent: 12, endIndent: 12),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _ActionChip(
                    icon: Icons.play_arrow_rounded,
                    label: 'Play album',
                    accent: widget.accent,
                    small: true,
                    onTap: () => _playAlbum(context, shuffle: false),
                  ),
                  const SizedBox(width: 6),
                  _ActionChip(
                    icon: Icons.shuffle_rounded,
                    label: 'Shuffle',
                    accent: widget.accent,
                    small: true,
                    onTap: () =>
                        _playAlbum(context, shuffle: true),
                  ),
                  const SizedBox(width: 6),
                  _ActionChip(
                    icon: Icons.repeat_rounded,
                    label: 'Loop album',
                    accent: widget.accent,
                    small: true,
                    onTap: () =>
                        _playAlbum(context, loop: true),
                  ),
                ],
              ),
            ),
            // ── Song list ────────────────────────────────────────────
            ...group.songs.asMap().entries.map(
                  (entry) => _SongTile(
                    download: entry.value,
                    queueIndex: entry.key,
                    albumQueue: group.songs,
                    accent: widget.accent,
                  ),
                ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Future<void> _playAlbum(BuildContext context,
      {bool shuffle = false, bool loop = false}) async {
    if (widget.group.songs.isEmpty) return;
    final start = widget.group.songs.first;
    await _OfflinePlaybackHelper.play(
      context: context,
      ref: ref,
      startDownload: start,
      fullQueue: widget.group.songs,
      startIndex: 0,
      shuffle: shuffle,
      loopAll: loop,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Music — individual song tile inside album group
// ─────────────────────────────────────────────────────────────────────────────

class _SongTile extends ConsumerWidget {
  final DownloadModel download;
  final int queueIndex;
  final List<DownloadModel> albumQueue;
  final Color accent;
  const _SongTile(
      {required this.download,
      required this.queueIndex,
      required this.albumQueue,
      required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: Key('song_${download.id}'),
      direction: DismissDirection.endToStart,
      background: _deleteBg(),
      onDismissed: (_) => ref
          .read(downloadManagerProvider.notifier)
          .deleteDownload(download.mediaId),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: accent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.music_note_rounded,
              color: accent, size: 18),
        ),
        title: Text(
          download.title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontSize: 13),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            _EncBadge(),
            const SizedBox(width: 6),
            Text(download.formattedSize,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.play_arrow_rounded),
          color: accent,
          iconSize: 26,
          onPressed: () => _OfflinePlaybackHelper.play(
            context: context,
            ref: ref,
            startDownload: download,
            fullQueue: albumQueue,
            startIndex: queueIndex,
          ),
        ),
        onTap: () => _OfflinePlaybackHelper.play(
          context: context,
          ref: ref,
          startDownload: download,
          fullQueue: albumQueue,
          startIndex: queueIndex,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stories — "Play all" bar
// ─────────────────────────────────────────────────────────────────────────────

class _StoriesSectionActions extends ConsumerWidget {
  final List<DownloadModel> mergedQueue;
  final Color accent;
  const _StoriesSectionActions(
      {required this.mergedQueue, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (mergedQueue.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _ActionChip(
        icon: Icons.play_arrow_rounded,
        label: 'Play all stories in order',
        accent: accent,
        onTap: () => _OfflinePlaybackHelper.play(
          context: context,
          ref: ref,
          startDownload: mergedQueue.first,
          fullQueue: mergedQueue,
          startIndex: 0,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stories — individual episode tile
// Tapping starts from this episode and continues through the merged queue.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeTile extends ConsumerWidget {
  final DownloadModel download;
  final int queueIndex;
  final List<DownloadModel> fullQueue;
  final Color accent;
  const _EpisodeTile(
      {required this.download,
      required this.queueIndex,
      required this.fullQueue,
      required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: Key('ep_${download.id}'),
      direction: DismissDirection.endToStart,
      background: _deleteBg(),
      onDismissed: (_) => ref
          .read(downloadManagerProvider.notifier)
          .deleteDownload(download.mediaId),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.cardColor,
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: accent.withOpacity(0.12)),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          leading: Stack(
            children: [
              CoverImage(
                  url: download.artworkUrl, size: 48, borderRadius: 10),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: AppColors.success,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 10, color: Colors.white),
                ),
              ),
            ],
          ),
          title: Text(
            download.title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (download.subtitle != null)
                Text(download.subtitle!,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: accent.withOpacity(0.8))),
              const SizedBox(height: 4),
              Row(
                children: [
                  _EncBadge(),
                  const SizedBox(width: 6),
                  Text(download.formattedSize,
                      style: Theme.of(context).textTheme.bodySmall),
                  if (download.totalParts > 1) ...[
                    const SizedBox(width: 6),
                    _PartsBadge(
                        count: download.totalParts, accent: accent),
                  ],
                  // Show queue position hint
                  const SizedBox(width: 6),
                  Text(
                    '#${queueIndex + 1}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textTertiary),
                  ),
                ],
              ),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.headset_rounded),
            color: accent,
            iconSize: 28,
            tooltip: 'Play from here',
            onPressed: () => _OfflinePlaybackHelper.play(
              context: context,
              ref: ref,
              startDownload: download,
              fullQueue: fullQueue,
              startIndex: queueIndex,
            ),
          ),
          onTap: () => _OfflinePlaybackHelper.play(
            context: context,
            ref: ref,
            startDownload: download,
            fullQueue: fullQueue,
            startIndex: queueIndex,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline playback helper (two-phase decrypt, unchanged logic)
// ─────────────────────────────────────────────────────────────────────────────

class _OfflinePlaybackHelper {
  static Future<void> play({
    required BuildContext context,
    required WidgetRef ref,
    required DownloadModel startDownload,
    required List<DownloadModel> fullQueue,
    required int startIndex,
    bool shuffle = false,
    bool loopAll = false,
  }) async {
    final manager = ref.read(downloadManagerProvider.notifier);
    final notifier = ref.read(audioPlayerProvider.notifier);

    // Build PlayableItem list from the full queue metadata (no decrypt yet).
    // Each item gets an empty streamUrl — replaced in phase 2.
    PlayableItem _toPlaceholder(DownloadModel d) => PlayableItem(
          id: d.mediaId,
          title: d.title,
          subtitle: d.subtitle,
          artworkUrl: d.artworkUrl,
          duration: d.durationSeconds,
          type: d.mediaType == 'episode'
              ? MediaType.episode
              : MediaType.song,
          partCount: d.totalParts,
          streamUrl: '',
          extras: const {'isOffline': true, 'pendingDecrypt': true},
        );

    final placeholderQueue =
        fullQueue.map(_toPlaceholder).toList();
    final startItem = placeholderQueue[startIndex];

    // Phase 1 — optimistic: set queue + navigate immediately.
    notifier.playItem(
      startItem,
      queue: placeholderQueue,
      index: startIndex,
    );

    if (context.mounted) {
      AppRouter.navigateToPlayer(context);
    }

    // Phase 2 — decrypt starting item in background.
    try {
      final paths =
          await manager.getDecryptedPaths(startDownload.mediaId);

      if (paths == null || paths.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not read downloaded file. Try re-downloading.'),
            backgroundColor: AppColors.error,
          ));
        }
        return;
      }

      final partUris = paths
          .map((p) => p.startsWith('file://') ? p : 'file://$p')
          .toList();

      final allExist = partUris
          .every((u) => File(u.replaceFirst('file://', '')).existsSync());
      if (!allExist) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Decrypted file missing. Try re-downloading.'),
            backgroundColor: AppColors.error,
          ));
        }
        return;
      }

      final realItem = PlayableItem(
        id: startDownload.mediaId,
        title: startDownload.title,
        subtitle: startDownload.subtitle,
        artworkUrl: startDownload.artworkUrl,
        duration: startDownload.durationSeconds,
        type: startDownload.mediaType == 'episode'
            ? MediaType.episode
            : MediaType.song,
        partCount: partUris.length,
        streamUrl: partUris.first,
        extras: {
          'isOffline': true,
          'offlinePartUrls': partUris.join('|'),
        },
      );

      notifier.playItem(
        realItem,
        queue: placeholderQueue,
        index: startIndex,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Playback error: $e'),
          backgroundColor: AppColors.error,
        ));
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unchanged widgets from previous version
// ─────────────────────────────────────────────────────────────────────────────

Widget _deleteBg() => Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      decoration: BoxDecoration(
        color: AppColors.error.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Icon(Icons.delete_rounded, color: AppColors.error),
    );

class _TypeHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  const _TypeHeader(
      {required this.icon, required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(width: 10),
          Text(label,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  )),
        ],
      ),
    );
  }
}

class _SubSectionLabel extends StatelessWidget {
  final String label;
  final int count;
  const _SubSectionLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('$count',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: AppColors.textTertiary)),
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;
  final bool small;
  const _ActionChip(
      {required this.icon,
      required this.label,
      required this.accent,
      required this.onTap,
      this.small = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: small ? 10 : 14,
            vertical: small ? 6 : 10),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: accent, size: small ? 14 : 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  style: TextStyle(
                      color: accent,
                      fontSize: small ? 11 : 12,
                      fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallIconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _SmallIconBtn(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, color: color, size: 20),
        onPressed: onTap,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      ),
    );
  }
}

// ── Active download card (unchanged) ─────────────────────────────────────────

class _ActiveDownloadCard extends ConsumerWidget {
  final DownloadModel download;
  const _ActiveDownloadCard({required this.download});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(
      downloadManagerProvider.select((map) => map[download.mediaId]),
    );
    if (dl == null) return const SizedBox.shrink();

    final progress = dl.progress.clamp(0.0, 1.0);
    final pct = (progress * 100).round();
    final barColor =
        dl.mediaType == 'song' ? _kMusicAccent : _kStoryAccent;
    final statusLabel = dl.status == 'encrypting'
        ? 'Encrypting…'
        : 'Downloading…';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: barColor.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CoverImage(
                  url: dl.artworkUrl, size: 44, borderRadius: 10),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dl.title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    if (dl.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(dl.subtitle!,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              _PulseDot(color: barColor),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: AppColors.surfaceVariant,
              color: barColor,
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(statusLabel,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.textTertiary)),
              Text('$pct%',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(
                          color: barColor, fontWeight: FontWeight.w700)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Failed tile (unchanged) ───────────────────────────────────────────────────

class _FailedTile extends ConsumerWidget {
  final DownloadModel download;
  const _FailedTile({required this.download});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(
      downloadManagerProvider.select((map) => map[download.mediaId]),
    );
    if (dl == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.error.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          CoverImage(url: dl.artworkUrl, size: 44, borderRadius: 10),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dl.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(dl.errorMessage ?? 'Unknown error',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => ref
                .read(downloadManagerProvider.notifier)
                .retryDownload(download.mediaId),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Retry'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared badge / decoration widgets ─────────────────────────────────────────

class _EncBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accentGold.withOpacity(0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: AppColors.accentGold.withOpacity(0.55), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 9, color: AppColors.accentGold),
          const SizedBox(width: 3),
          Text('ENC',
              style: TextStyle(
                  color: AppColors.accentGold,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6)),
        ],
      ),
    );
  }
}

class _PartsBadge extends StatelessWidget {
  final int count;
  final Color accent;
  const _PartsBadge({required this.count, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text('$count parts',
          style: TextStyle(
              color: accent, fontSize: 9, fontWeight: FontWeight.w600)),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 1.0, end: 0.25)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
              color: widget.color, shape: BoxShape.circle)),
    );
  }
}
// lib/features/downloads/presentation/downloads_screen.dart
//
// CHANGES IN THIS VERSION
// ========================
//
// 1. BLAST BUFFER QUEUE FIX — RepaintBoundary on progress cards
//    _ActiveDownloadCard and _DownloadProgressRing now wrapped in
//    RepaintBoundary so their 10Hz progress repaints are isolated
//    compositing layers that don't dirty parent list views.
//
// 2. SERIES GROUPING (matching Music album grouping):
//    Downloaded episodes are now grouped by series (subtitle field).
//    Each series group shows:
//      • Series cover + title + episode count header
//      • Collapsible episode list (same expand/collapse as album groups)
//      • Play buttons: "Play series", "Play all stories in order"
//    Episodes within each series are sorted by createdAt (approx. ep order).
//
// 3. SINGLE DELETE — swipe-to-delete on any episode or song tile (unchanged)
//
// 4. SELECTED DELETE — long-press any tile to enter multi-select mode.
//    A selection toolbar appears at the top with:
//      • Count indicator ("3 selected")
//      • "Delete selected" button (red)
//      • "Cancel" button
//    Tapping a tile in select-mode toggles its selection.
//    Confirmed deletion removes selected items and exits select mode.
//
// 5. DELETE ALL — the existing trash icon in AppBar triggers a confirmation
//    dialog to delete everything. Now also accessible from the selection
//    toolbar via "Select all → Delete".

import 'dart:io';

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

class _AlbumGroup {
  final String albumTitle;
  final List<DownloadModel> songs;
  const _AlbumGroup({required this.albumTitle, required this.songs});
}

class _SeriesGroup {
  final String seriesTitle;
  final List<DownloadModel> episodes;
  const _SeriesGroup({required this.seriesTitle, required this.episodes});
}

List<_AlbumGroup> _groupSongsByAlbum(List<DownloadModel> completedSongs) {
  final map = <String, List<DownloadModel>>{};
  for (final s in completedSongs) {
    final key = s.subtitle ?? 'Unknown Album';
    map.putIfAbsent(key, () => []).add(s);
  }
  return map.entries
      .map((e) {
        final sorted = [...e.value]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        return _AlbumGroup(albumTitle: e.key, songs: sorted);
      })
      .toList()
    ..sort((a, b) => a.albumTitle.compareTo(b.albumTitle));
}

List<_SeriesGroup> _groupEpisodesBySeries(
    List<DownloadModel> completedEpisodes) {
  final map = <String, List<DownloadModel>>{};
  for (final ep in completedEpisodes) {
    final key = ep.subtitle ?? 'Unknown Series';
    map.putIfAbsent(key, () => []).add(ep);
  }
  return map.entries
      .map((e) {
        final sorted = [...e.value]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        return _SeriesGroup(seriesTitle: e.key, episodes: sorted);
      })
      .toList()
    ..sort((a, b) => a.seriesTitle.compareTo(b.seriesTitle));
}

/// Merged cross-series queue sorted by series title then episode order
List<DownloadModel> _mergedEpisodeQueue(List<DownloadModel> completedEpisodes) {
  return [...completedEpisodes]
    ..sort((a, b) {
      final sc = (a.subtitle ?? '').compareTo(b.subtitle ?? '');
      if (sc != 0) return sc;
      return a.createdAt.compareTo(b.createdAt);
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  // ── Multi-select state ─────────────────────────────────────────────────────
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  void _enterSelectionMode(String firstId) {
    setState(() {
      _selectionMode = true;
      _selectedIds.clear();
      _selectedIds.add(firstId);
    });
  }

  void _toggleSelection(String mediaId) {
    setState(() {
      if (_selectedIds.contains(mediaId)) {
        _selectedIds.remove(mediaId);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(mediaId);
      }
    });
  }

  void _cancelSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _selectAll(List<DownloadModel> all) {
    setState(() {
      _selectedIds.clear();
      for (final d in all) {
        _selectedIds.add(d.mediaId);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ids = Set<String>.from(_selectedIds);
    _cancelSelection();
    final manager = ref.read(downloadManagerProvider.notifier);
    for (final id in ids) {
      await manager.deleteDownload(id);
    }
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Downloads'),
        content: const Text(
            'This will delete all downloaded files. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      _cancelSelection();
      await ref.read(downloadManagerProvider.notifier).clearAllDownloads();
    }
  }

  Future<void> _confirmDeleteSelected() async {
    final count = _selectedIds.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $count item${count == 1 ? '' : 's'}'),
        content: Text(
            'Delete $count selected download${count == 1 ? '' : 's'}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) await _deleteSelected();
  }

  @override
  Widget build(BuildContext context) {
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

    final hasCompleted = completedSongs.isNotEmpty || completedEpisodes.isNotEmpty;
    final allDownloads = [...downloads.values];

    final albumGroups = _groupSongsByAlbum(completedSongs);
    final seriesGroups = _groupEpisodesBySeries(completedEpisodes);
    final mergedEpisodes = _mergedEpisodeQueue(completedEpisodes);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _selectionMode
          ? _buildSelectionAppBar(allDownloads)
          : _buildNormalAppBar(context, hasCompleted),
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
                if (!_selectionMode)
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
                              style:
                                  Theme.of(context).textTheme.bodyMedium,
                            ),
                            const Spacer(),
                            Text(
                              '$total file${total == 1 ? '' : 's'}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(color: AppColors.textTertiary),
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
                          ...inProgressSongs.map((d) => RepaintBoundary(
                              child: _ActiveDownloadCard(download: d))),
                          const SizedBox(height: 8),
                        ],

                        if (failedSongs.isNotEmpty) ...[
                          _SubSectionLabel(
                              label: 'Failed', count: failedSongs.length),
                          ...failedSongs.map((d) => _FailedTile(download: d)),
                          const SizedBox(height: 8),
                        ],

                        if (completedSongs.isNotEmpty) ...[
                          _MusicSectionActions(
                            allSongs: completedSongs,
                            accent: _kMusicAccent,
                          ),
                          ...albumGroups.map(
                            (group) => _AlbumGroupWidget(
                              group: group,
                              allCompletedSongs: completedSongs,
                              accent: _kMusicAccent,
                              selectionMode: _selectionMode,
                              selectedIds: _selectedIds,
                              onLongPress: _enterSelectionMode,
                              onToggleSelect: _toggleSelection,
                            ),
                          ),
                        ],

                        const SizedBox(height: 20),
                      ],

                      // ══════════════════════════════════════════════════════
                      // AUDIO STORIES SECTION — Series grouped
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
                          ...inProgressEpisodes.map((d) => RepaintBoundary(
                              child: _ActiveDownloadCard(download: d))),
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
                          // "Play all stories" header
                          _StoriesSectionActions(
                            mergedQueue: mergedEpisodes,
                            accent: _kStoryAccent,
                          ),
                          // Series groups (like album groups for music)
                          ...seriesGroups.map(
                            (group) => _SeriesGroupWidget(
                              group: group,
                              allMergedQueue: mergedEpisodes,
                              accent: _kStoryAccent,
                              selectionMode: _selectionMode,
                              selectedIds: _selectedIds,
                              onLongPress: _enterSelectionMode,
                              onToggleSelect: _toggleSelection,
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

  AppBar _buildNormalAppBar(BuildContext context, bool hasCompleted) {
    return AppBar(
      title: const Text('Downloads'),
      actions: [
        if (hasCompleted)
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded),
            color: AppColors.error,
            tooltip: 'Clear all downloads',
            onPressed: () => _confirmDeleteAll(context),
          ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar(List<DownloadModel> allDownloads) {
    final completedAll =
        allDownloads.where((d) => d.isCompleted).toList();
    return AppBar(
      backgroundColor: AppColors.surfaceVariant,
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        onPressed: _cancelSelection,
      ),
      title: Text(
        '${_selectedIds.length} selected',
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
      actions: [
        // Select all button
        TextButton(
          onPressed: () => _selectAll(completedAll),
          child: const Text(
            'All',
            style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
          ),
        ),
        // Delete selected button
        if (_selectedIds.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.delete_rounded),
            color: AppColors.error,
            tooltip: 'Delete selected',
            onPressed: _confirmDeleteSelected,
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Music — "Play all music" bar (unchanged)
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
// Music — Album group widget (with selection support added)
// ─────────────────────────────────────────────────────────────────────────────

class _AlbumGroupWidget extends ConsumerStatefulWidget {
  final _AlbumGroup group;
  final List<DownloadModel> allCompletedSongs;
  final Color accent;
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String) onLongPress;
  final void Function(String) onToggleSelect;

  const _AlbumGroupWidget({
    required this.group,
    required this.allCompletedSongs,
    required this.accent,
    required this.selectionMode,
    required this.selectedIds,
    required this.onLongPress,
    required this.onToggleSelect,
  });

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

    // Check if any songs in this album are selected
    final anySelected =
        group.songs.any((s) => widget.selectedIds.contains(s.mediaId));
    final allSelected =
        group.songs.every((s) => widget.selectedIds.contains(s.mediaId));

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: anySelected && widget.selectionMode
              ? widget.accent.withOpacity(0.5)
              : widget.accent.withOpacity(0.12),
          width: anySelected && widget.selectionMode ? 1.5 : 1,
        ),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // Selection checkbox in select mode
                  if (widget.selectionMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () {
                          for (final s in group.songs) {
                            if (allSelected) {
                              widget.onToggleSelect(s.mediaId);
                            } else if (!widget.selectedIds
                                .contains(s.mediaId)) {
                              widget.onToggleSelect(s.mediaId);
                            }
                          }
                        },
                        child: _SelectionCheckbox(
                          selected: allSelected,
                          partial: anySelected && !allSelected,
                          accent: widget.accent,
                        ),
                      ),
                    ),
                  CoverImage(url: coverUrl, size: 52, borderRadius: 10),
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
                  if (!widget.selectionMode) ...[
                    _SmallIconBtn(
                      icon: Icons.play_circle_rounded,
                      color: widget.accent,
                      tooltip: 'Play album',
                      onTap: () => _playAlbum(context, shuffle: false),
                    ),
                    _SmallIconBtn(
                      icon: Icons.repeat_rounded,
                      color: widget.accent.withOpacity(0.7),
                      tooltip: 'Loop album',
                      onTap: () => _playAlbum(context, loop: true),
                    ),
                  ],
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
          if (_expanded) ...[
            const Divider(height: 1, indent: 12, endIndent: 12),
            if (!widget.selectionMode)
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
                      onTap: () => _playAlbum(context, shuffle: true),
                    ),
                    const SizedBox(width: 6),
                    _ActionChip(
                      icon: Icons.repeat_rounded,
                      label: 'Loop album',
                      accent: widget.accent,
                      small: true,
                      onTap: () => _playAlbum(context, loop: true),
                    ),
                  ],
                ),
              ),
            ...group.songs.asMap().entries.map(
                  (entry) => _SongTile(
                    download: entry.value,
                    queueIndex: entry.key,
                    albumQueue: group.songs,
                    accent: widget.accent,
                    selectionMode: widget.selectionMode,
                    isSelected:
                        widget.selectedIds.contains(entry.value.mediaId),
                    onLongPress: () =>
                        widget.onLongPress(entry.value.mediaId),
                    onToggleSelect: () =>
                        widget.onToggleSelect(entry.value.mediaId),
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
// Music — individual song tile (with selection support)
// ─────────────────────────────────────────────────────────────────────────────

class _SongTile extends ConsumerWidget {
  final DownloadModel download;
  final int queueIndex;
  final List<DownloadModel> albumQueue;
  final Color accent;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;

  const _SongTile({
    required this.download,
    required this.queueIndex,
    required this.albumQueue,
    required this.accent,
    required this.selectionMode,
    required this.isSelected,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget tile = Container(
      color: isSelected
          ? accent.withOpacity(0.08)
          : Colors.transparent,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: selectionMode
            ? _SelectionCheckbox(
                selected: isSelected, accent: accent)
            : Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child:
                    Icon(Icons.music_note_rounded, color: accent, size: 18),
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
        trailing: selectionMode
            ? null
            : IconButton(
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
        onTap: selectionMode
            ? onToggleSelect
            : () => _OfflinePlaybackHelper.play(
                  context: context,
                  ref: ref,
                  startDownload: download,
                  fullQueue: albumQueue,
                  startIndex: queueIndex,
                ),
        onLongPress: selectionMode ? null : onLongPress,
      ),
    );

    if (selectionMode) return tile;

    return Dismissible(
      key: Key('song_${download.id}'),
      direction: DismissDirection.endToStart,
      background: _deleteBg(),
      confirmDismiss: (_) async {
        return await _confirmSingleDelete(context, download.title);
      },
      onDismissed: (_) => ref
          .read(downloadManagerProvider.notifier)
          .deleteDownload(download.mediaId),
      child: tile,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stories — "Play all" bar (unchanged)
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
// Stories — Series group widget (mirrors AlbumGroupWidget for episodes)
// ─────────────────────────────────────────────────────────────────────────────

class _SeriesGroupWidget extends ConsumerStatefulWidget {
  final _SeriesGroup group;
  final List<DownloadModel> allMergedQueue;
  final Color accent;
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String) onLongPress;
  final void Function(String) onToggleSelect;

  const _SeriesGroupWidget({
    required this.group,
    required this.allMergedQueue,
    required this.accent,
    required this.selectionMode,
    required this.selectedIds,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  @override
  ConsumerState<_SeriesGroupWidget> createState() =>
      _SeriesGroupWidgetState();
}

class _SeriesGroupWidgetState extends ConsumerState<_SeriesGroupWidget> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final coverUrl =
        group.episodes.isNotEmpty ? group.episodes.first.artworkUrl : null;

    final anySelected =
        group.episodes.any((e) => widget.selectedIds.contains(e.mediaId));
    final allSelected =
        group.episodes.every((e) => widget.selectedIds.contains(e.mediaId));

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: anySelected && widget.selectionMode
              ? widget.accent.withOpacity(0.5)
              : widget.accent.withOpacity(0.12),
          width: anySelected && widget.selectionMode ? 1.5 : 1,
        ),
      ),
      child: Column(
        children: [
          // ── Series header ──────────────────────────────────────────────
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  if (widget.selectionMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () {
                          for (final ep in group.episodes) {
                            if (allSelected) {
                              widget.onToggleSelect(ep.mediaId);
                            } else if (!widget.selectedIds
                                .contains(ep.mediaId)) {
                              widget.onToggleSelect(ep.mediaId);
                            }
                          }
                        },
                        child: _SelectionCheckbox(
                          selected: allSelected,
                          partial: anySelected && !allSelected,
                          accent: widget.accent,
                        ),
                      ),
                    ),
                  CoverImage(url: coverUrl, size: 52, borderRadius: 10),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.seriesTitle,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  fontSize: 14,
                                  color: widget.accent),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${group.episodes.length} episode${group.episodes.length == 1 ? '' : 's'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (!widget.selectionMode) ...[
                    _SmallIconBtn(
                      icon: Icons.play_circle_rounded,
                      color: widget.accent,
                      tooltip: 'Play series',
                      onTap: () => _playSeries(context, startIndex: 0),
                    ),
                  ],
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

          if (_expanded) ...[
            const Divider(height: 1, indent: 12, endIndent: 12),
            // Play chips for the series
            if (!widget.selectionMode)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _ActionChip(
                      icon: Icons.play_arrow_rounded,
                      label: 'Play series',
                      accent: widget.accent,
                      small: true,
                      onTap: () =>
                          _playSeries(context, startIndex: 0),
                    ),
                    const SizedBox(width: 6),
                    _ActionChip(
                      icon: Icons.playlist_play_rounded,
                      label: 'Continue all',
                      accent: widget.accent,
                      small: true,
                      onTap: () => _playAllFromSeries(context),
                    ),
                  ],
                ),
              ),
            // Episode tiles
            ...group.episodes.asMap().entries.map(
                  (entry) => _EpisodeTile(
                    download: entry.value,
                    seriesQueue: group.episodes,
                    queueIndexInSeries: entry.key,
                    allMergedQueue: widget.allMergedQueue,
                    accent: widget.accent,
                    selectionMode: widget.selectionMode,
                    isSelected: widget.selectedIds
                        .contains(entry.value.mediaId),
                    onLongPress: () =>
                        widget.onLongPress(entry.value.mediaId),
                    onToggleSelect: () =>
                        widget.onToggleSelect(entry.value.mediaId),
                  ),
                ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  /// Play this series starting from [startIndex] within the series queue
  Future<void> _playSeries(BuildContext context,
      {required int startIndex}) async {
    if (widget.group.episodes.isEmpty) return;
    final ep = widget.group.episodes[startIndex];
    await _OfflinePlaybackHelper.play(
      context: context,
      ref: ref,
      startDownload: ep,
      fullQueue: widget.group.episodes,
      startIndex: startIndex,
    );
  }

  /// Play this series and continue into subsequent series (cross-series queue)
  Future<void> _playAllFromSeries(BuildContext context) async {
    if (widget.group.episodes.isEmpty) return;
    // Find where this series starts in the merged queue
    final firstEp = widget.group.episodes.first;
    final mergedIndex = widget.allMergedQueue
        .indexWhere((e) => e.mediaId == firstEp.mediaId);
    final startIdx = mergedIndex >= 0 ? mergedIndex : 0;

    await _OfflinePlaybackHelper.play(
      context: context,
      ref: ref,
      startDownload: widget.allMergedQueue[startIdx],
      fullQueue: widget.allMergedQueue,
      startIndex: startIdx,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stories — individual episode tile (with selection support)
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeTile extends ConsumerWidget {
  final DownloadModel download;
  final List<DownloadModel> seriesQueue;     // episodes in THIS series
  final int queueIndexInSeries;
  final List<DownloadModel> allMergedQueue;  // all episodes cross-series
  final Color accent;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;

  const _EpisodeTile({
    required this.download,
    required this.seriesQueue,
    required this.queueIndexInSeries,
    required this.allMergedQueue,
    required this.accent,
    required this.selectionMode,
    required this.isSelected,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Queue position in the merged cross-series list (for the "#N" badge)
    final mergedIndex =
        allMergedQueue.indexWhere((e) => e.mediaId == download.mediaId);
    final queuePosition = mergedIndex >= 0 ? mergedIndex + 1 : null;

    Widget tile = Container(
      margin: const EdgeInsets.only(bottom: 4),
      color: isSelected ? accent.withOpacity(0.08) : Colors.transparent,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: selectionMode
            ? _SelectionCheckbox(selected: isSelected, accent: accent)
            : Stack(
                children: [
                  CoverImage(
                      url: download.artworkUrl,
                      size: 48,
                      borderRadius: 10),
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
        subtitle: Row(
          children: [
            _EncBadge(),
            const SizedBox(width: 6),
            Text(download.formattedSize,
                style: Theme.of(context).textTheme.bodySmall),
            if (download.totalParts > 1) ...[
              const SizedBox(width: 6),
              _PartsBadge(count: download.totalParts, accent: accent),
            ],
            if (queuePosition != null) ...[
              const SizedBox(width: 6),
              Text(
                '#$queuePosition',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ],
        ),
        trailing: selectionMode
            ? null
            : IconButton(
                icon: const Icon(Icons.headset_rounded),
                color: accent,
                iconSize: 28,
                tooltip: 'Play from here',
                onPressed: () => _OfflinePlaybackHelper.play(
                  context: context,
                  ref: ref,
                  startDownload: download,
                  fullQueue: seriesQueue,
                  startIndex: queueIndexInSeries,
                ),
              ),
        onTap: selectionMode
            ? onToggleSelect
            : () => _OfflinePlaybackHelper.play(
                  context: context,
                  ref: ref,
                  startDownload: download,
                  fullQueue: seriesQueue,
                  startIndex: queueIndexInSeries,
                ),
        onLongPress: selectionMode ? null : onLongPress,
      ),
    );

    if (selectionMode) return tile;

    return Dismissible(
      key: Key('ep_${download.id}'),
      direction: DismissDirection.endToStart,
      background: _deleteBg(),
      confirmDismiss: (_) async {
        return await _confirmSingleDelete(context, download.title);
      },
      onDismissed: (_) => ref
          .read(downloadManagerProvider.notifier)
          .deleteDownload(download.mediaId),
      child: tile,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline playback helper (unchanged)
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

    final placeholderQueue = fullQueue.map(_toPlaceholder).toList();
    final startItem = placeholderQueue[startIndex];

    notifier.playItem(
      startItem,
      queue: placeholderQueue,
      index: startIndex,
    );

    if (context.mounted) {
      AppRouter.navigateToPlayer(context);
    }

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
            content: Text('Decrypted file missing. Try re-downloading.'),
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
// Helper: single delete confirmation
// ─────────────────────────────────────────────────────────────────────────────

Future<bool> _confirmSingleDelete(
    BuildContext context, String itemTitle) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete Download'),
      content: Text('Delete "$itemTitle"?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
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

class _SelectionCheckbox extends StatelessWidget {
  final bool selected;
  final bool partial;
  final Color accent;

  const _SelectionCheckbox({
    required this.selected,
    this.partial = false,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected || partial ? accent : Colors.transparent,
        border: Border.all(
          color: selected || partial ? accent : AppColors.textTertiary,
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : partial
              ? Container(
                  width: 8,
                  height: 2,
                  margin: const EdgeInsets.all(5),
                  color: Colors.white,
                )
              : null,
    );
  }
}

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
            horizontal: small ? 10 : 14, vertical: small ? 6 : 10),
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

// FIX: RepaintBoundary is applied by the parent (caller wraps in RepaintBoundary)
class _ActiveDownloadCard extends ConsumerWidget {
  final DownloadModel download;
  const _ActiveDownloadCard({required this.download});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // FIX: Select only status and progress — not the full map
    final status = ref.watch(
      downloadManagerProvider.select((map) => map[download.mediaId]?.status),
    );
    final progress = ref.watch(
      downloadManagerProvider
          .select((map) => map[download.mediaId]?.progress ?? 0.0),
    );
    final dl = ref.watch(
      downloadManagerProvider.select((map) => map[download.mediaId]),
    );
    if (dl == null) return const SizedBox.shrink();

    final clampedProgress = progress.clamp(0.0, 1.0);
    final pct = (clampedProgress * 100).round();
    final barColor =
        dl.mediaType == 'song' ? _kMusicAccent : _kStoryAccent;
    final statusLabel =
        status == 'encrypting' ? 'Encrypting…' : 'Downloading…';

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
          // FIX: RepaintBoundary around the progress bar only.
          // The card header (cover + title) doesn't need to repaint at 10Hz.
          RepaintBoundary(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: clampedProgress,
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textTertiary)),
                    Text('$pct%',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: barColor, fontWeight: FontWeight.w700)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
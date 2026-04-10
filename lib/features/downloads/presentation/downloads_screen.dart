// lib/features/downloads/presentation/downloads_screen.dart
//
// CHANGES IN THIS VERSION
// ========================
//
// 1. INSTANT OFFLINE PLAYBACK
//    Old: _playOffline() called getDecryptedPaths() (blocking decrypt) BEFORE
//         navigating, showing a 15-second snackbar while decryption ran.
//    New: Two-phase approach:
//         a. Optimistic start — build PlayableItem from known metadata and
//            call playItem() + navigateToPlayer() synchronously on the next
//            frame (MiniPlayer appears immediately, player screen opens).
//         b. Background decrypt — decrypt runs concurrently; once paths are
//            ready, the item is re-issued to the handler via playItem() so
//            the actual file plays.  If decryption fails, an error snackbar
//            is shown without interrupting the player UI.
//    Fast-path: if the decrypted cache file already exists (warm cache),
//    the whole flow is instant — no spinner at all.
//
// 2. MEDIA TYPE SEPARATION
//    Downloads are split into two clearly-labelled top-level sections:
//      • 🎵 Music         — mediaType == 'song'
//      • 🎙 Audio Stories — mediaType == 'episode'
//    Each section has its own header style, icon, and accent colour so
//    users can never confuse a song download with a podcast/story episode.
//    The in-progress and failed lists are also split by type.
//    Sections are hidden when empty (no "0 items" clutter).

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

// ── Accent colours for each media type ────────────────────────────────────────
// Music uses the existing primary (purple/blue).
// Audio Stories uses a warm amber to look distinct at a glance.
const _kMusicAccent = AppColors.primary;
const _kStoryAccent = Color(0xFFEF9F27); // amber — same as the ENC badge

// ── Downloads screen ───────────────────────────────────────────────────────────

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadManagerProvider);
    final manager = ref.read(downloadManagerProvider.notifier);

    // Separate by type
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

    final hasAnything = downloads.isNotEmpty;
    final hasCompleted =
        completedSongs.isNotEmpty || completedEpisodes.isNotEmpty;

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
      body: !hasAnything
          ? const EmptyStateWidget(
              icon: Icons.download_rounded,
              title: 'No Downloads',
              subtitle:
                  'Downloaded music and audio stories appear here for offline listening',
            )
          : Column(
              children: [
                // ── Storage summary bar ──────────────────────────────────
                FutureBuilder<int>(
                  future: manager.getTotalStorageBytes(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data == 0) {
                      return const SizedBox.shrink();
                    }
                    final total = completedSongs.length +
                        completedEpisodes.length;
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
                      // ══════════════════════════════════════════════
                      // MUSIC section
                      // ══════════════════════════════════════════════
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
                          ...inProgressSongs.map(
                              (d) => _ActiveDownloadCard(download: d)),
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
                          _SubSectionLabel(
                              label: 'Ready to play',
                              count: completedSongs.length),
                          ...completedSongs.map(
                            (d) => _CompletedTile(
                                download: d, accent: _kMusicAccent),
                          ),
                        ],

                        const SizedBox(height: 20),
                      ],

                      // ══════════════════════════════════════════════
                      // AUDIO STORIES section
                      // ══════════════════════════════════════════════
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
                          ...inProgressEpisodes.map(
                              (d) => _ActiveDownloadCard(download: d)),
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
                          _SubSectionLabel(
                              label: 'Ready to play',
                              count: completedEpisodes.length),
                          ...completedEpisodes.map(
                            (d) => _CompletedTile(
                                download: d, accent: _kStoryAccent),
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

// ── Type header (Music / Audio Stories) ───────────────────────────────────────

class _TypeHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;

  const _TypeHeader({
    required this.icon,
    required this.label,
    required this.accent,
  });

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
          Text(
            label,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
          ),
        ],
      ),
    );
  }
}

// ── Sub-section label (Downloading / Failed / Ready to play) ──────────────────

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
            child: Text(
              '$count',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Active download card ───────────────────────────────────────────────────────

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

    final Color barColor;
    final String statusLabel;

    switch (dl.status) {
      case 'encrypting':
        barColor = _kStoryAccent;
        final partInfo = dl.totalParts > 1
            ? ' part ${dl.downloadedParts}/${dl.totalParts}'
            : '';
        statusLabel = 'Encrypting$partInfo…';
        break;
      default:
        barColor = dl.mediaType == 'song' ? _kMusicAccent : _kStoryAccent;
        final partInfo = dl.totalParts > 1
            ? 'Part ${dl.downloadedParts}/${dl.totalParts}'
            : '';
        statusLabel =
            'Downloading${partInfo.isNotEmpty ? ' · $partInfo' : ''}…';
    }

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
                    Text(
                      dl.title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (dl.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(dl.subtitle!,
                          style:
                              Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
              Text(
                statusLabel,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textTertiary),
              ),
              Text(
                '$pct%',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(
                      color: barColor,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Failed tile ────────────────────────────────────────────────────────────────

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
                Text(
                  dl.title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  dl.errorMessage ?? 'Unknown error',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
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
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Completed tile ─────────────────────────────────────────────────────────────

class _CompletedTile extends ConsumerWidget {
  final DownloadModel download;
  final Color accent;

  const _CompletedTile({
    required this.download,
    required this.accent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: Key('completed_${download.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 10),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.error.withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child:
            const Icon(Icons.delete_rounded, color: AppColors.error),
      ),
      onDismissed: (_) => ref
          .read(downloadManagerProvider.notifier)
          .deleteDownload(download.mediaId),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.cardColor,
          borderRadius: BorderRadius.circular(16),
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
                ?.copyWith(fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (download.subtitle != null)
                Text(download.subtitle!,
                    style: Theme.of(context).textTheme.bodySmall),
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
                ],
              ),
            ],
          ),
          // ── Play button ────────────────────────────────────────────
          trailing: IconButton(
            icon: Icon(
              download.mediaType == 'song'
                  ? Icons.play_circle_rounded
                  : Icons.headset_rounded,
            ),
            color: accent,
            iconSize: 32,
            tooltip: 'Play',
            onPressed: () => _playOffline(context, ref),
          ),
          onTap: () => _playOffline(context, ref),
        ),
      ),
    );
  }

  // ── Instant offline playback ─────────────────────────────────────────────────
  //
  // PHASE 1 (synchronous, <1 frame):
  //   Build a PlayableItem from metadata that we already have in memory.
  //   Call playItem() — the provider sets state.currentItem + isLoading=true
  //   synchronously (see audio_player_provider.dart optimistic update).
  //   Navigate to the player screen immediately.
  //
  // PHASE 2 (background):
  //   getDecryptedPaths() runs concurrently.  When done:
  //     • If cache hit (file already decrypted) → effectively instant.
  //     • If cache miss → decrypt takes ~0.5-2 s depending on file size.
  //   Once paths are ready, call playItem() again with the real file URIs.
  //   The player screen is already open so the transition is seamless.
  //
  // Error handling:
  //   If decryption fails, show a snackbar WITHOUT closing the player screen.
  //   The user can tap back and retry the download if needed.

  Future<void> _playOffline(BuildContext context, WidgetRef ref) async {
    final manager = ref.read(downloadManagerProvider.notifier);
    final notifier = ref.read(audioPlayerProvider.notifier);

    // ── PHASE 1: immediate navigation ──────────────────────────────────────
    // We set streamUrl to an empty placeholder; AudioHandler won't actually
    // try to load it until PHASE 2 replaces it with real file URIs.
    // Setting extras['isLoading'] = true lets the handler know to wait.
    final placeholderItem = PlayableItem(
      id: download.mediaId,
      title: download.title,
      subtitle: download.subtitle,
      artworkUrl: download.artworkUrl,
      duration: download.durationSeconds,
      type: download.mediaType == 'episode'
          ? MediaType.episode
          : MediaType.song,
      partCount: download.totalParts,
      // Empty streamUrl — playItem() on the notifier sets currentItem
      // synchronously, so the mini player and player screen render metadata
      // (title, artwork, duration) before the file path is ready.
      streamUrl: '',
      extras: const {'isOffline': true, 'pendingDecrypt': true},
    );

    // Sets currentItem + isLoading=true on the NEXT frame (optimistic).
    notifier.playItem(placeholderItem);

    // Navigate immediately — MiniPlayer and PlayerScreen are already
    // watching state.currentItem which is now non-null.
    if (context.mounted) {
      AppRouter.navigateToPlayer(context);
    }

    // ── PHASE 2: background decrypt + real playback ─────────────────────────
    try {
      final decryptedPaths =
          await manager.getDecryptedPaths(download.mediaId);

      if (decryptedPaths == null || decryptedPaths.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
                  Text('Could not read downloaded file. Try re-downloading.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
        return;
      }

      // Verify all decrypted files exist (fast sanity check)
      final partUris = decryptedPaths.map((p) {
        final withScheme =
            p.startsWith('file://') ? p : 'file://$p';
        return withScheme;
      }).toList();

      final allExist =
          partUris.every((u) => File(u.replaceFirst('file://', '')).existsSync());
      if (!allExist) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Decrypted file missing. Try re-downloading.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
        return;
      }

      // Replace the placeholder with the real item
      final realItem = PlayableItem(
        id: download.mediaId,
        title: download.title,
        subtitle: download.subtitle,
        artworkUrl: download.artworkUrl,
        duration: download.durationSeconds,
        type: download.mediaType == 'episode'
            ? MediaType.episode
            : MediaType.song,
        partCount: partUris.length,
        streamUrl: partUris.first,
        extras: {
          'isOffline': true,
          'offlinePartUrls': partUris.join('|'),
        },
      );

      // playItem() will set the real source on the handler.
      // The player screen is already open — users see the seekbar
      // activate as soon as the first part buffers (usually <200 ms
      // for a cached local file).
      notifier.playItem(realItem);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Playback error: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }
}

// ── ENC badge ──────────────────────────────────────────────────────────────────

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
        boxShadow: [
          BoxShadow(
              color: AppColors.accentGold.withOpacity(0.2),
              blurRadius: 6),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 9, color: AppColors.accentGold),
          const SizedBox(width: 3),
          Text(
            'ENC',
            style: TextStyle(
              color: AppColors.accentGold,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Parts badge ────────────────────────────────────────────────────────────────

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
      child: Text(
        '$count parts',
        style: TextStyle(
          color: accent,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Pulsing dot ────────────────────────────────────────────────────────────────

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
        decoration:
            BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
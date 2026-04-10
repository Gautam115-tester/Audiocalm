// lib/features/downloads/presentation/downloads_screen.dart
//
// MULTI-PART OFFLINE PLAYBACK FIX
// =================================
// _playOffline now calls getDecryptedPaths() (plural) instead of
// getDecryptedPath() (singular).  For a 2-part episode this returns
// ['/path/part0_dec.audio', '/path/part1_dec.audio'].
//
// We build a PlayableItem with:
//   • streamUrl  = first part's file:// URI
//   • partCount  = actual number of parts
//   • extras['offlinePartUrls'] = all part URIs joined by '|'
//
// AudioHandler._buildPartUrls() reads offlinePartUrls from extras when
// the item is offline, so all parts are played sequentially with the
// existing multi-part logic and the seekbar stays unified.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/services/download_manager.dart';
import '../data/models/download_model.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadManagerProvider);
    final manager = ref.read(downloadManagerProvider.notifier);

    final completed = downloads.values.where((d) => d.isCompleted).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final inProgress = downloads.values.where((d) => d.isInProgress).toList();
    final failed = downloads.values.where((d) => d.isFailed).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (completed.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              color: AppColors.error,
              onPressed: () => _confirmClearAll(context, ref),
            ),
        ],
      ),
      body: downloads.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.download_rounded,
              title: 'No Downloads',
              subtitle: 'Downloaded content appears here for offline listening',
            )
          : Column(
              children: [
                FutureBuilder<int>(
                  future: manager.getTotalStorageBytes(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data == 0) {
                      return const SizedBox.shrink();
                    }
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
                            '${completed.length} file${completed.length == 1 ? '' : 's'}',
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
                      if (inProgress.isNotEmpty) ...[
                        _SectionLabel(
                            label: 'Downloading', count: inProgress.length),
                        ...inProgress
                            .map((d) => _ActiveDownloadCard(download: d)),
                        const SizedBox(height: 8),
                      ],
                      if (failed.isNotEmpty) ...[
                        _SectionLabel(
                            label: 'Failed', count: failed.length),
                        ...failed.map((d) => _FailedTile(download: d)),
                        const SizedBox(height: 8),
                      ],
                      if (completed.isNotEmpty) ...[
                        _SectionLabel(
                            label: 'Completed', count: completed.length),
                        ...completed.map((d) => _CompletedTile(download: d)),
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
              ref.read(downloadManagerProvider.notifier).clearAllDownloads();
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final int count;
  const _SectionLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
        barColor = const Color(0xFFEF9F27);
        final partInfo = dl.totalParts > 1
            ? ' part ${dl.downloadedParts}/${dl.totalParts}'
            : '';
        statusLabel = 'Encrypting$partInfo…';
        break;
      default:
        barColor = AppColors.primary;
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
        border: Border.all(color: AppColors.primary.withOpacity(0.12)),
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
                          style: Theme.of(context).textTheme.bodySmall),
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
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
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

// ── Completed tile ─────────────────────────────────────────────────────────────

class _CompletedTile extends ConsumerWidget {
  final DownloadModel download;
  const _CompletedTile({required this.download});

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
        child: const Icon(Icons.delete_rounded, color: AppColors.error),
      ),
      onDismissed: (_) => ref
          .read(downloadManagerProvider.notifier)
          .deleteDownload(download.mediaId),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.primary.withOpacity(0.07)),
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
                    _PartsBadge(count: download.totalParts),
                  ],
                ],
              ),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.play_circle_outline_rounded),
            color: AppColors.primary,
            onPressed: () => _playOffline(context, ref),
          ),
          onTap: () => _playOffline(context, ref),
        ),
      ),
    );
  }

  /// Decrypt ALL part files and hand them to the AudioHandler for
  /// seamless sequential playback with unified seekbar.
  Future<void> _playOffline(BuildContext context, WidgetRef ref) async {
    final manager = ref.read(downloadManagerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);

    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: const [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Preparing offline playback…'),
          ],
        ),
        duration: const Duration(seconds: 15),
        backgroundColor: AppColors.surfaceVariant,
      ),
    );

    try {
      // Returns [decryptedPath_part0, decryptedPath_part1, ...] in order
      final decryptedPaths =
          await manager.getDecryptedPaths(download.mediaId);

      messenger.hideCurrentSnackBar();

      if (decryptedPaths == null || decryptedPaths.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Could not read downloaded file. Try re-downloading.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
        return;
      }

      // Ensure all paths have file:// scheme
      final partUris = decryptedPaths
          .map((p) => p.startsWith('file://') ? p : 'file://$p')
          .toList();

      // AudioHandler reads offlinePartUrls (pipe-separated) from extras
      // to build its _partUrls list, enabling full multi-part playback.
      final item = PlayableItem(
        id: download.mediaId,
        title: download.title,
        subtitle: download.subtitle,
        artworkUrl: download.artworkUrl,
        // FIX: Pass stored total duration so AudioHandler sets
        // _knownTotalDuration from the start. Without this, the handler
        // only knows part 1's duration, causing:
        //   • seekbar max = 06:58 (part 1 only) while position grows to 13:56
        //   • duration jumping when part 2 loads
        duration: download.durationSeconds,
        type: download.mediaType == 'episode'
            ? MediaType.episode
            : MediaType.song,
        partCount: partUris.length,
        streamUrl: partUris.first, // first part (used for single-part fast path)
        extras: {
          'isOffline': true,
          'offlinePartUrls': partUris.join('|'), // all parts for multi-part
        },
      );

      if (!context.mounted) return;
      ref.read(audioPlayerProvider.notifier).playItem(item);
      AppRouter.navigateToPlayer(context);
    } catch (e) {
      messenger.hideCurrentSnackBar();
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
              color: AppColors.accentGold.withOpacity(0.2), blurRadius: 6)
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
  const _PartsBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$count parts',
        style: TextStyle(
          color: AppColors.primary,
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
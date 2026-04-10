// lib/features/downloads/presentation/downloads_screen.dart
//
// Changes:
// - Failed items show a "Retry" button instead of just error text
// - Error messages are cleaner (no "DioException [unknown]: null")
// - Active download card shows the correct phase label

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
                        ...completed
                            .map((d) => _CompletedTile(download: d)),
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
      case 'merging':
        barColor = const Color(0xFFEF9F27);
        statusLabel = 'Merging parts…';
        break;
      case 'encrypting':
        barColor = const Color(0xFFEF9F27);
        statusLabel = 'Encrypting…';
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
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: dl.artworkUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: CoverImage(
                            url: dl.artworkUrl, size: 48, borderRadius: 10),
                      )
                    : Icon(
                        dl.mediaType == 'episode'
                            ? Icons.headphones_rounded
                            : Icons.music_note_rounded,
                        color: AppColors.textTertiary,
                        size: 22,
                      ),
              ),
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
                      Text(
                        dl.subtitle!,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: barColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress > 0 ? progress : null,
              backgroundColor: AppColors.surfaceVariant,
              color: barColor,
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _PulseDot(color: barColor),
              const SizedBox(width: 6),
              Text(
                statusLabel,
                style: TextStyle(fontSize: 11, color: barColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Failed tile with retry ─────────────────────────────────────────────────────

class _FailedTile extends ConsumerWidget {
  final DownloadModel download;
  const _FailedTile({required this.download});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Clean up the error message — remove class name prefixes
    String errorMsg = download.errorMessage ?? 'Download failed';
    errorMsg = errorMsg
        .replaceAll('DioException [unknown]: ', '')
        .replaceAll('Exception: ', '');
    if (errorMsg == 'null' || errorMsg.isEmpty) {
      errorMsg = 'Network error — tap Retry';
    }

    return Dismissible(
      key: Key('failed_${download.id}'),
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
      onDismissed: (_) {
        ref
            .read(downloadManagerProvider.notifier)
            .deleteDownload(download.mediaId);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.error.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.error_outline_rounded,
                  color: AppColors.error, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    download.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    errorMsg,
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
            // Retry button
            TextButton.icon(
              onPressed: () {
                ref
                    .read(downloadManagerProvider.notifier)
                    .retryDownload(download.mediaId);
              },
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
      onDismissed: (_) {
        ref
            .read(downloadManagerProvider.notifier)
            .deleteDownload(download.mediaId);
      },
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
                  // ENC lock badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.accentGold.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: AppColors.accentGold.withOpacity(0.55),
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accentGold.withOpacity(0.2),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_rounded,
                            size: 9, color: AppColors.accentGold),
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
                  ),
                  const SizedBox(width: 6),
                  Text(download.formattedSize,
                      style: Theme.of(context).textTheme.bodySmall),
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

  Future<void> _playOffline(BuildContext context, WidgetRef ref) async {
    final manager = ref.read(downloadManagerProvider.notifier);
    final decryptedPath = await manager.getDecryptedPath(download.mediaId);
    if (decryptedPath != null) {
      final item = PlayableItem(
        id: download.mediaId,
        title: download.title,
        subtitle: download.subtitle,
        artworkUrl: download.artworkUrl,
        type: download.mediaType == 'episode'
            ? MediaType.episode
            : MediaType.song,
        streamUrl: 'file://$decryptedPath',
      );
      ref.read(audioPlayerProvider.notifier).playItem(item);
      if (context.mounted) AppRouter.navigateToPlayer(context);
    }
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
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
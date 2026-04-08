// lib/features/downloads/presentation/downloads_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/services/download_manager.dart';
import '../data/models/download_model.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadManagerProvider);
    final manager = ref.read(downloadManagerProvider.notifier);
    final completed =
        downloads.values.where((d) => d.isCompleted).toList();
    final inProgress =
        downloads.values.where((d) => d.isInProgress).toList();

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
                // Storage info
                FutureBuilder<int>(
                  future: manager.getTotalStorageBytes(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const SizedBox.shrink();
                    return Container(
                      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.storage_rounded,
                              color: AppColors.primary, size: 20),
                          const SizedBox(width: 10),
                          Text(
                            'Storage used: ${manager.formatStorageSize(snapshot.data!)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const Spacer(),
                          Text(
                            '${completed.length} files',
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
                    padding: const EdgeInsets.only(top: 8, bottom: 100),
                    children: [
                      // In-progress downloads
                      if (inProgress.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Text('Downloading',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                        ...inProgress.map(
                            (d) => _DownloadTile(download: d)),
                      ],

                      // Completed
                      if (completed.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Text('Completed',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                        ...completed.map(
                            (d) => _DownloadTile(download: d)),
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
            'This will delete all downloaded files. This action cannot be undone.'),
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

class _DownloadTile extends ConsumerWidget {
  final DownloadModel download;
  const _DownloadTile({required this.download});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: Key(download.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppColors.error.withOpacity(0.15),
        child: const Icon(Icons.delete_rounded, color: AppColors.error),
      ),
      onDismissed: (_) {
        ref
            .read(downloadManagerProvider.notifier)
            .deleteDownload(download.mediaId);
      },
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        leading: Stack(
          children: [
            CoverImage(
              url: download.artworkUrl,
              size: 52,
              borderRadius: 10,
            ),
            if (download.isCompleted)
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
        title: Text(download.title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontSize: 14)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (download.subtitle != null)
              Text(download.subtitle!,
                  style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            if (download.isInProgress) ...[
              LinearProgressIndicator(
                value: download.progress > 0 ? download.progress : null,
                backgroundColor: AppColors.surfaceVariant,
                color: AppColors.primary,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 2),
              Text(
                _statusLabel(download),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: AppColors.primary),
              ),
            ] else if (download.isCompleted) ...[
              Row(
                children: [
                  const EncryptedBadge(),
                  const SizedBox(width: 6),
                  Text(download.formattedSize,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ] else if (download.isFailed) ...[
              Text(
                'Failed: ${download.errorMessage ?? 'Unknown error'}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.error),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        trailing: download.isCompleted
            ? IconButton(
                icon: const Icon(Icons.play_circle_outline_rounded),
                color: AppColors.primary,
                onPressed: () => _playOffline(context, ref),
              )
            : null,
        onTap: download.isCompleted ? () => _playOffline(context, ref) : null,
      ),
    );
  }

  String _statusLabel(DownloadModel d) {
    return switch (d.status) {
      'downloading' =>
        'Downloading part ${d.downloadedParts}/${d.totalParts}...',
      'merging' => 'Merging parts...',
      'encrypting' => 'Encrypting...',
      _ => 'Processing...',
    };
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
      if (context.mounted) {
        AppRouter.navigateToPlayer(context);
      }
    }
  }
}

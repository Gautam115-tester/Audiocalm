// lib/features/calm_music/presentation/music_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/calm_music_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

class MusicScreen extends ConsumerWidget {
  const MusicScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Calm Music')),
      body: albumsAsync.when(
        loading: () => GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.72,
          ),
          itemCount: 6,
          itemBuilder: (_, __) =>
              const ShimmerBox(height: double.infinity, borderRadius: 16),
        ),
        error: (_, __) => AppErrorWidget(
          message: 'Unable to load albums',
          onRetry: () => ref.refresh(albumsListProvider),
        ),
        data: (albums) {
          if (albums.isEmpty) {
            return const EmptyStateWidget(
              icon: Icons.album_rounded,
              title: 'No Albums Yet',
              subtitle: 'Albums will appear here once synced',
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            // PERF FIX: Pre-render 300px of off-screen items for smooth scroll
            cacheExtent: 300,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 0.72,
            ),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final a = albums[i];
              // PERF FIX: RepaintBoundary per card — GPU only repaints touched card
              return RepaintBoundary(
                child: _AlbumCard(
                  title: a.title,
                  artist: a.artist,
                  coverUrl: a.coverUrl,
                  trackCount: a.trackCount,
                  onTap: () => context.push('/music/${a.id}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final String title;
  final String? artist;
  final String? coverUrl;
  final int trackCount;
  final VoidCallback onTap;

  const _AlbumCard({
    required this.title,
    this.artist,
    this.coverUrl,
    required this.trackCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.primary.withOpacity(0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: SizedBox.expand(
                  child: CoverImage(
                    url: coverUrl,
                    size: double.infinity,
                    borderRadius: 0,
                    // PERF FIX: Grid thumbnails decode at 300px max — 
                    // saves ~70% RAM vs decoding full-size Telegram images
                    memCacheWidth: 300,
                    memCacheHeight: 300,
                    placeholder: Container(
                      decoration: const BoxDecoration(
                          gradient: AppColors.cardGradient),
                      child: const Center(
                        child: Icon(Icons.album_rounded,
                            size: 48, color: AppColors.textTertiary),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artist ?? '$trackCount tracks',
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
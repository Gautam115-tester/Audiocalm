// lib/features/calm_music/presentation/music_screen.dart
//
// SMART PREFETCH: Uses a ScrollController to detect which albums are visible,
// then tells AlbumPrefetchController to warm exactly those + the next 5.
// For a library of 1,000,000 albums, only ~10 items are ever prefetched at once.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/calm_music_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

// Grid constants — must match the GridView delegate below
const _kCrossAxisCount = 2;
const _kItemAspectRatio = 0.72;
const _kSpacing = 14.0;
const _kPadding = 16.0;

class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key});

  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final albums = ref.read(albumsListProvider).valueOrNull;
    if (albums == null || albums.isEmpty) return;
    _triggerPrefetch(albums);
  }

  /// Computes which album indices are currently visible in the grid,
  /// then asks the prefetch controller to warm those + the next 5.
  void _triggerPrefetch(List albums) {
    final controller = ref.read(albumPrefetchControllerProvider);
    final screenHeight = MediaQuery.of(context).size.height;
    final scrollOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    // Item height derived from aspect ratio + spacing
    final itemWidth =
        (MediaQuery.of(context).size.width - _kPadding * 2 - _kSpacing) /
            _kCrossAxisCount;
    final itemHeight = itemWidth / _kItemAspectRatio + _kSpacing;

    // Row index range that is visible on screen
    final firstVisibleRow = (scrollOffset / itemHeight).floor();
    final lastVisibleRow =
        ((scrollOffset + screenHeight) / itemHeight).ceil();

    // Convert rows → flat album indices
    final firstIdx = (firstVisibleRow * _kCrossAxisCount).clamp(0, albums.length - 1);
    final lastIdx = ((lastVisibleRow + 1) * _kCrossAxisCount - 1)
        .clamp(0, albums.length - 1);

    final visibleIds = albums
        .sublist(firstIdx, lastIdx + 1)
        .map<String>((a) => a.id as String)
        .toList();

    // Next 5 beyond the visible window
    final aheadEnd = (lastIdx + 1 + 5).clamp(0, albums.length);
    final upcomingIds = lastIdx + 1 < albums.length
        ? albums
            .sublist(lastIdx + 1, aheadEnd)
            .map<String>((a) => a.id as String)
            .toList()
        : <String>[];

    controller.warmRange(
      visibleIds: visibleIds,
      upcomingIds: upcomingIds,
    );
  }

  @override
  Widget build(BuildContext context) {
    final albumsAsync = ref.watch(albumsListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Calm Music')),
      body: albumsAsync.when(
        loading: () => GridView.builder(
          padding: const EdgeInsets.all(_kPadding),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _kCrossAxisCount,
            mainAxisSpacing: _kSpacing,
            crossAxisSpacing: _kSpacing,
            childAspectRatio: _kItemAspectRatio,
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

          // Trigger initial prefetch for whatever is visible on first render
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _triggerPrefetch(albums);
          });

          return GridView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(_kPadding),
            cacheExtent: 300,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _kCrossAxisCount,
              mainAxisSpacing: _kSpacing,
              crossAxisSpacing: _kSpacing,
              childAspectRatio: _kItemAspectRatio,
            ),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final a = albums[i];
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
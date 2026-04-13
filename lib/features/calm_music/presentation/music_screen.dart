// lib/features/calm_music/presentation/music_screen.dart
// VYNCE MUSIC SCREEN — grid + list tabs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/calm_music_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

const _kCrossAxisCount = 2;
const _kItemAspectRatio = 0.72;
const _kSpacing = 12.0;
const _kPadding = 14.0;

class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key});

  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen> {
  final _scrollController = ScrollController();
  bool _gridView = true;

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

  void _triggerPrefetch(List albums) {
    final controller = ref.read(albumPrefetchControllerProvider);
    final screenHeight = MediaQuery.of(context).size.height;
    final scrollOffset = _scrollController.hasClients ? _scrollController.offset : 0.0;
    final itemWidth = (MediaQuery.of(context).size.width - _kPadding * 2 - _kSpacing) / _kCrossAxisCount;
    final itemHeight = itemWidth / _kItemAspectRatio + _kSpacing;
    final firstVisibleRow = (scrollOffset / itemHeight).floor();
    final lastVisibleRow  = ((scrollOffset + screenHeight) / itemHeight).ceil();
    final firstIdx = (firstVisibleRow * _kCrossAxisCount).clamp(0, albums.length - 1);
    final lastIdx  = ((lastVisibleRow + 1) * _kCrossAxisCount - 1).clamp(0, albums.length - 1);
    final visibleIds  = albums.sublist(firstIdx, lastIdx + 1).map<String>((a) => a.id as String).toList();
    final aheadEnd    = (lastIdx + 1 + 5).clamp(0, albums.length);
    final upcomingIds = lastIdx + 1 < albums.length
        ? albums.sublist(lastIdx + 1, aheadEnd).map<String>((a) => a.id as String).toList()
        : <String>[];
    controller.warmRange(visibleIds: visibleIds, upcomingIds: upcomingIds);
  }

  @override
  Widget build(BuildContext context) {
    final albumsAsync = ref.watch(albumsListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
          ).createShader(r),
          child: const Text(
            'Calm Music',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_gridView ? Icons.list_rounded : Icons.grid_view_rounded,
                color: AppColors.textSecondary),
            onPressed: () => setState(() => _gridView = !_gridView),
          ),
        ],
      ),
      body: albumsAsync.when(
        loading: () => _buildShimmer(),
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

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _triggerPrefetch(albums);
          });

          if (_gridView) {
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
                  child: _AlbumGridCard(
                    title: a.title,
                    artist: a.artist,
                    coverUrl: a.coverUrl,
                    trackCount: a.trackCount,
                    onTap: () => context.push('/music/${a.id}'),
                  ),
                );
              },
            );
          }

          // List view
          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final a = albums[i];
              return _AlbumListTile(
                title: a.title,
                artist: a.artist,
                coverUrl: a.coverUrl,
                trackCount: a.trackCount,
                onTap: () => context.push('/music/${a.id}'),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildShimmer() {
    return GridView.builder(
      padding: const EdgeInsets.all(_kPadding),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _kCrossAxisCount,
        mainAxisSpacing: _kSpacing,
        crossAxisSpacing: _kSpacing,
        childAspectRatio: _kItemAspectRatio,
      ),
      itemCount: 6,
      itemBuilder: (_, __) => const ShimmerBox(height: double.infinity, borderRadius: 14),
    );
  }
}

// ─── Album Grid Card ──────────────────────────────────────────────────────────

class _AlbumGridCard extends StatelessWidget {
  final String title;
  final String? artist;
  final String? coverUrl;
  final int trackCount;
  final VoidCallback onTap;

  const _AlbumGridCard({
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
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF6366F1).withOpacity(0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                child: SizedBox.expand(
                  child: CoverImage(
                    url: coverUrl,
                    size: double.infinity,
                    borderRadius: 0,
                    memCacheWidth: 300,
                    memCacheHeight: 300,
                    placeholder: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF1E1040), Color(0xFF0A1A40)],
                        ),
                      ),
                      child: const Center(
                        child: Icon(Icons.album_rounded, size: 44, color: Color(0xFF7C3AED)),
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
                  Text(title,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0)),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    (artist != null && artist!.isNotEmpty) ? artist! : '$trackCount tracks',
                    style: const TextStyle(fontSize: 9, color: Color(0xFF4B5563)),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
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

// ─── Album List Tile ──────────────────────────────────────────────────────────

class _AlbumListTile extends StatelessWidget {
  final String title;
  final String? artist;
  final String? coverUrl;
  final int trackCount;
  final VoidCallback onTap;

  const _AlbumListTile({
    required this.title,
    this.artist,
    this.coverUrl,
    required this.trackCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: onTap,
      leading: CoverImage(url: coverUrl, size: 50, borderRadius: 10),
      title: Text(title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0))),
      subtitle: Text(
        (artist != null && artist!.isNotEmpty) ? artist! : '$trackCount tracks',
        style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
      ),
      trailing: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF7C3AED).withOpacity(0.4)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.chevron_right_rounded, color: Color(0xFF7C3AED), size: 18),
      ),
    );
  }
}
// lib/features/home/presentation/home_screen.dart
//
// FIX: Music section now correctly shows "X tracks" or artist name
// instead of "X episodes". A dedicated _AlbumCard widget replaces the
// reused _SeriesCard in _MusicSection.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../calm_stories/providers/calm_stories_provider.dart';
import '../../calm_music/providers/calm_music_provider.dart';
import '../../favorites/providers/favorites_provider.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(context),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ContinueListeningSection(),
                _FeaturedBanner(),
                _StoriesSection(),
                _MusicSection(),
                const SizedBox(height: 120),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return SliverAppBar(
      floating: true,
      backgroundColor: AppColors.background,
      expandedHeight: 80,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        title: Row(
          children: [
            Image.asset(
              'assets/icons/logo.png',
              width: 36,
              height: 36,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            Text(
              'Audio Calm',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
            ),
          ],
        ),
      ),
      actions: const [],
    );
  }
}

// ─── Continue Listening ──────────────────────────────────────────────────────
class _ContinueListeningSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(continueListeningProvider);
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'Continue Listening'),
        SizedBox(
          height: 88,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _ContinueItem(item: items[i]),
          ),
        ),
      ],
    );
  }
}

class _ContinueItem extends ConsumerWidget {
  final PlayableItem item;
  const _ContinueItem({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () {
        ref.read(audioPlayerProvider.notifier).playItem(item);
        AppRouter.navigateToPlayer(context);
      },
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.primary.withOpacity(0.1),
          ),
        ),
        child: Row(
          children: [
            CoverImage(url: item.artworkUrl, size: 52, borderRadius: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.subtitle != null)
                    Text(
                      item.subtitle!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const Icon(Icons.play_circle_rounded,
                color: AppColors.primary, size: 28),
          ],
        ),
      ),
    );
  }
}

// ─── Featured Banner ─────────────────────────────────────────────────────────
class _FeaturedBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      height: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D3B35), Color(0xFF1A4A7A)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -20,
            top: -20,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withOpacity(0.15),
              ),
            ),
          ),
          Positioned(
            right: 20,
            bottom: -30,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.secondary.withOpacity(0.1),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'FEATURED',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.primary,
                          letterSpacing: 1.5,
                        ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Find Your Inner Peace',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Guided meditations for restful sleep',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Stories Section ─────────────────────────────────────────────────────────
class _StoriesSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync = ref.watch(seriesListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Calm Stories',
          onSeeAll: () => context.go('/stories'),
        ),
        SizedBox(
          height: 180,
          child: seriesAsync.when(
            loading: () => _buildShimmerList(),
            error: (_, __) => const Center(child: Text('Failed to load')),
            data: (series) => series.isEmpty
                ? const Center(child: Text('No stories available'))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: series.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, i) {
                      final s = series[i];
                      return _SeriesCard(
                        title: s.title,
                        coverUrl: s.coverUrl,
                        episodeCount: s.episodeCount,
                        onTap: () => context.push('/stories/${s.id}'),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildShimmerList() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(width: 14),
      itemBuilder: (_, __) =>
          const ShimmerBox(width: 130, height: 180, borderRadius: 16),
    );
  }
}

// ─── Music Section ────────────────────────────────────────────────────────────
class _MusicSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Calm Music',
          onSeeAll: () => context.go('/music'),
        ),
        SizedBox(
          height: 180,
          child: albumsAsync.when(
            loading: () => _buildShimmerList(),
            error: (_, __) => const Center(child: Text('Failed to load')),
            data: (albums) => albums.isEmpty
                ? const Center(child: Text('No albums available'))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: albums.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, i) {
                      final a = albums[i];
                      // FIX: Use _AlbumCard instead of _SeriesCard.
                      // _SeriesCard hardcodes "episodes" — _AlbumCard shows
                      // artist name or "X tracks".
                      return _AlbumCard(
                        title: a.title,
                        artist: a.artist,
                        coverUrl: a.coverUrl,
                        trackCount: a.trackCount,
                        onTap: () => context.push('/music/${a.id}'),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildShimmerList() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(width: 14),
      itemBuilder: (_, __) =>
          const ShimmerBox(width: 130, height: 180, borderRadius: 16),
    );
  }
}

// ─── Series Card (used only for Stories section) ──────────────────────────────
class _SeriesCard extends StatelessWidget {
  final String title;
  final String? coverUrl;
  final int episodeCount;
  final VoidCallback onTap;

  const _SeriesCard({
    required this.title,
    this.coverUrl,
    required this.episodeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CoverImage(
                url: coverUrl,
                size: 110,
                borderRadius: 14,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '$episodeCount episodes',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Album Card (used only for Music section) ─────────────────────────────────
//
// FIX: Shows artist name if available, else "$trackCount tracks".
// Never says "episodes" — previously _MusicSection wrongly reused _SeriesCard.
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
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CoverImage(
                url: coverUrl,
                size: 110,
                borderRadius: 14,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              // Show artist if available, otherwise show track count.
              // "7 tracks" not "7 episodes".
              (artist != null && artist!.isNotEmpty)
                  ? artist!
                  : '$trackCount tracks',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
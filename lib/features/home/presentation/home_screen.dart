// lib/features/home/presentation/home_screen.dart
// VYNCE HOME — Updated section labels: "Calm Stories" → "Audio Story", "Calm Music" → "Music"

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
      expandedHeight: 72,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        title: Row(
          children: [
            Image.asset(
              'assets/icons/logo.png',
              width: 32,
              height: 32,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const _VLogoSmall(),
            ),
            const SizedBox(width: 10),
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
              ).createShader(r),
              child: const Text(
                'VYNCE',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VLogoSmall extends StatelessWidget {
  const _VLogoSmall();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Text(
          'V',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
    );
  }
}

// ─── Continue Listening ───────────────────────────────────────────────────────

class _ContinueListeningSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(continueListeningProvider);
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VynceSectionHeader(title: 'Continue Listening'),
        SizedBox(
          height: 88,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18),
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
          border: Border.all(color: AppColors.primary.withOpacity(0.15)),
        ),
        child: Row(
          children: [
            CoverImage(url: item.artworkUrl, size: 50, borderRadius: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 12),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (item.subtitle != null)
                    Text(item.subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
              ).createShader(r),
              child: const Icon(Icons.play_circle_rounded, color: Colors.white, size: 28),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Featured Banner ──────────────────────────────────────────────────────────

class _FeaturedBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 16, 18, 0),
      height: 150,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A0533), Color(0xFF0C1A4A)],
        ),
        border: Border.all(color: const Color(0xFF7C3AED).withOpacity(0.2)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -20, top: -20,
            child: Container(
              width: 140, height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFA855F7).withOpacity(0.08),
              ),
            ),
          ),
          Positioned(
            right: 30, bottom: -30,
            child: Container(
              width: 90, height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF06B6D4).withOpacity(0.06),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFA855F7).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'FEATURED',
                    style: TextStyle(fontSize: 9, color: Color(0xFFA855F7), letterSpacing: 2, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Stories in Every Beat',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Immersive audio for every mood',
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

// ─── Section header ───────────────────────────────────────────────────────────

class _VynceSectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  const _VynceSectionHeader({required this.title, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 22, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
          ),
          if (onSeeAll != null)
            GestureDetector(
              onTap: onSeeAll,
              child: const Text(
                'See all',
                style: TextStyle(fontSize: 11, color: Color(0xFF7C3AED), fontWeight: FontWeight.w500),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Audio Story Section ──────────────────────────────────────────────────────

class _StoriesSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync = ref.watch(seriesListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VynceSectionHeader(
          title: 'Audio Story',           // RENAMED
          onSeeAll: () => context.go('/stories'),
        ),
        SizedBox(
          height: 176,
          child: seriesAsync.when(
            loading: () => _buildShimmer(),
            error: (_, __) => const Center(child: Text('Failed to load')),
            data: (series) => series.isEmpty
                ? const Center(child: Text('No stories available'))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    itemCount: series.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                      final s = series[i];
                      return _VynceCard(
                        title: s.title,
                        subtitle: '${s.episodeCount} episodes',
                        coverUrl: s.coverUrl,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xFF1E1040), Color(0xFF0A1A40)],
                        ),
                        onTap: () => context.push('/stories/${s.id}'),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildShimmer() => ListView.separated(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    itemCount: 4,
    separatorBuilder: (_, __) => const SizedBox(width: 12),
    itemBuilder: (_, __) => const ShimmerBox(width: 120, height: 176, borderRadius: 14),
  );
}

// ─── Music Section ────────────────────────────────────────────────────────────

class _MusicSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VynceSectionHeader(
          title: 'Music',                  // RENAMED
          onSeeAll: () => context.go('/music'),
        ),
        SizedBox(
          height: 176,
          child: albumsAsync.when(
            loading: () => _buildShimmer(),
            error: (_, __) => const Center(child: Text('Failed to load')),
            data: (albums) => albums.isEmpty
                ? const Center(child: Text('No albums available'))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    itemCount: albums.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                      final a = albums[i];
                      return _VynceCard(
                        title: a.title,
                        subtitle: (a.artist != null && a.artist!.isNotEmpty)
                            ? a.artist!
                            : '${a.trackCount} tracks',
                        coverUrl: a.coverUrl,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xFF041A2A), Color(0xFF071C2E)],
                        ),
                        onTap: () => context.push('/music/${a.id}'),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildShimmer() => ListView.separated(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    itemCount: 4,
    separatorBuilder: (_, __) => const SizedBox(width: 12),
    itemBuilder: (_, __) => const ShimmerBox(width: 120, height: 176, borderRadius: 14),
  );
}

// ─── Vynce Card ───────────────────────────────────────────────────────────────

class _VynceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? coverUrl;
  final LinearGradient gradient;
  final VoidCallback onTap;

  const _VynceCard({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
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
                child: coverUrl != null && coverUrl!.isNotEmpty
                    ? CoverImage(url: coverUrl, size: double.infinity, borderRadius: 0, memCacheWidth: 240)
                    : Container(
                        decoration: BoxDecoration(gradient: gradient),
                        child: const Center(
                          child: Icon(Icons.music_note_rounded, size: 36, color: Color(0xFF7C3AED)),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0)),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 9, color: Color(0xFF4B5563)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
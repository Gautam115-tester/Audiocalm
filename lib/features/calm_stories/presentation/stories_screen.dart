// lib/features/calm_stories/presentation/stories_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/calm_stories_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

class StoriesScreen extends ConsumerWidget {
  const StoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync = ref.watch(seriesListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Calm Stories'),
      ),
      body: seriesAsync.when(
        loading: () => _buildShimmer(),
        error: (e, _) => AppErrorWidget(
          message: 'Unable to load stories',
          onRetry: () => ref.refresh(seriesListProvider),
        ),
        data: (series) {
          if (series.isEmpty) {
            return const EmptyStateWidget(
              icon: Icons.auto_stories_rounded,
              title: 'No Stories Yet',
              subtitle: 'Stories will appear here once synced',
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 0.72,
            ),
            itemCount: series.length,
            itemBuilder: (context, i) {
              final s = series[i];
              return _SeriesGridCard(
                title: s.title,
                description: s.description,
                coverUrl: s.coverUrl,
                episodeCount: s.episodeCount,
                onTap: () => context.push('/stories/${s.id}'),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildShimmer() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.72,
      ),
      itemCount: 6,
      itemBuilder: (_, __) => const ShimmerBox(height: double.infinity, borderRadius: 16),
    );
  }
}

class _SeriesGridCard extends StatelessWidget {
  final String title;
  final String? description;
  final String? coverUrl;
  final int episodeCount;
  final VoidCallback onTap;

  const _SeriesGridCard({
    required this.title,
    this.description,
    this.coverUrl,
    required this.episodeCount,
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
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: AspectRatio(
                aspectRatio: 1,
                child: CoverImage(
                  url: coverUrl,
                  size: double.infinity,
                  borderRadius: 0,
                  placeholder: Container(
                    decoration: const BoxDecoration(
                      gradient: AppColors.cardGradient,
                    ),
                    child: const Center(
                      child: Icon(Icons.auto_stories_rounded,
                          size: 40, color: AppColors.textTertiary),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  const SizedBox(height: 4),
                  Text(
                    '$episodeCount episodes',
                    style: Theme.of(context).textTheme.bodySmall,
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

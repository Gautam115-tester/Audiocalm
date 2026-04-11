// lib/features/calm_stories/presentation/stories_screen.dart
//
// FIX: Forces a fresh fetch of allSeriesRawProvider every time this screen
// mounts by calling ref.invalidate(allSeriesRawProvider) in initState.
//
// WHY THIS IS NEEDED:
// Even with keepAlive removed from all derived providers, there is a window
// where allSeriesRawProvider could still be alive (e.g. if SeriesDetailScreen
// is still in the navigator stack). ref.invalidate() is the guaranteed nuclear
// option — it forces a fresh network request regardless of the provider's
// current lifecycle state, ensuring the episode count is always up to date.
//
// The invalidation happens BEFORE the first build, so the loading shimmer
// is shown briefly while fresh data arrives — correct UX behaviour.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/calm_stories_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

const _kCrossAxisCount = 2;
const _kItemAspectRatio = 0.72;
const _kSpacing = 14.0;
const _kPadding = 16.0;

class StoriesScreen extends ConsumerStatefulWidget {
  const StoriesScreen({super.key});

  @override
  ConsumerState<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends ConsumerState<StoriesScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    // CORE FIX: Invalidate allSeriesRawProvider every time StoriesScreen
    // mounts. This forces a fresh network fetch, guaranteeing the episode
    // count is always current regardless of any Riverpod keepAlive state.
    //
    // Using addPostFrameCallback so the widget tree is fully built before
    // the invalidation triggers a rebuild — avoids setState-during-build errors.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.invalidate(allSeriesRawProvider);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final series = ref.read(seriesListProvider).valueOrNull;
    if (series == null || series.isEmpty) return;
    _triggerPrefetch(series);
  }

  void _triggerPrefetch(List series) {
    final controller = ref.read(seriesPrefetchControllerProvider);
    final screenHeight = MediaQuery.of(context).size.height;
    final scrollOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    final itemWidth =
        (MediaQuery.of(context).size.width - _kPadding * 2 - _kSpacing) /
            _kCrossAxisCount;
    final itemHeight = itemWidth / _kItemAspectRatio + _kSpacing;

    final firstVisibleRow = (scrollOffset / itemHeight).floor();
    final lastVisibleRow =
        ((scrollOffset + screenHeight) / itemHeight).ceil();

    final firstIdx =
        (firstVisibleRow * _kCrossAxisCount).clamp(0, series.length - 1);
    final lastIdx = ((lastVisibleRow + 1) * _kCrossAxisCount - 1)
        .clamp(0, series.length - 1);

    final visibleIds = series
        .sublist(firstIdx, lastIdx + 1)
        .map<String>((s) => s.id as String)
        .toList();

    final aheadEnd = (lastIdx + 1 + 5).clamp(0, series.length);
    final upcomingIds = lastIdx + 1 < series.length
        ? series
            .sublist(lastIdx + 1, aheadEnd)
            .map<String>((s) => s.id as String)
            .toList()
        : <String>[];

    controller.warmRange(
      visibleIds: visibleIds,
      upcomingIds: upcomingIds,
    );
  }

  @override
  Widget build(BuildContext context) {
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
          onRetry: () => ref.invalidate(allSeriesRawProvider),
        ),
        data: (series) {
          if (series.isEmpty) {
            return const EmptyStateWidget(
              icon: Icons.auto_stories_rounded,
              title: 'No Stories Yet',
              subtitle: 'Stories will appear here once synced',
            );
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _triggerPrefetch(series);
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
                  const SizedBox(height: 4),
                  Text(
                    '$episodeCount episodes',
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
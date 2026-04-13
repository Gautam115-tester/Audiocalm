// lib/features/calm_stories/presentation/stories_screen.dart
//
// RENAMED: "Calm Stories" → "Audio Story"
// ADDED: Logo on left side of app bar
// ADDED: Menu option (three-dot) in app bar
// FIX: Forces fresh fetch on mount

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
  bool _gridView = true; // default grid

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

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

  void _showSortMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.grid_view_rounded, color: AppColors.primary),
                title: const Text('Grid View'),
                trailing: _gridView ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
                onTap: () {
                  setState(() => _gridView = true);
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.list_rounded, color: AppColors.primary),
                title: const Text('List View'),
                trailing: !_gridView ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
                onTap: () {
                  setState(() => _gridView = false);
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh_rounded, color: AppColors.primary),
                title: const Text('Refresh'),
                onTap: () {
                  ref.invalidate(allSeriesRawProvider);
                  Navigator.pop(ctx);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seriesAsync = ref.watch(seriesListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 16),
            // Logo / V icon on left
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
              ).createShader(r),
              child: const Icon(Icons.headphones_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
              ).createShader(r),
              child: const Text(
                'Audio Story',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        actions: [
          // View toggle icon
          IconButton(
            icon: Icon(
              _gridView ? Icons.list_rounded : Icons.grid_view_rounded,
              color: AppColors.textSecondary,
            ),
            onPressed: () => setState(() => _gridView = !_gridView),
          ),
          // Menu (three dots)
          IconButton(
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
            onPressed: () => _showSortMenu(context),
          ),
        ],
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
          }

          // List view
          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: series.length,
            itemBuilder: (context, i) {
              final s = series[i];
              return _SeriesListTile(
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

// ─── Grid Card ────────────────────────────────────────────────────────────────

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

// ─── List Tile ────────────────────────────────────────────────────────────────

class _SeriesListTile extends StatelessWidget {
  final String title;
  final String? description;
  final String? coverUrl;
  final int episodeCount;
  final VoidCallback onTap;

  const _SeriesListTile({
    required this.title,
    this.description,
    this.coverUrl,
    required this.episodeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: onTap,
      leading: CoverImage(url: coverUrl, size: 52, borderRadius: 10),
      title: Text(title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0))),
      subtitle: Text(
        '$episodeCount episodes',
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
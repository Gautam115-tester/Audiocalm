// lib/features/search/presentation/search_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/search_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      ref.read(searchProvider.notifier).search(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: 'Search stories, music...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () {
                        _controller.clear();
                        ref.read(searchProvider.notifier).clear();
                      },
                    )
                  : null,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ),
      ),
      body: _buildBody(searchState),
    );
  }

  Widget _buildBody(SearchState state) {
    if (state.query.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.search_rounded,
        title: 'Search',
        subtitle: 'Find stories, albums, episodes, and songs',
      );
    }

    if (state.query.length < 2) {
      return Center(
        child: Text(
          'Type at least 2 characters',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null) {
      return AppErrorWidget(
        message: state.error!,
        onRetry: () =>
            ref.read(searchProvider.notifier).search(state.query),
      );
    }

    if (state.results.isEmpty) {
      return EmptyStateWidget(
        icon: Icons.search_off_rounded,
        title: 'No Results',
        subtitle: 'No results for "${state.query}"',
      );
    }

    // Group by type
    final Map<String, List<SearchResult>> grouped = {};
    for (final r in state.results) {
      grouped.putIfAbsent(r.type, () => []).add(r);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 100),
      children: [
        for (final entry in grouped.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              _typeLabel(entry.key),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: AppColors.primary),
            ),
          ),
          ...entry.value.map((r) => _SearchResultTile(result: r)),
        ],
      ],
    );
  }

  String _typeLabel(String type) => switch (type) {
        'series' => 'Series',
        'album' => 'Albums',
        'episode' => 'Episodes',
        'song' => 'Songs',
        _ => type,
      };
}

class _SearchResultTile extends StatelessWidget {
  final SearchResult result;
  const _SearchResultTile({required this.result});

  IconData get _icon => switch (result.type) {
        'series' => Icons.auto_stories_rounded,
        'album' => Icons.album_rounded,
        'episode' => Icons.headphones_rounded,
        'song' => Icons.music_note_rounded,
        _ => Icons.play_circle_rounded,
      };

  void _navigate(BuildContext context) {
    switch (result.type) {
      case 'series':
        context.push('/stories/${result.id}');
        break;
      case 'album':
        context.push('/music/${result.id}');
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: result.imageUrl != null
          ? CoverImage(url: result.imageUrl, size: 44, borderRadius: 10)
          : Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_icon, color: AppColors.primary, size: 22),
            ),
      title: Text(result.title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontSize: 14)),
      subtitle: result.subtitle != null
          ? Text(result.subtitle!,
              style: Theme.of(context).textTheme.bodySmall)
          : null,
      trailing:
          const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
      onTap: () => _navigate(context),
    );
  }
}

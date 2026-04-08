// lib/features/favorites/presentation/favorites_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/favorites_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider);
    final notifier = ref.read(favoritesProvider.notifier);
    final favoriteData = notifier.getAllFavoriteData();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Favorites')),
      body: favorites.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.favorite_rounded,
              title: 'No Favorites',
              subtitle: 'Tap ♡ on any song or episode to save it here',
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: favoriteData.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 80),
              itemBuilder: (context, i) {
                final item = favoriteData[i];
                final id = item['id'] as String? ?? '';
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  leading: CoverImage(
                    url: item['artworkUrl'] as String?,
                    size: 52,
                    borderRadius: 10,
                  ),
                  title: Text(
                    item['title'] as String? ?? '',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontSize: 14),
                  ),
                  subtitle: item['subtitle'] != null
                      ? Text(item['subtitle'] as String,
                          style: Theme.of(context).textTheme.bodySmall)
                      : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.favorite_rounded,
                        color: AppColors.error, size: 20),
                    onPressed: () =>
                        ref.read(favoritesProvider.notifier).toggle(id),
                  ),
                );
              },
            ),
    );
  }
}

// lib/features/favorites/providers/favorites_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../core/constants/app_constants.dart';
import '../../player/domain/media_item_model.dart';

class FavoritesNotifier extends StateNotifier<Set<String>> {
  FavoritesNotifier() : super({}) {
    _load();
  }

  void _load() {
    try {
      final box = Hive.box(AppConstants.favoritesBox);
      state = Set<String>.from(box.keys.cast<String>());
    } catch (_) {}
  }

  bool isFavorite(String id) => state.contains(id);

  Future<void> toggle(String id) async {
    try {
      final box = Hive.box(AppConstants.favoritesBox);
      if (state.contains(id)) {
        await box.delete(id);
        state = Set<String>.from(state)..remove(id);
      } else {
        await box.put(id, true);
        state = Set<String>.from(state)..add(id);
      }
    } catch (_) {}
  }

  Future<void> saveItemData(String id, Map<String, dynamic> data) async {
    try {
      final box = Hive.box(AppConstants.favoritesBox);
      await box.put(id, data);
    } catch (_) {}
  }

  List<Map<String, dynamic>> getAllFavoriteData() {
    try {
      final box = Hive.box(AppConstants.favoritesBox);
      final result = <Map<String, dynamic>>[];
      for (final key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          result.add(Map<String, dynamic>.from(val));
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, Set<String>>((ref) {
  return FavoritesNotifier();
});

// Continue Listening provider
final continueListeningProvider = Provider<List<PlayableItem>>((ref) {
  try {
    final box = Hive.box(AppConstants.continueListeningBox);
    final items = <PlayableItem>[];
    final keys = box.keys.toList().reversed.toList();
    for (final key in keys.take(AppConstants.continueListeningMaxItems)) {
      final val = box.get(key);
      if (val is Map) {
        try {
          items.add(PlayableItem.fromJson(Map<String, dynamic>.from(val)));
        } catch (_) {}
      }
    }
    return items;
  } catch (_) {
    return [];
  }
});

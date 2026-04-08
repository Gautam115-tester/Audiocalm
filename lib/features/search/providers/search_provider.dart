// lib/features/search/providers/search_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

class SearchResult {
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final String type; // 'series' | 'album' | 'episode' | 'song'

  const SearchResult({
    required this.id,
    required this.title,
    this.subtitle,
    this.imageUrl,
    required this.type,
  });
}

class SearchState {
  final String query;
  final List<SearchResult> results;
  final bool isLoading;
  final String? error;

  const SearchState({
    this.query = '',
    this.results = const [],
    this.isLoading = false,
    this.error,
  });

  SearchState copyWith({
    String? query,
    List<SearchResult>? results,
    bool? isLoading,
    String? error,
  }) =>
      SearchState(
        query: query ?? this.query,
        results: results ?? this.results,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class SearchNotifier extends StateNotifier<SearchState> {
  final Ref _ref;

  SearchNotifier(this._ref) : super(const SearchState());

  Future<void> search(String query) async {
    if (query.length < 2) {
      state = state.copyWith(query: query, results: [], isLoading: false);
      return;
    }

    state = state.copyWith(query: query, isLoading: true, error: null);

    try {
      final dio = _ref.read(dioClientProvider);
      final data = await dio.get<Map<String, dynamic>>(
        ApiConstants.search,
        queryParameters: {'q': query},
      );

      final results = <SearchResult>[];

      // Parse series
      final series = data['series'] as List? ?? [];
      for (final s in series) {
        results.add(SearchResult(
          id: s['id'].toString(),
          title: s['title'].toString(),
          subtitle: 'Series',
          imageUrl: s['coverUrl']?.toString(),
          type: 'series',
        ));
      }

      // Parse albums
      final albums = data['albums'] as List? ?? [];
      for (final a in albums) {
        results.add(SearchResult(
          id: a['id'].toString(),
          title: a['title'].toString(),
          subtitle: a['artist']?.toString() ?? 'Album',
          imageUrl: a['coverUrl']?.toString(),
          type: 'album',
        ));
      }

      // Parse episodes
      final episodes = data['episodes'] as List? ?? [];
      for (final e in episodes) {
        results.add(SearchResult(
          id: e['id'].toString(),
          title: e['title'].toString(),
          subtitle: 'Episode',
          type: 'episode',
        ));
      }

      // Parse songs
      final songs = data['songs'] as List? ?? [];
      for (final s in songs) {
        results.add(SearchResult(
          id: s['id'].toString(),
          title: s['title'].toString(),
          subtitle: 'Song',
          type: 'song',
        ));
      }

      state = state.copyWith(results: results, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Search failed. Please try again.',
        results: [],
      );
    }
  }

  void clear() {
    state = const SearchState();
  }
}

final searchProvider =
    StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  return SearchNotifier(ref);
});

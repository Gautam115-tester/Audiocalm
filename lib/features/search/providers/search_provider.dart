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

      // Backend returns { series: [], albums: [], episodes: [], songs: [] }
      final raw = await dio.get<Map<String, dynamic>>(
        ApiConstants.search,
        queryParameters: {'q': query},
      );

      final results = <SearchResult>[];

      for (final s in (raw['series'] as List? ?? [])) {
        results.add(SearchResult(
          id:       s['id'].toString(),
          title:    s['title'].toString(),
          subtitle: '${s['episodeCount'] ?? 0} episodes',
          imageUrl: s['coverUrl']?.toString(),
          type:     'series',
        ));
      }

      for (final a in (raw['albums'] as List? ?? [])) {
        results.add(SearchResult(
          id:       a['id'].toString(),
          title:    a['title'].toString(),
          subtitle: a['artist']?.toString(),
          imageUrl: a['coverUrl']?.toString(),
          type:     'album',
        ));
      }

      for (final e in (raw['episodes'] as List? ?? [])) {
        results.add(SearchResult(
          id:       e['id'].toString(),
          title:    e['title'].toString(),
          subtitle: null,
          imageUrl: null,
          type:     'episode',
        ));
      }

      for (final s in (raw['songs'] as List? ?? [])) {
        results.add(SearchResult(
          id:       s['id'].toString(),
          title:    s['title'].toString(),
          subtitle: null,
          imageUrl: null,
          type:     'song',
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
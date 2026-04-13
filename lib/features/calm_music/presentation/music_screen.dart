// lib/features/calm_music/presentation/music_screen.dart
// VYNCE MUSIC SCREEN
// RENAMED: "Calm Music" → "Music"
// ADDED: Logo on left, All Music tab, Artist Songs section

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/calm_music_provider.dart';
import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../player/providers/audio_player_provider.dart';
import '../../player/domain/media_item_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/router/app_router.dart';

const _kCrossAxisCount = 2;
const _kItemAspectRatio = 0.72;
const _kSpacing = 12.0;
const _kPadding = 14.0;

// ─── Tab enum ─────────────────────────────────────────────────────────────────
enum _MusicTab { albums, allMusic, artists }

class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key});

  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen> {
  final _scrollController = ScrollController();
  bool _gridView = true;
  _MusicTab _activeTab = _MusicTab.albums;
  String? _selectedArtist;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final albums = ref.read(albumsListProvider).valueOrNull;
    if (albums == null || albums.isEmpty) return;
    _triggerPrefetch(albums);
  }

  void _triggerPrefetch(List albums) {
    final controller = ref.read(albumPrefetchControllerProvider);
    final screenHeight = MediaQuery.of(context).size.height;
    final scrollOffset = _scrollController.hasClients ? _scrollController.offset : 0.0;
    final itemWidth = (MediaQuery.of(context).size.width - _kPadding * 2 - _kSpacing) / _kCrossAxisCount;
    final itemHeight = itemWidth / _kItemAspectRatio + _kSpacing;
    final firstVisibleRow = (scrollOffset / itemHeight).floor();
    final lastVisibleRow  = ((scrollOffset + screenHeight) / itemHeight).ceil();
    final firstIdx = (firstVisibleRow * _kCrossAxisCount).clamp(0, albums.length - 1);
    final lastIdx  = ((lastVisibleRow + 1) * _kCrossAxisCount - 1).clamp(0, albums.length - 1);
    final visibleIds  = albums.sublist(firstIdx, lastIdx + 1).map<String>((a) => a.id as String).toList();
    final aheadEnd    = (lastIdx + 1 + 5).clamp(0, albums.length);
    final upcomingIds = lastIdx + 1 < albums.length
        ? albums.sublist(lastIdx + 1, aheadEnd).map<String>((a) => a.id as String).toList()
        : <String>[];
    controller.warmRange(visibleIds: visibleIds, upcomingIds: upcomingIds);
  }

  @override
  Widget build(BuildContext context) {
    final albumsAsync = ref.watch(albumsListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 16),
            // Music logo on left
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
              ).createShader(r),
              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
              ).createShader(r),
              child: const Text(
                'Music',
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
          if (_activeTab == _MusicTab.albums)
            IconButton(
              icon: Icon(_gridView ? Icons.list_rounded : Icons.grid_view_rounded,
                  color: AppColors.textSecondary),
              onPressed: () => setState(() => _gridView = !_gridView),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _TabBar(
            activeTab: _activeTab,
            onTabChanged: (tab) => setState(() {
              _activeTab = tab;
              _selectedArtist = null;
            }),
          ),
        ),
      ),
      body: albumsAsync.when(
        loading: () => _buildShimmer(),
        error: (_, __) => AppErrorWidget(
          message: 'Unable to load music',
          onRetry: () => ref.refresh(albumsListProvider),
        ),
        data: (albums) {
          if (albums.isEmpty) {
            return const EmptyStateWidget(
              icon: Icons.album_rounded,
              title: 'No Albums Yet',
              subtitle: 'Albums will appear here once synced',
            );
          }

          switch (_activeTab) {
            case _MusicTab.albums:
              return _AlbumsTab(
                albums: albums,
                gridView: _gridView,
                scrollController: _scrollController,
                onPrefetch: _triggerPrefetch,
              );
            case _MusicTab.allMusic:
              return _AllMusicTab(albums: albums);
            case _MusicTab.artists:
              if (_selectedArtist != null) {
                return _ArtistSongsTab(
                  albums: albums,
                  artist: _selectedArtist!,
                  onBack: () => setState(() => _selectedArtist = null),
                );
              }
              return _ArtistsTab(
                albums: albums,
                onArtistTap: (artist) => setState(() => _selectedArtist = artist),
              );
          }
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
      itemBuilder: (_, __) => const ShimmerBox(height: double.infinity, borderRadius: 14),
    );
  }
}

// ─── Tab Bar ──────────────────────────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  final _MusicTab activeTab;
  final void Function(_MusicTab) onTabChanged;

  const _TabBar({required this.activeTab, required this.onTabChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _TabBtn(label: 'Albums',    tab: _MusicTab.albums,   active: activeTab == _MusicTab.albums,   onTap: onTabChanged),
          _TabBtn(label: 'All Music', tab: _MusicTab.allMusic, active: activeTab == _MusicTab.allMusic, onTap: onTabChanged),
          _TabBtn(label: 'Artists',   tab: _MusicTab.artists,  active: activeTab == _MusicTab.artists,  onTap: onTabChanged),
        ],
      ),
    );
  }
}

class _TabBtn extends StatelessWidget {
  final String label;
  final _MusicTab tab;
  final bool active;
  final void Function(_MusicTab) onTap;

  const _TabBtn({required this.label, required this.tab, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(tab),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: active ? const LinearGradient(
              colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
            ) : null,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: active ? Colors.white : AppColors.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Albums Tab (original grid/list) ─────────────────────────────────────────

class _AlbumsTab extends ConsumerWidget {
  final List<AlbumModel> albums;
  final bool gridView;
  final ScrollController scrollController;
  final void Function(List) onPrefetch;

  const _AlbumsTab({
    required this.albums,
    required this.gridView,
    required this.scrollController,
    required this.onPrefetch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onPrefetch(albums);
    });

    if (gridView) {
      return GridView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(_kPadding),
        cacheExtent: 300,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _kCrossAxisCount,
          mainAxisSpacing: _kSpacing,
          crossAxisSpacing: _kSpacing,
          childAspectRatio: _kItemAspectRatio,
        ),
        itemCount: albums.length,
        itemBuilder: (context, i) {
          final a = albums[i];
          return RepaintBoundary(
            child: _AlbumGridCard(
              title: a.title,
              artist: a.artist,
              coverUrl: a.coverUrl,
              trackCount: a.trackCount,
              onTap: () => context.push('/music/${a.id}'),
            ),
          );
        },
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final a = albums[i];
        return _AlbumListTile(
          title: a.title,
          artist: a.artist,
          coverUrl: a.coverUrl,
          trackCount: a.trackCount,
          onTap: () => context.push('/music/${a.id}'),
        );
      },
    );
  }
}

// ─── All Music Tab ────────────────────────────────────────────────────────────

class _AllMusicTab extends ConsumerWidget {
  final List<AlbumModel> albums;

  const _AllMusicTab({required this.albums});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Collect all songs across all albums from the batch provider
    final batchAsync = ref.watch(_allAlbumsRawProvider);

    return batchAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
      error: (_, __) => const AppErrorWidget(message: 'Unable to load songs'),
      data: (batch) {
        // Flatten all songs
        final allSongs = <SongModel>[];
        final songAlbumMap = <String, AlbumModel>{};

        for (final album in albums) {
          final songs = batch.songsByAlbumId[album.id] ?? [];
          for (final song in songs) {
            allSongs.add(song);
            songAlbumMap[song.id] = album;
          }
        }

        if (allSongs.isEmpty) {
          return const EmptyStateWidget(
            icon: Icons.music_note_rounded,
            title: 'No Songs Yet',
            subtitle: 'Songs will appear here once synced',
          );
        }

        return Column(
          children: [
            // Play all header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Text(
                    '${allSongs.length} songs',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      final queue = allSongs.asMap().entries.map((e) {
                        final song = e.value;
                        final album = songAlbumMap[song.id];
                        return PlayableItem(
                          id: song.id,
                          title: song.title,
                          subtitle: album?.title,
                          artworkUrl: song.coverUrl ?? album?.coverUrl,
                          duration: song.duration,
                          partCount: song.isMultiPart ? 2 : 1,
                          type: MediaType.song,
                          streamUrl: '${ApiConstants.baseUrl}${ApiConstants.songStream(song.id)}',
                        );
                      }).toList();
                      ref.read(audioPlayerProvider.notifier).playItem(queue[0], queue: queue, index: 0);
                      AppRouter.navigateToPlayer(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                          SizedBox(width: 4),
                          Text('Play All', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 100),
                itemCount: allSongs.length,
                itemBuilder: (context, i) {
                  final song = allSongs[i];
                  final album = songAlbumMap[song.id];

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: CoverImage(url: song.coverUrl ?? album?.coverUrl, size: 48, borderRadius: 10),
                    title: Text(song.title,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0)),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      song.artist ?? album?.title ?? '',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      song.formattedDuration,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
                    ),
                    onTap: () {
                      final queue = allSongs.asMap().entries.map((e) {
                        final s = e.value;
                        final a = songAlbumMap[s.id];
                        return PlayableItem(
                          id: s.id,
                          title: s.title,
                          subtitle: a?.title,
                          artworkUrl: s.coverUrl ?? a?.coverUrl,
                          duration: s.duration,
                          partCount: s.isMultiPart ? 2 : 1,
                          type: MediaType.song,
                          streamUrl: '${ApiConstants.baseUrl}${ApiConstants.songStream(s.id)}',
                        );
                      }).toList();
                      ref.read(audioPlayerProvider.notifier).playItem(queue[i], queue: queue, index: i);
                      AppRouter.navigateToPlayer(context);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Artists Tab ──────────────────────────────────────────────────────────────

class _ArtistsTab extends ConsumerWidget {
  final List<AlbumModel> albums;
  final void Function(String) onArtistTap;

  const _ArtistsTab({required this.albums, required this.onArtistTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Extract unique artists
    final artistMap = <String, List<AlbumModel>>{};
    for (final album in albums) {
      final artist = album.artist ?? 'Unknown Artist';
      artistMap.putIfAbsent(artist, () => []).add(album);
    }

    final artists = artistMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    if (artists.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.person_rounded,
        title: 'No Artists',
        subtitle: 'Artists will appear once albums are synced',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: artists.length,
      itemBuilder: (context, i) {
        final entry = artists[i];
        final coverUrl = entry.value.isNotEmpty ? entry.value.first.coverUrl : null;
        final albumCount = entry.value.length;
        final trackCount = entry.value.fold(0, (sum, a) => sum + a.trackCount);

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          onTap: () => onArtistTap(entry.key),
          leading: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceVariant,
            ),
            child: ClipOval(
              child: CoverImage(url: coverUrl, size: 52, borderRadius: 26),
            ),
          ),
          title: Text(entry.key,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0))),
          subtitle: Text(
            '$albumCount album${albumCount == 1 ? '' : 's'} · $trackCount tracks',
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
      },
    );
  }
}

// ─── Artist Songs Tab ─────────────────────────────────────────────────────────

class _ArtistSongsTab extends ConsumerWidget {
  final List<AlbumModel> albums;
  final String artist;
  final VoidCallback onBack;

  const _ArtistSongsTab({required this.albums, required this.artist, required this.onBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistAlbums = albums.where((a) => (a.artist ?? 'Unknown Artist') == artist).toList();
    final batchAsync = ref.watch(_allAlbumsRawProvider);

    return batchAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
      error: (_, __) => const AppErrorWidget(message: 'Unable to load songs'),
      data: (batch) {
        final artistSongs = <SongModel>[];
        final songAlbumMap = <String, AlbumModel>{};

        for (final album in artistAlbums) {
          final songs = batch.songsByAlbumId[album.id] ?? [];
          for (final song in songs) {
            artistSongs.add(song);
            songAlbumMap[song.id] = album;
          }
        }

        return Column(
          children: [
            // Artist header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              color: AppColors.surface,
              child: Row(
                children: [
                  GestureDetector(
                    onTap: onBack,
                    child: const Icon(Icons.arrow_back_rounded, color: AppColors.textSecondary, size: 22),
                  ),
                  const SizedBox(width: 12),
                  // Artist avatar (first album cover)
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(shape: BoxShape.circle),
                    child: ClipOval(
                      child: CoverImage(
                        url: artistAlbums.isNotEmpty ? artistAlbums.first.coverUrl : null,
                        size: 44,
                        borderRadius: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(artist,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFFD0D0F0))),
                        Text('${artistSongs.length} songs',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563))),
                      ],
                    ),
                  ),
                  // Play all artist songs
                  GestureDetector(
                    onTap: () {
                      if (artistSongs.isEmpty) return;
                      final queue = artistSongs.map((s) {
                        final a = songAlbumMap[s.id];
                        return PlayableItem(
                          id: s.id,
                          title: s.title,
                          subtitle: a?.title,
                          artworkUrl: s.coverUrl ?? a?.coverUrl,
                          duration: s.duration,
                          partCount: s.isMultiPart ? 2 : 1,
                          type: MediaType.song,
                          streamUrl: '${ApiConstants.baseUrl}${ApiConstants.songStream(s.id)}',
                        );
                      }).toList();
                      ref.read(audioPlayerProvider.notifier).playItem(queue[0], queue: queue, index: 0);
                      AppRouter.navigateToPlayer(context);
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
                        ),
                      ),
                      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ),

            // Albums from this artist
            if (artistAlbums.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Albums', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary)),
                ),
              ),
              SizedBox(
                height: 110,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: artistAlbums.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    final a = artistAlbums[i];
                    return GestureDetector(
                      onTap: () => context.push('/music/${a.id}'),
                      child: Column(
                        children: [
                          CoverImage(url: a.coverUrl, size: 72, borderRadius: 10),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: 72,
                            child: Text(a.title,
                              style: const TextStyle(fontSize: 10, color: Color(0xFFD0D0F0)),
                              maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],

            // All songs by artist
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Songs', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary)),
              ),
            ),

            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 100),
                itemCount: artistSongs.length,
                itemBuilder: (context, i) {
                  final song = artistSongs[i];
                  final album = songAlbumMap[song.id];

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    leading: CoverImage(url: song.coverUrl ?? album?.coverUrl, size: 44, borderRadius: 8),
                    title: Text(song.title,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0)),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      album?.title ?? '',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      song.formattedDuration,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
                    ),
                    onTap: () {
                      final queue = artistSongs.map((s) {
                        final a = songAlbumMap[s.id];
                        return PlayableItem(
                          id: s.id,
                          title: s.title,
                          subtitle: a?.title,
                          artworkUrl: s.coverUrl ?? a?.coverUrl,
                          duration: s.duration,
                          partCount: s.isMultiPart ? 2 : 1,
                          type: MediaType.song,
                          streamUrl: '${ApiConstants.baseUrl}${ApiConstants.songStream(s.id)}',
                        );
                      }).toList();
                      ref.read(audioPlayerProvider.notifier).playItem(queue[i], queue: queue, index: i);
                      AppRouter.navigateToPlayer(context);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Album Grid Card ──────────────────────────────────────────────────────────

class _AlbumGridCard extends StatelessWidget {
  final String title;
  final String? artist;
  final String? coverUrl;
  final int trackCount;
  final VoidCallback onTap;

  const _AlbumGridCard({
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
      child: Container(
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
                child: SizedBox.expand(
                  child: CoverImage(
                    url: coverUrl,
                    size: double.infinity,
                    borderRadius: 0,
                    memCacheWidth: 300,
                    memCacheHeight: 300,
                    placeholder: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF1E1040), Color(0xFF0A1A40)],
                        ),
                      ),
                      child: const Center(
                        child: Icon(Icons.album_rounded, size: 44, color: Color(0xFF7C3AED)),
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
                  Text(title,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0)),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    (artist != null && artist!.isNotEmpty) ? artist! : '$trackCount tracks',
                    style: const TextStyle(fontSize: 9, color: Color(0xFF4B5563)),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
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

// ─── Album List Tile ──────────────────────────────────────────────────────────

class _AlbumListTile extends StatelessWidget {
  final String title;
  final String? artist;
  final String? coverUrl;
  final int trackCount;
  final VoidCallback onTap;

  const _AlbumListTile({
    required this.title,
    this.artist,
    this.coverUrl,
    required this.trackCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: onTap,
      leading: CoverImage(url: coverUrl, size: 50, borderRadius: 10),
      title: Text(title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFD0D0F0))),
      subtitle: Text(
        (artist != null && artist!.isNotEmpty) ? artist! : '$trackCount tracks',
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
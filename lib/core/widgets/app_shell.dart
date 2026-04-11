// lib/core/widgets/app_shell.dart
//
// BLAST BUFFER QUEUE FIX — GRANULAR PROVIDER SELECTION
// =====================================================
//
// ROOT CAUSE:
//   ref.watch(audioPlayerProvider) subscribes to the ENTIRE AudioPlayerState.
//   AudioPlayerState.position updates every ~100ms while audio plays.
//   This caused AppShell.build() to run every 100ms, triggering a full
//   widget subtree rebuild including:
//     - Column (bottomNavigationBar)
//     - MiniPlayer (which itself watches audioPlayerProvider)
//     - _BottomNav
//
//   Even though AppShell only needs `playerState.hasMedia`, it rebuilt
//   everything on every position tick. Each rebuild → Flutter schedules
//   a frame → SurfaceView queues a buffer.
//
//   At 10 position ticks/second with a ~16ms frame budget:
//     10 AppShell rebuilds/sec + 10 MiniPlayer rebuilds/sec = 20 rebuilds/sec
//     Plus audio_handler.dart notification broadcasts (now fixed to 60fps max)
//     = total buffer production >> SurfaceFlinger consumption rate
//
// FIX:
//   Use ref.watch(audioPlayerProvider.select((s) => s.hasMedia)) so AppShell
//   ONLY rebuilds when hasMedia changes (i.e. when audio starts or stops
//   entirely). This reduces AppShell rebuilds from 10/sec to ~0/sec during
//   normal playback.
//
//   MiniPlayer still watches the full state (it needs position, isPlaying, etc.)
//   but it's now isolated by RepaintBoundary so its repaints don't cascade up.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/player/presentation/mini_player.dart';
import '../../features/player/providers/audio_player_provider.dart';
import '../theme/app_theme.dart';

class AppShell extends ConsumerWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // FIX: Only watch hasMedia — not the full state.
    // AppShell rebuilds ONLY when audio starts or stops (hasMedia changes).
    // Position ticks (10Hz) no longer cause AppShell to rebuild.
    final hasMedia = ref.watch(
      audioPlayerProvider.select((s) => s.hasMedia),
    );

    final location = GoRouterState.of(context).uri.toString();
    final currentIndex = _locationToIndex(location);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // FIX: RepaintBoundary isolates MiniPlayer repaints from the
          // BottomNav and the rest of the shell. MiniPlayer repaints at
          // 10Hz (position ticks) but BottomNav only needs to repaint
          // when the selected tab changes. Without RepaintBoundary, the
          // BottomNav's RenderObject gets invalidated on every MiniPlayer
          // rebuild, queuing unnecessary frames.
          if (hasMedia)
            const RepaintBoundary(child: MiniPlayer()),
          _BottomNav(currentIndex: currentIndex),
        ],
      ),
    );
  }

  int _locationToIndex(String location) {
    if (location.startsWith('/stories')) return 1;
    if (location.startsWith('/music')) return 2;
    if (location.startsWith('/search')) return 3;
    if (location.startsWith('/downloads')) return 4;
    return 0;
  }
}

class _BottomNav extends StatelessWidget {
  final int currentIndex;

  const _BottomNav({required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(
            color: AppColors.primary.withOpacity(0.1),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: BottomNavigationBar(
          currentIndex: currentIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.textTertiary,
          selectedFontSize: 11,
          unselectedFontSize: 11,
          onTap: (i) => _onTap(context, i),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              activeIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.auto_stories_rounded),
              activeIcon: Icon(Icons.auto_stories_rounded),
              label: 'Stories',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.music_note_rounded),
              activeIcon: Icon(Icons.music_note_rounded),
              label: 'Music',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.search_rounded),
              activeIcon: Icon(Icons.search_rounded),
              label: 'Search',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.download_rounded),
              activeIcon: Icon(Icons.download_rounded),
              label: 'Downloads',
            ),
          ],
        ),
      ),
    );
  }

  void _onTap(BuildContext context, int index) {
    final routes = ['/home', '/stories', '/music', '/search', '/downloads'];
    if (index < routes.length) {
      context.go(routes[index]);
    }
  }
}
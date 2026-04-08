// lib/core/widgets/app_shell.dart
// No direct PlayerState reference here — it reads audioPlayerProvider which
// now returns AudioPlayerState. No changes needed beyond ensuring the import
// still works. File reproduced for completeness.

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
    final playerState = ref.watch(audioPlayerProvider);
    final location = GoRouterState.of(context).uri.toString();
    final currentIndex = _locationToIndex(location);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (playerState.hasMedia) const MiniPlayer(),
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
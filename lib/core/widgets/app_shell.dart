// lib/core/widgets/app_shell.dart
// VYNCE APP SHELL — Purple/Cyan bottom nav

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
    final hasMedia     = ref.watch(audioPlayerProvider.select((s) => s.hasMedia));
    final location     = GoRouterState.of(context).uri.toString();
    final currentIndex = _locationToIndex(location);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasMedia) const RepaintBoundary(child: MiniPlayer()),
          _VynceBottomNav(currentIndex: currentIndex),
        ],
      ),
    );
  }

  int _locationToIndex(String location) {
    if (location.startsWith('/stories'))   return 1;
    if (location.startsWith('/music'))     return 2;
    if (location.startsWith('/search'))    return 3;
    if (location.startsWith('/downloads')) return 4;
    return 0;
  }
}

// ─── Bottom Nav ───────────────────────────────────────────────────────────────

class _VynceBottomNav extends StatelessWidget {
  final int currentIndex;
  const _VynceBottomNav({required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: const Color(0xFF7C3AED).withOpacity(0.12), width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(index: 0, current: currentIndex, icon: Icons.home_rounded, label: 'Home'),
              _NavItem(index: 1, current: currentIndex, icon: Icons.auto_stories_rounded, label: 'Stories'),
              _NavItem(index: 2, current: currentIndex, icon: Icons.music_note_rounded, label: 'Music'),
              _NavItem(index: 3, current: currentIndex, icon: Icons.search_rounded, label: 'Search'),
              _NavItem(index: 4, current: currentIndex, icon: Icons.download_rounded, label: 'Downloads'),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final int index;
  final int current;
  final IconData icon;
  final String label;
  const _NavItem({required this.index, required this.current, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final isActive = index == current;
    final routes   = ['/home', '/stories', '/music', '/search', '/downloads'];

    return GestureDetector(
      onTap: () => context.go(routes[index]),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive)
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
                ).createShader(r),
                child: Icon(icon, size: 22, color: Colors.white),
              )
            else
              Icon(icon, size: 22, color: const Color(0xFF4B5563)),
            const SizedBox(height: 3),
            if (isActive)
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
                ).createShader(r),
                child: Text(label,
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Colors.white)),
              )
            else
              Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF4B5563))),
            if (isActive)
              const SizedBox(
                height: 4,
                child: Center(
                  child: SizedBox(
                    width: 4,
                    height: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF7C3AED),
                      ),
                    ),
                  ),
                ),
              )
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
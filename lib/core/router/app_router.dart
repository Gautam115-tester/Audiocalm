// lib/core/router/app_router.dart

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/calm_stories/presentation/stories_screen.dart';
import '../../features/calm_stories/presentation/series_detail_screen.dart';
import '../../features/calm_music/presentation/music_screen.dart';
import '../../features/calm_music/presentation/album_detail_screen.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/downloads/presentation/downloads_screen.dart';
import '../../features/favorites/presentation/favorites_screen.dart';
import '../../features/player/presentation/player_screen.dart';
import '../widgets/app_shell.dart';

class AppRouter {
  AppRouter._();

  static bool _navigatingToPlayer = false;

  static final _rootNavigatorKey = GlobalKey<NavigatorState>();
  static final _shellNavigatorKey = GlobalKey<NavigatorState>();

  static final router = GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/home',
    routes: [
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: HomeScreen(),
            ),
          ),
          GoRoute(
            path: '/stories',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: StoriesScreen(),
            ),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) => SeriesDetailScreen(
                  seriesId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/music',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: MusicScreen(),
            ),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) => AlbumDetailScreen(
                  albumId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SearchScreen(),
            ),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: DownloadsScreen(),
            ),
          ),
          GoRoute(
            path: '/favorites',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: FavoritesScreen(),
            ),
          ),
        ],
      ),
      // Player is a full-screen route outside the shell
      GoRoute(
        path: '/player',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => CustomTransitionPage(
          child: const PlayerScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              )),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 350),
        ),
      ),
    ],
  );

  // Deduplication guard for player navigation
  static void navigateToPlayer(BuildContext context) {
    if (_navigatingToPlayer) return;
    _navigatingToPlayer = true;

    final router = GoRouter.of(context);
    final location = router.routerDelegate.currentConfiguration.uri.toString();

    if (location != '/player') {
      context.push('/player');
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      _navigatingToPlayer = false;
    });
  }
}

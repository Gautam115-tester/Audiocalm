// lib/features/player/presentation/player_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../providers/audio_player_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/constants/app_constants.dart';
import '../../favorites/providers/favorites_provider.dart';
import 'equalizer_sheet.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with TickerProviderStateMixin {
  late AnimationController _artworkController;
  late Animation<double> _artworkScale;
  bool _isSeeking = false;
  double _seekValue = 0;

  @override
  void initState() {
    super.initState();
    _artworkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _artworkScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _artworkController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _artworkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerState = ref.watch(audioPlayerProvider);
    final notifier = ref.read(audioPlayerProvider.notifier);

    if (!playerState.hasMedia) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(),
        body: const Center(child: Text('No media playing')),
      );
    }

    final item = playerState.currentItem!;

    if (playerState.isPlaying) {
      _artworkController.forward();
    } else {
      _artworkController.reverse();
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null) {
            if (details.primaryVelocity! > 500) {
              notifier.skipToPrevious();
            } else if (details.primaryVelocity! < -500) {
              notifier.skipToNext();
            }
          }
        },
        child: Container(
          decoration: const BoxDecoration(gradient: AppColors.playerGradient),
          child: SafeArea(
            child: Column(
              children: [
                _buildTopBar(context),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: Column(
                      children: [
                        const SizedBox(height: 20),
                        _buildArtwork(item.artworkUrl),
                        const SizedBox(height: 28),
                        _buildTitleSection(
                            context, item.title, item.subtitle, playerState),
                        const SizedBox(height: 24),
                        _buildSeekBar(context, playerState, notifier),
                        const SizedBox(height: 16),
                        _buildMainControls(context, playerState, notifier),
                        const SizedBox(height: 20),
                        _buildBottomControls(context, playerState, notifier),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
            color: AppColors.textSecondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              'NOW PLAYING',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 2,
                    color: AppColors.primary,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            color: AppColors.textSecondary,
            onPressed: () => _showOptions(context),
          ),
        ],
      ),
    );
  }

  Widget _buildArtwork(String? url) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: ScaleTransition(
        scale: _artworkScale,
        child: Container(
          height: 260,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.25),
                blurRadius: 40,
                spreadRadius: 4,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: CoverImage(
              url: url,
              size: double.infinity,
              borderRadius: 24,
              placeholder: Container(
                decoration:
                    const BoxDecoration(gradient: AppColors.cardGradient),
                child: const Center(
                  child: Icon(Icons.music_note_rounded,
                      size: 72, color: AppColors.textTertiary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleSection(
    BuildContext context,
    String title,
    String? subtitle,
    AudioPlayerState state,
  ) {
    final item = state.currentItem;
    final isFav = item != null
        ? ref.watch(favoritesProvider).contains(item.id)
        : false;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (item != null)
            IconButton(
              icon: Icon(
                isFav
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: isFav ? AppColors.error : AppColors.textSecondary,
                size: 28,
              ),
              onPressed: () =>
                  ref.read(favoritesProvider.notifier).toggle(item.id),
            ),
        ],
      ),
    );
  }

  Widget _buildSeekBar(
    BuildContext context,
    AudioPlayerState state,
    AudioPlayerNotifier notifier,
  ) {
    final position = _isSeeking
        ? Duration(
            milliseconds: (_seekValue *
                    (state.duration?.inMilliseconds ?? 0))
                .toInt())
        : state.position;
    final duration = state.duration ?? Duration.zero;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 18),
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.surfaceVariant,
              thumbColor: Colors.white,
              overlayColor: AppColors.primary.withOpacity(0.15),
            ),
            child: Slider(
              value: (_isSeeking ? _seekValue : progress).toDouble(),
              onChangeStart: (_) => setState(() => _isSeeking = true),
              onChanged: (v) => setState(() => _seekValue = v),
              onChangeEnd: (v) {
                setState(() => _isSeeking = false);
                final ms =
                    (v * (state.duration?.inMilliseconds ?? 0)).toInt();
                notifier.seek(Duration(milliseconds: ms));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(position),
                    style: Theme.of(context).textTheme.labelSmall),
                Text(_formatDuration(duration),
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainControls(
    BuildContext context,
    AudioPlayerState state,
    AudioPlayerNotifier notifier,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Fix: Icons.forward_15_rounded doesn't exist → use replay_10_rounded
        _ControlButton(
          icon: Icons.replay_10_rounded,
          onTap: notifier.skipBackward,
          size: 32,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: 12),
        _ControlButton(
          icon: Icons.skip_previous_rounded,
          onTap: notifier.skipToPrevious,
          size: 36,
          color: AppColors.textPrimary,
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: notifier.togglePlayPause,
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, AppColors.primaryDark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: state.isLoading
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5),
                  )
                : Icon(
                    state.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
          ),
        ),
        const SizedBox(width: 12),
        _ControlButton(
          icon: Icons.skip_next_rounded,
          onTap: notifier.skipToNext,
          size: 36,
          color: AppColors.textPrimary,
        ),
        const SizedBox(width: 12),
        // Fix: Icons.forward_15_rounded doesn't exist → use forward_10_rounded
        _ControlButton(
          icon: Icons.forward_10_rounded,
          onTap: notifier.skipForward,
          size: 32,
          color: AppColors.textSecondary,
        ),
      ],
    );
  }

  Widget _buildBottomControls(
    BuildContext context,
    AudioPlayerState state,
    AudioPlayerNotifier notifier,
  ) {
    // Fix: exhaustive switch on ja.LoopMode (sealed enum)
    final loopIcon = switch (state.loopMode) {
      ja.LoopMode.off => Icons.repeat_rounded,
      ja.LoopMode.one => Icons.repeat_one_rounded,
      ja.LoopMode.all => Icons.repeat_rounded,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _IconToggle(
            icon: Icons.shuffle_rounded,
            active: state.shuffleMode,
            onTap: notifier.toggleShuffle,
          ),
          _IconToggle(
            icon: loopIcon,
            active: state.loopMode != ja.LoopMode.off,
            onTap: notifier.cycleLoopMode,
          ),
          _SpeedButton(speed: state.speed, onChanged: notifier.setSpeed),
          if (state.currentItem?.isSong ?? false)
            _IconToggle(
              icon: Icons.equalizer_rounded,
              active: false,
              onTap: () => _showEqualizer(context),
            )
          else
            const SizedBox(width: 36),
        ],
      ),
    );
  }

  void _showEqualizer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EqualizerSheet(),
    );
  }

  void _showOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Queue'),
              onTap: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final Color color;

  const _ControlButton({
    required this.icon,
    required this.onTap,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: size, color: color),
      ),
    );
  }
}

class _IconToggle extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _IconToggle(
      {required this.icon, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon,
            size: 24,
            color: active ? AppColors.primary : AppColors.textTertiary),
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {
  final double speed;
  final void Function(double) onChanged;

  const _SpeedButton({required this.speed, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showSpeedMenu(context),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: speed != 1.0
                ? AppColors.primary.withOpacity(0.5)
                : Colors.transparent,
          ),
        ),
        child: Text(
          '${speed}x',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: speed != 1.0
                    ? AppColors.primary
                    : AppColors.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
        ),
      ),
    );
  }

  void _showSpeedMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Text('Playback Speed',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            ...AppConstants.playbackSpeeds.map(
              (s) => ListTile(
                title: Text('${s}x'),
                trailing: speed == s
                    ? const Icon(Icons.check_rounded,
                        color: AppColors.primary)
                    : null,
                onTap: () {
                  onChanged(s);
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
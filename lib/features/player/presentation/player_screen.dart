// lib/features/player/presentation/player_screen.dart
//
// FIXES IN THIS VERSION
// =====================
//
// FIX — PLAYER SCREEN FREEZE (seek bar stuck at 00:00)
// ------------------------------------------------------
// ROOT CAUSE:
//   The entire PlayerScreen was one ConsumerStatefulWidget calling
//   ref.watch(audioPlayerProvider) — watching the FULL AudioPlayerState.
//   Position updates fire at up to 10 Hz. Every tick forced:
//     • _artworkController.forward/reverse() called inside build()
//     • ScaleTransition, CoverImage, title text, all controls to rebuild
//     • The Slider and time labels to rebuild
//   On mid-range Android this starved the Choreographer → frame drops →
//   seek bar appeared stuck at 00:00 even though audio was playing.
//
// FIX — Split into isolated ConsumerWidget subtrees, each selecting only
//   the exact scalar it needs:
//
//   _ArtworkSection        → ref.watch(.select isPlaying)
//                            ref.watch(.select artworkUrl)
//   _TitleSection          → ref.watch(.select currentItem)
//                            ref.watch(favoritesProvider)
//   _SeekBarSection        → ref.watch(.select position)   ← 10 Hz
//                            ref.watch(.select duration)
//                            wrapped in RepaintBoundary by parent
//   _MainControlsSection   → ref.watch(.select isPlaying)
//                            ref.watch(.select isLoading)
//   _BottomControlsSection → ref.watch(.select loopMode)
//                            ref.watch(.select shuffleMode)
//                            ref.watch(.select speed)
//                            ref.watch(.select isSong)
//
// The outer PlayerScreen now watches ONLY hasMedia.
// During normal playback the ONLY thing rebuilding at 10 Hz is _SeekBarSection.
// Its RepaintBoundary means those repaints are an isolated compositing layer
// that never dirtifies the artwork, title, or controls.
//
// FIX — LOOP ORDER
//   off → all (repeat album/queue) → one (repeat single track) → off
//   Matches Spotify / Apple Music / YouTube Music standard UX.
//   Icon: off=grey repeat, all=primary repeat, one=primary repeat_one
//
// All previous fixes preserved:
//   FIX 4 — speed sheet isScrollControlled + Column (no ListView overflow)
//   FIX 5 — queue sheet SafeArea clears system nav bar
//   Swipe-to-skip horizontal drag gesture
//   Equalizer sheet

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../providers/audio_player_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/constants/app_constants.dart';
import '../../favorites/providers/favorites_provider.dart';
import 'equalizer_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ROOT — only watches hasMedia; NEVER rebuilds on position ticks
// ─────────────────────────────────────────────────────────────────────────────

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasMedia = ref.watch(
      audioPlayerProvider.select((s) => s.hasMedia),
    );

    if (!hasMedia) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(),
        body: const Center(child: Text('No media playing')),
      );
    }

    return const _PlayerBody();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BODY — structural skeleton only, never rebuilds during playback
// ─────────────────────────────────────────────────────────────────────────────

class _PlayerBody extends ConsumerWidget {
  const _PlayerBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(audioPlayerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null) {
            if (details.primaryVelocity! > 500)       notifier.skipToPrevious();
            else if (details.primaryVelocity! < -500) notifier.skipToNext();
          }
        },
        child: Container(
          decoration: const BoxDecoration(gradient: AppColors.playerGradient),
          child: SafeArea(
            child: Column(
              children: [
                const _TopBar(),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: Column(
                      children: const [
                        SizedBox(height: 20),

                        // Artwork — rebuilds only when isPlaying or artworkUrl changes
                        _ArtworkSection(),
                        SizedBox(height: 28),

                        // Title + heart — rebuilds only when item or fav changes
                        _TitleSection(),
                        SizedBox(height: 24),

                        // Seek bar — 10 Hz but isolated compositing layer
                        RepaintBoundary(child: _SeekBarSection()),
                        SizedBox(height: 16),

                        // Play/pause — rebuilds only on isPlaying/isLoading
                        _MainControlsSection(),
                        SizedBox(height: 20),

                        // Shuffle/loop/speed/EQ — rebuilds only on those values
                        _BottomControlsSection(),
                        SizedBox(height: 16),
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
}

// ─────────────────────────────────────────────────────────────────────────────
// TOP BAR
// ─────────────────────────────────────────────────────────────────────────────

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon:  const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
            color: AppColors.textSecondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              'NOW PLAYING',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 2,
                color:         AppColors.primary,
              ),
            ),
          ),
          IconButton(
            icon:  const Icon(Icons.more_vert_rounded),
            color: AppColors.textSecondary,
            onPressed: () => _showOptions(context),
          ),
        ],
      ),
    );
  }

  // FIX 5: SafeArea clears the system navigation bar automatically.
  void _showOptions(BuildContext context) {
    showModalBottomSheet(
      context:         context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            color:        AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width:  36,
                height: 4,
                decoration: BoxDecoration(
                  color:        AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title:   const Text('Queue'),
                onTap:   () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ARTWORK — rebuilds ONLY when isPlaying changes (scale animation)
//           or artworkUrl changes (track skip)
// ─────────────────────────────────────────────────────────────────────────────

class _ArtworkSection extends ConsumerStatefulWidget {
  const _ArtworkSection();

  @override
  ConsumerState<_ArtworkSection> createState() => _ArtworkSectionState();
}

class _ArtworkSectionState extends ConsumerState<_ArtworkSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 300),
    );
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = ref.watch(
      audioPlayerProvider.select((s) => s.isPlaying),
    );
    final artworkUrl = ref.watch(
      audioPlayerProvider.select((s) => s.currentItem?.artworkUrl),
    );

    // forward/reverse are idempotent when already at target — safe in build
    if (isPlaying) _ctrl.forward();
    else           _ctrl.reverse();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          height: 260,
          width:  double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color:        AppColors.primary.withOpacity(0.25),
                blurRadius:   40,
                spreadRadius: 4,
                offset:       const Offset(0, 16),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: CoverImage(
              url:          artworkUrl,
              size:         double.infinity,
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
}

// ─────────────────────────────────────────────────────────────────────────────
// TITLE + FAVORITE — rebuilds only when currentItem or favorites changes
// ─────────────────────────────────────────────────────────────────────────────

class _TitleSection extends ConsumerWidget {
  const _TitleSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(
      audioPlayerProvider.select((s) => s.currentItem),
    );
    final isFav = item != null
        ? ref.watch(favoritesProvider).contains(item.id)
        : false;

    if (item == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.subtitle!,
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
          IconButton(
            icon: Icon(
              isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: isFav ? AppColors.error : AppColors.textSecondary,
              size:  28,
            ),
            onPressed: () =>
                ref.read(favoritesProvider.notifier).toggle(item.id),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SEEK BAR — THE MAIN FREEZE FIX
//
// This is the ONLY widget that updates at 10 Hz. It is wrapped in a
// RepaintBoundary by its parent (_PlayerBody) so its repaints are an isolated
// compositing layer. The artwork, title, and controls are NEVER invalidated
// by a position tick.
//
// Previously this ran inside the root ConsumerStatefulWidget which watched the
// full state — every tick dropped frames on the main thread, making the seek
// bar appear frozen at 00:00.
// ─────────────────────────────────────────────────────────────────────────────

class _SeekBarSection extends ConsumerStatefulWidget {
  const _SeekBarSection();

  @override
  ConsumerState<_SeekBarSection> createState() => _SeekBarSectionState();
}

class _SeekBarSectionState extends ConsumerState<_SeekBarSection> {
  bool   _isSeeking = false;
  double _seekValue  = 0;

  @override
  Widget build(BuildContext context) {
    // ONLY subscribe to position and duration
    final position = ref.watch(
      audioPlayerProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      audioPlayerProvider.select((s) => s.duration),
    );

    final notifier = ref.read(audioPlayerProvider.notifier);

    final displayPos = _isSeeking
        ? Duration(
            milliseconds:
                (_seekValue * (duration?.inMilliseconds ?? 0)).toInt())
        : position;
    final displayDur = duration ?? Duration.zero;
    final progress   = displayDur.inMilliseconds > 0
        ? (displayPos.inMilliseconds / displayDur.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight:        4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 18),
              activeTrackColor:   AppColors.primary,
              inactiveTrackColor: AppColors.surfaceVariant,
              thumbColor:         Colors.white,
              overlayColor:       AppColors.primary.withOpacity(0.15),
            ),
            child: Slider(
              value: (_isSeeking ? _seekValue : progress).toDouble(),
              onChangeStart: (_) => setState(() => _isSeeking = true),
              onChanged:     (v) => setState(() => _seekValue = v),
              onChangeEnd:   (v) {
                setState(() => _isSeeking = false);
                final ms =
                    (v * (duration?.inMilliseconds ?? 0)).toInt();
                notifier.seek(Duration(milliseconds: ms));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(displayPos),
                    style: Theme.of(context).textTheme.labelSmall),
                Text(_fmt(displayDur),
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN CONTROLS — rebuilds only when isPlaying or isLoading changes
// ─────────────────────────────────────────────────────────────────────────────

class _MainControlsSection extends ConsumerWidget {
  const _MainControlsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      audioPlayerProvider.select((s) => s.isPlaying),
    );
    final isLoading = ref.watch(
      audioPlayerProvider.select((s) => s.isLoading),
    );
    final notifier = ref.read(audioPlayerProvider.notifier);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ControlButton(
          icon:  Icons.replay_10_rounded,
          onTap: notifier.skipBackward,
          size:  32,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: 12),
        _ControlButton(
          icon:  Icons.skip_previous_rounded,
          onTap: notifier.skipToPrevious,
          size:  36,
          color: AppColors.textPrimary,
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: notifier.togglePlayPause,
          child: Container(
            width:  70,
            height: 70,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, AppColors.primaryDark],
                begin:  Alignment.topLeft,
                end:    Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color:      AppColors.primary.withOpacity(0.4),
                  blurRadius: 24,
                  offset:     const Offset(0, 8),
                ),
              ],
            ),
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5),
                  )
                : Icon(
                    isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size:  36,
                  ),
          ),
        ),
        const SizedBox(width: 12),
        _ControlButton(
          icon:  Icons.skip_next_rounded,
          onTap: notifier.skipToNext,
          size:  36,
          color: AppColors.textPrimary,
        ),
        const SizedBox(width: 12),
        _ControlButton(
          icon:  Icons.forward_10_rounded,
          onTap: notifier.skipForward,
          size:  32,
          color: AppColors.textSecondary,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOTTOM CONTROLS — shuffle / loop / speed / EQ
//   Rebuilds only when loop mode, shuffle, speed, or item type changes.
// ─────────────────────────────────────────────────────────────────────────────

class _BottomControlsSection extends ConsumerWidget {
  const _BottomControlsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loopMode = ref.watch(
      audioPlayerProvider.select((s) => s.loopMode),
    );
    final shuffleMode = ref.watch(
      audioPlayerProvider.select((s) => s.shuffleMode),
    );
    final speed = ref.watch(
      audioPlayerProvider.select((s) => s.speed),
    );
    final isSong = ref.watch(
      audioPlayerProvider.select((s) => s.currentItem?.isSong ?? false),
    );
    final notifier = ref.read(audioPlayerProvider.notifier);

    // Loop icon — new order: off → all → one → off
    //   off = repeat icon, GREY    (no loop)
    //   all = repeat icon, PRIMARY (repeat whole album — 1st tap)
    //   one = repeat_one,  PRIMARY (repeat single track — 2nd tap)
    final loopIcon = switch (loopMode) {
      ja.LoopMode.off => Icons.repeat_rounded,
      ja.LoopMode.all => Icons.repeat_rounded,
      ja.LoopMode.one => Icons.repeat_one_rounded,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _IconToggle(
            icon:   Icons.shuffle_rounded,
            active: shuffleMode,
            onTap:  notifier.toggleShuffle,
          ),
          _IconToggle(
            icon:   loopIcon,
            active: loopMode != ja.LoopMode.off,
            onTap:  notifier.cycleLoopMode,
          ),
          _SpeedButton(speed: speed, onChanged: notifier.setSpeed),
          if (isSong)
            _IconToggle(
              icon:   Icons.equalizer_rounded,
              active: false,
              onTap:  () => _showEqualizer(context),
            )
          else
            const SizedBox(width: 36),
        ],
      ),
    );
  }

  void _showEqualizer(BuildContext context) {
    showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => const EqualizerSheet(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SPEED BUTTON — FIX 4 (unchanged)
// ─────────────────────────────────────────────────────────────────────────────

class _SpeedButton extends StatelessWidget {
  final double speed;
  final void Function(double) onChanged;

  const _SpeedButton({required this.speed, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showSpeedMenu(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color:        AppColors.surfaceVariant,
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
            fontSize:   12,
          ),
        ),
      ),
    );
  }

  void _showSpeedMenu(BuildContext context) {
    showModalBottomSheet(
      context:            context,
      backgroundColor:    Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            color:        AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              Text(
                'Playback Speed',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
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
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED CONTROL WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData     icon;
  final VoidCallback onTap;
  final double       size;
  final Color        color;

  const _ControlButton({
    required this.icon,
    required this.onTap,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap:    onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child:   Icon(icon, size: size, color: color),
      ),
    );
  }
}

class _IconToggle extends StatelessWidget {
  final IconData     icon;
  final bool         active;
  final VoidCallback onTap;

  const _IconToggle({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          icon,
          size:  24,
          color: active ? AppColors.primary : AppColors.textTertiary,
        ),
      ),
    );
  }
}
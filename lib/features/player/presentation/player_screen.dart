// lib/features/player/presentation/player_screen.dart
// VYNCE PLAYER — Full screen, Purple/Cyan gradient identity with glow effects
//
// FIXES:
// 1. SEEKBAR PIXEL OVERFLOW — thumb was rendering outside track bounds when
//    progress was near 1.0. Fixed by clamping fillW so the thumb center never
//    exceeds the track width, and using a ClipRect on the fill bar.
// 2. TAP-TO-SEEK — added onTapDown handler so a single tap (not just drag)
//    also seeks to the tapped position.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../providers/audio_player_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../../core/constants/app_constants.dart';
import '../../favorites/providers/favorites_provider.dart';
import 'equalizer_sheet.dart';

// ─── Root ─────────────────────────────────────────────────────────────────────

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasMedia = ref.watch(audioPlayerProvider.select((s) => s.hasMedia));

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

// ─── Body ─────────────────────────────────────────────────────────────────────

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
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      const _ArtworkSection(),
                      const _TitleSection(),
                      const RepaintBoundary(child: _SeekBarSection()),
                      const _MainControlsSection(),
                      const _BottomControlsSection(),
                    ],
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

// ─── Top bar ──────────────────────────────────────────────────────────────────

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
              ).createShader(r),
              child: const Text(
                'NOW PLAYING',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2.5,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, size: 28),
            color: AppColors.textSecondary,
            onPressed: () => _showOptions(context),
          ),
        ],
      ),
    );
  }

  void _showOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.queue_music_rounded, color: AppColors.primary),
                title: const Text('Queue'),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Artwork ──────────────────────────────────────────────────────────────────

class _ArtworkSection extends ConsumerStatefulWidget {
  const _ArtworkSection();

  @override
  ConsumerState<_ArtworkSection> createState() => _ArtworkSectionState();
}

class _ArtworkSectionState extends ConsumerState<_ArtworkSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _scale = Tween<double>(begin: 0.88, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying  = ref.watch(audioPlayerProvider.select((s) => s.isPlaying));
    final artworkUrl = ref.watch(audioPlayerProvider.select((s) => s.currentItem?.artworkUrl));
    final screenWidth = MediaQuery.of(context).size.width;
    final artworkSize = screenWidth - 48.0;

    if (isPlaying) _ctrl.forward();
    else _ctrl.reverse();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          height: artworkSize,
          width: artworkSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.25)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7C3AED).withOpacity(0.35),
                blurRadius: 50,
                spreadRadius: 4,
                offset: const Offset(0, 16),
              ),
              BoxShadow(
                color: const Color(0xFF06B6D4).withOpacity(0.15),
                blurRadius: 70,
                spreadRadius: 0,
                offset: const Offset(0, 24),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: CoverImage(
              url: artworkUrl,
              size: double.infinity,
              borderRadius: 24,
              placeholder: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1A0533), Color(0xFF0C1A4A)],
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.music_note_rounded, size: 100, color: Color(0xFF7C3AED)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Title + Favorite ─────────────────────────────────────────────────────────

class _TitleSection extends ConsumerWidget {
  const _TitleSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item  = ref.watch(audioPlayerProvider.select((s) => s.currentItem));
    final isFav = item != null ? ref.watch(favoritesProvider).contains(item.id) : false;

    if (item == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFF0F0FF),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (item.subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${item.subtitle!} · Vynce',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
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
              size: 28,
            ),
            onPressed: () => ref.read(favoritesProvider.notifier).toggle(item.id),
          ),
        ],
      ),
    );
  }
}

// ─── Seek Bar ─────────────────────────────────────────────────────────────────
//
// FIX 1: PIXEL OVERFLOW — thumb was painted outside track bounds when progress ≈ 1.0
//   Root cause: `left: fillW - 7` could place the 14px thumb so its right edge
//   exceeded `totalW`, causing a RenderFlex overflow pixel.
//   Fix: clamp the thumb's left position to `totalW - 14` so it never escapes.
//
// FIX 2: TAP-TO-SEEK — onTapDown now seeks immediately on a single tap.
//   Previously only drag worked; tapping had no effect.

class _SeekBarSection extends ConsumerStatefulWidget {
  const _SeekBarSection();

  @override
  ConsumerState<_SeekBarSection> createState() => _SeekBarSectionState();
}

class _SeekBarSectionState extends ConsumerState<_SeekBarSection> {
  bool   _isSeeking = false;
  double _seekValue = 0;

  // Convert a local x offset to a 0..1 progress value, clamped.
  double _xToProgress(double x, double totalWidth) {
    return (x / totalWidth).clamp(0.0, 1.0);
  }

  void _commitSeek(double progress, Duration? duration) {
    if (duration == null || duration == Duration.zero) return;
    final ms = (progress * duration.inMilliseconds).toInt();
    ref.read(audioPlayerProvider.notifier).seek(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(audioPlayerProvider.select((s) => s.position));
    final duration = ref.watch(audioPlayerProvider.select((s) => s.duration));

    final displayPos = _isSeeking
        ? Duration(milliseconds: (_seekValue * (duration?.inMilliseconds ?? 0)).toInt())
        : position;
    final displayDur = duration ?? Duration.zero;
    final progress   = displayDur.inMilliseconds > 0
        ? (displayPos.inMilliseconds / displayDur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          LayoutBuilder(builder: (_, constraints) {
            final totalW = constraints.maxWidth;
            // FIX 1: clamp fill so the 14px thumb never overflows totalW.
            // fillW can equal totalW; thumb left is clamped to totalW - 14.
            final rawFillW = totalW * progress;
            final fillW    = rawFillW.clamp(0.0, totalW);
            final thumbLeft = (fillW - 7.0).clamp(0.0, totalW - 14.0);

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // FIX 2: tap-to-seek
              onTapDown: (details) {
                final p = _xToProgress(details.localPosition.dx, totalW);
                setState(() {
                  _isSeeking  = false;
                  _seekValue  = p;
                });
                _commitSeek(p, duration);
              },
              onHorizontalDragStart: (details) {
                setState(() {
                  _isSeeking = true;
                  _seekValue = _xToProgress(details.localPosition.dx, totalW);
                });
              },
              onHorizontalDragUpdate: (details) {
                setState(() {
                  _seekValue = _xToProgress(details.localPosition.dx, totalW);
                });
              },
              onHorizontalDragEnd: (_) {
                final p = _seekValue;
                setState(() => _isSeeking = false);
                _commitSeek(p, duration);
              },
              child: SizedBox(
                height: 36, // taller hit area for easier touch
                child: Stack(
                  alignment: Alignment.centerLeft,
                  clipBehavior: Clip.none,
                  children: [
                    // Track background
                    Positioned(
                      top: 0, bottom: 0,
                      left: 0, right: 0,
                      child: Center(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1A2E),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                    // Filled portion — clipped so it never overflows
                    Positioned(
                      top: 0, bottom: 0, left: 0,
                      child: Center(
                        child: ClipRect(
                          child: Container(
                            height: 4,
                            width: fillW,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              gradient: const LinearGradient(
                                colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Thumb — FIX 1: left is clamped so thumb stays on screen
                    if (fillW > 0)
                      Positioned(
                        left: thumbLeft,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isSeeking
                                  ? const Color(0xFF06B6D4)
                                  : const Color(0xFFA855F7),
                              boxShadow: [
                                BoxShadow(
                                  color: _isSeeking
                                      ? const Color(0xFF06B6D4)
                                      : const Color(0xFFA855F7),
                                  blurRadius: _isSeeking ? 14 : 10,
                                  spreadRadius: _isSeeking ? 3 : 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(displayPos), style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563))),
                Text(_fmt(displayDur), style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563))),
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
    if (h > 0) return '$h:${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
    return '${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
  }
}

// ─── Main Controls ────────────────────────────────────────────────────────────

class _MainControlsSection extends ConsumerWidget {
  const _MainControlsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(audioPlayerProvider.select((s) => s.isPlaying));
    final isLoading = ref.watch(audioPlayerProvider.select((s) => s.isLoading));
    final notifier  = ref.read(audioPlayerProvider.notifier);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _VynceCtrlBtn(
          icon: Icons.skip_previous_rounded,
          onTap: notifier.skipToPrevious,
          size: 30,
        ),
        const SizedBox(width: 8),
        _VynceCtrlBtn(
          widget: _SkipWidget(label: '-10s', onTap: notifier.skipBackward, forward: false),
          size: 30,
        ),
        const SizedBox(width: 16),
        GestureDetector(
          onTap: notifier.togglePlayPause,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7C3AED).withOpacity(0.5),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                  )
                : Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
          ),
        ),
        const SizedBox(width: 16),
        _VynceCtrlBtn(
          widget: _SkipWidget(label: '+15s', onTap: notifier.skipForward, forward: true),
          size: 30,
        ),
        const SizedBox(width: 8),
        _VynceCtrlBtn(
          icon: Icons.skip_next_rounded,
          onTap: notifier.skipToNext,
          size: 30,
        ),
      ],
    );
  }
}

// ─── Skip visual ──────────────────────────────────────────────────────────────

class _SkipWidget extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool forward;
  const _SkipWidget({required this.label, required this.onTap, this.forward = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF4B5563), width: 1.5),
                  ),
                ),
                Text(
                  forward ? '15' : '10',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFC4B5FD),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: Color(0xFF6B7280), letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }
}

// ─── Bottom Controls ──────────────────────────────────────────────────────────

class _BottomControlsSection extends ConsumerWidget {
  const _BottomControlsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loopMode    = ref.watch(audioPlayerProvider.select((s) => s.loopMode));
    final shuffleMode = ref.watch(audioPlayerProvider.select((s) => s.shuffleMode));
    final speed       = ref.watch(audioPlayerProvider.select((s) => s.speed));
    final isSong      = ref.watch(audioPlayerProvider.select((s) => s.currentItem?.isSong ?? false));
    final notifier    = ref.read(audioPlayerProvider.notifier);

    final loopIcon = switch (loopMode) {
      ja.LoopMode.off => Icons.repeat_rounded,
      ja.LoopMode.all => Icons.repeat_rounded,
      ja.LoopMode.one => Icons.repeat_one_rounded,
    };
    final loopActive = loopMode != ja.LoopMode.off;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _IconToggle(icon: Icons.shuffle_rounded, active: shuffleMode, onTap: notifier.toggleShuffle),
          _IconToggle(icon: loopIcon, active: loopActive, onTap: notifier.cycleLoopMode),
          _SpeedButton(speed: speed, onChanged: notifier.setSpeed),
          if (isSong)
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
}

// ─── Speed Button ─────────────────────────────────────────────────────────────

class _SpeedButton extends StatelessWidget {
  final double speed;
  final void Function(double) onChanged;
  const _SpeedButton({required this.speed, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showSpeedMenu(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: speed != 1.0
                ? const Color(0xFF7C3AED).withOpacity(0.5)
                : Colors.transparent,
          ),
        ),
        child: Text(
          '${speed}x',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: speed != 1.0 ? const Color(0xFFA855F7) : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }

  void _showSpeedMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              const Text('Playback Speed',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              ...AppConstants.playbackSpeeds.map(
                (s) => ListTile(
                  title: Text('${s}x'),
                  trailing: speed == s
                      ? ShaderMask(
                          shaderCallback: (r) => const LinearGradient(
                            colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
                          ).createShader(r),
                          child: const Icon(Icons.check_rounded, color: Colors.white),
                        )
                      : null,
                  onTap: () { onChanged(s); Navigator.pop(ctx); },
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

// ─── Shared control widgets ───────────────────────────────────────────────────

class _VynceCtrlBtn extends StatelessWidget {
  final IconData? icon;
  final Widget? widget;
  final VoidCallback? onTap;
  final double size;
  const _VynceCtrlBtn({this.icon, this.widget, this.onTap, this.size = 26});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: widget ?? Icon(icon, size: size, color: const Color(0xFF6B7280)),
      ),
    );
  }
}

class _IconToggle extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _IconToggle({required this.icon, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: active
            ? ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
                ).createShader(r),
                child: Icon(icon, size: 24, color: Colors.white),
              )
            : Icon(icon, size: 24, color: const Color(0xFF4B5563)),
      ),
    );
  }
}
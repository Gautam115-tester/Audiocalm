// lib/core/widgets/splash_screen.dart
// VYNCE SPLASH — Purple/Cyan identity with expanding rings

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

// ─── Stage definitions ────────────────────────────────────────────────────────

class _Stage {
  final String label;
  final double pct;
  const _Stage(this.label, this.pct);
}

const List<_Stage> _kStages = [
  _Stage('Initializing storage',         8),
  _Stage('Registering adapters',        16),
  _Stage('Opening storage boxes',       28),
  _Stage('Loading download registry',   38),
  _Stage('Starting audio service',      52),
  _Stage('Connecting audio handler',    64),
  _Stage('Restoring playback state',    74),
  _Stage('Loading position history',    83),
  _Stage('Preparing content cache',     93),
  _Stage('Ready',                      100),
];

const List<String> _kTips = [
  'Long-press ♡ on an episode to mark it incomplete',
  'Swipe left or right on the player to skip tracks',
  'Downloads are AES-encrypted and stored securely',
  'Your listening position is saved automatically',
  'Multi-part episodes play seamlessly end to end',
  'Feel the Sound. Stories in Every Beat.',
];

// ─── SplashNotifier ───────────────────────────────────────────────────────────

class SplashNotifier {
  final _controller = StreamController<int>.broadcast();
  final List<int> _history = [];
  int _lastStage = -1;

  Stream<int> get stream => _controller.stream;
  int get lastStage => _lastStage;
  List<int> get history => List.unmodifiable(_history);

  void advance(int stageIndex) {
    _lastStage = stageIndex;
    _history.add(stageIndex);
    if (!_controller.isClosed) _controller.add(stageIndex);
  }

  void dispose() => _controller.close();
}

// ─── SplashScreen widget ──────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  final SplashNotifier notifier;
  const SplashScreen({super.key, required this.notifier});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {

  late final AnimationController _logoCtrl;
  late final AnimationController _ringsCtrl;
  late final AnimationController _glowCtrl;
  late final AnimationController _barsCtrl;
  late final AnimationController _panelCtrl;

  double _displayPct = 0;
  double _targetPct  = 0;
  String _stageLabel = 'Initializing…';
  bool   _done       = false;
  late final String _tip;
  late final Ticker _progressTicker;
  StreamSubscription<int>? _stageSub;
  final math.Random _rng = math.Random();
  final List<double> _barMaxH = [];

  @override
  void initState() {
    super.initState();
    _tip = _kTips[DateTime.now().millisecond % _kTips.length];

    for (int i = 0; i < 20; i++) {
      _barMaxH.add(5 + _rng.nextDouble() * 18);
    }

    _logoCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _panelCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _ringsCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _glowCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat(reverse: true);
    _barsCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..repeat(reverse: true);

    _logoCtrl.forward();
    _panelCtrl.forward();

    _progressTicker = createTicker((_) {
      if (!mounted) return;
      if (_displayPct < _targetPct) {
        setState(() {
          _displayPct = (_displayPct + 1.2).clamp(0.0, _targetPct);
        });
      }
    })..start();

    for (final stage in widget.notifier.history) { _onStage(stage); }
    _stageSub = widget.notifier.stream.listen(_onStage);
  }

  void _onStage(int idx) {
    if (!mounted || idx < 0 || idx >= _kStages.length) return;
    setState(() {
      _targetPct  = _kStages[idx].pct;
      _stageLabel = _kStages[idx].label;
      _done       = idx == _kStages.length - 1;
    });
  }

  @override
  void dispose() {
    _stageSub?.cancel();
    _progressTicker.dispose();
    _logoCtrl.dispose();
    _panelCtrl.dispose();
    _ringsCtrl.dispose();
    _glowCtrl.dispose();
    _barsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        alignment: Alignment.center,
        children: [
          _buildBg(),
          _buildRings(),
          _buildFloorGlow(),
          _buildLogo(),
          _buildPanel(),
        ],
      ),
    );
  }

  Widget _buildBg() => Container(
    decoration: const BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(0, -0.2),
        radius: 1.2,
        colors: [Color(0xFF0E0520), Color(0xFF050510), Colors.black],
        stops: [0.0, 0.5, 1.0],
      ),
    ),
  );

  Widget _buildRings() => AnimatedBuilder(
    animation: _ringsCtrl,
    builder: (_, __) => CustomPaint(
      size: Size.infinite,
      painter: _VynceRingsPainter(_ringsCtrl.value),
    ),
  );

  Widget _buildFloorGlow() => Positioned(
    bottom: -60,
    child: AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, __) {
        final t = _glowCtrl.value;
        return Container(
          width: 420,
          height: 160,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [
                Color.fromRGBO(124, 58, 237, 0.08 + t * 0.06),
                Color.fromRGBO(6, 182, 212, 0.04 + t * 0.04),
                Colors.transparent,
              ],
              stops: const [0.0, 0.5, 1.0],
              radius: 0.6,
            ),
            borderRadius: BorderRadius.circular(210),
          ),
        );
      },
    ),
  );

  Widget _buildLogo() => Positioned(
    top: 0, bottom: 220, left: 0, right: 0,
    child: Center(
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOut),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOut)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // V logo with glow
              AnimatedBuilder(
                animation: _glowCtrl,
                builder: (_, child) {
                  final g = _glowCtrl.value;
                  return Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color.fromRGBO(168, 85, 247, 0.5 + g * 0.3),
                          blurRadius: 40 + g * 30,
                        ),
                        BoxShadow(
                          color: Color.fromRGBO(6, 182, 212, 0.2 + g * 0.15),
                          blurRadius: 80 + g * 40,
                        ),
                      ],
                    ),
                    child: child,
                  );
                },
                child: Image.asset(
                  'assets/icons/logo.png',
                  width: 130,
                  height: 130,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => _VynceFallbackLogo(glow: _glowCtrl),
                ),
              ),
              const SizedBox(height: 18),
              // App name
              AnimatedBuilder(
                animation: _glowCtrl,
                builder: (_, __) {
                  final g = _glowCtrl.value;
                  return ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      colors: [Color(0xFFA855F7), Color(0xFF06B6D4)],
                    ).createShader(r),
                    child: Text(
                      'VYNCE',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 8,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Color.fromRGBO(168, 85, 247, 0.6 + g * 0.3),
                            blurRadius: 20 + g * 16,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              Text(
                'FEEL  THE  SOUND',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 5,
                  color: const Color(0xFF7C3AED).withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildPanel() {
    final pct = _displayPct.round();
    final accentColor = _done ? const Color(0xFFADD8E6) : const Color(0xFF06B6D4);

    return Positioned(
      bottom: 24,
      left: 36,
      right: 36,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOut),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _VynceBars(ctrl: _barsCtrl, maxHeights: _barMaxH),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.3),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: Text(
                      _done ? '✓  $_stageLabel' : _stageLabel,
                      key: ValueKey(_stageLabel),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 1.5,
                        color: _done
                            ? const Color(0xFFC4B5FD).withOpacity(0.9)
                            : const Color(0xFF7C3AED).withOpacity(0.7),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 300),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: accentColor,
                    shadows: [
                      Shadow(color: accentColor.withOpacity(0.6), blurRadius: 12),
                    ],
                  ),
                  child: Text('$pct%'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _VynceProgressBar(pct: _displayPct / 100.0, done: _done),
            const SizedBox(height: 7),
            _SegmentTicks(pct: _displayPct / 100.0, count: 20),
            const SizedBox(height: 12),
            Text(
              '💡  $_tip',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w300,
                letterSpacing: 0.4,
                color: const Color(0xFF7C3AED).withOpacity(0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Rings painter ────────────────────────────────────────────────────────────

class _VynceRingsPainter extends CustomPainter {
  final double t;
  _VynceRingsPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const ringCount = 4;
    const maxRadius = 320.0;
    const minRadius = 80.0;

    for (int i = 0; i < ringCount; i++) {
      final phase   = (t + i / ringCount) % 1.0;
      final eased   = 1 - math.pow(1 - phase, 2).toDouble();
      final radius  = minRadius + (maxRadius - minRadius) * eased;
      final opacity = (1 - phase) * (phase < 0.15 ? phase / 0.15 : 1.0) * 0.4;
      if (opacity <= 0) continue;

      // Alternate purple and cyan rings
      final Color ringColor = i.isEven
          ? Color.fromRGBO(168, 85, 247, opacity.clamp(0, 1))
          : Color.fromRGBO(6, 182, 212, (opacity * 0.7).clamp(0, 1));

      canvas.drawCircle(
        Offset(cx, cy),
        radius,
        Paint()
          ..color = ringColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }
  }

  @override
  bool shouldRepaint(_VynceRingsPainter old) => old.t != t;
}

// ─── Bars ──────────────────────────────────────────────────────────────────────

class _VynceBars extends StatelessWidget {
  final AnimationController ctrl;
  final List<double> maxHeights;
  const _VynceBars({required this.ctrl, required this.maxHeights});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(maxHeights.length, (i) {
          final phase  = (ctrl.value + i / maxHeights.length) % 1.0;
          final factor = (math.sin(phase * math.pi)).clamp(0.15, 1.0);
          final h      = (maxHeights[i] * factor).clamp(3.0, 24.0);
          // gradient from purple to cyan based on position
          final t = i / (maxHeights.length - 1);
          final r = (168 - (168 - 6) * t).round();
          final g = (85  + (182 - 85) * t).round();
          final b = (247 - (247 - 212) * t).round();

          return Container(
            width: 3,
            height: h,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
              color: Color.fromRGBO(r, g, b, 0.9),
            ),
          );
        }),
      ),
    );
  }
}

// ─── Progress bar ─────────────────────────────────────────────────────────────

class _VynceProgressBar extends StatelessWidget {
  final double pct;
  final bool done;
  const _VynceProgressBar({required this.pct, required this.done});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final totalW = constraints.maxWidth;
      final fillW  = totalW * pct.clamp(0.0, 1.0);

      return Stack(clipBehavior: Clip.none, children: [
        Container(
          height: 3,
          width: totalW,
          decoration: BoxDecoration(
            color: const Color(0xFF7C3AED).withOpacity(0.1),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          height: 3,
          width: fillW,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: done
                ? const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFF06B6D4)])
                : const LinearGradient(
                    colors: [Color(0xFF3B0764), Color(0xFF7C3AED), Color(0xFF06B6D4)],
                    stops: [0.0, 0.6, 1.0],
                  ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7C3AED).withOpacity(0.5),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        if (fillW > 4)
          Positioned(
            left: fillW - 5,
            top: -3,
            child: Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF06B6D4),
                boxShadow: [
                  BoxShadow(color: Color(0xFF06B6D4), blurRadius: 8, spreadRadius: 1),
                ],
              ),
            ),
          ),
      ]);
    });
  }
}

// ─── Segment ticks ─────────────────────────────────────────────────────────────

class _SegmentTicks extends StatelessWidget {
  final double pct;
  final int count;
  const _SegmentTicks({required this.pct, required this.count});

  @override
  Widget build(BuildContext context) {
    final doneTicks = (pct * count).floor();
    return Row(
      children: List.generate(count, (i) {
        final lit = i < doneTicks;
        final t = i / (count - 1);
        return Expanded(
          child: Container(
            height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: lit
                  ? Color.fromRGBO(
                      (168 + (6 - 168) * t).round(),
                      (85  + (182 - 85) * t).round(),
                      (247 - (247 - 212) * t).round(),
                      0.7,
                    )
                  : const Color(0xFF7C3AED).withOpacity(0.1),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      }),
    );
  }
}

// ─── Fallback V logo ──────────────────────────────────────────────────────────

class _VynceFallbackLogo extends StatelessWidget {
  final AnimationController glow;
  const _VynceFallbackLogo({required this.glow});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: glow,
    builder: (_, __) => CustomPaint(
      size: const Size(130, 130),
      painter: _VLogoFallbackPainter(glow.value),
    ),
  );
}

class _VLogoFallbackPainter extends CustomPainter {
  final double t;
  _VLogoFallbackPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFC026D3), Color(0xFF7C3AED), Color(0xFF06B6D4)],
        stops: [0.0, 0.45, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    // Draw V shape
    final path = Path()
      ..moveTo(cx - 40, cy - 30)
      ..lineTo(cx - 14, cy - 30)
      ..lineTo(cx, cy + 22)
      ..lineTo(cx + 14, cy - 30)
      ..lineTo(cx + 40, cy - 30)
      ..lineTo(cx, cy + 46)
      ..close();

    // Glow
    canvas.drawPath(path, Paint()
      ..shader = paint.shader
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 12 + t * 8)
      ..style = PaintingStyle.fill);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_VLogoFallbackPainter old) => old.t != t;
}
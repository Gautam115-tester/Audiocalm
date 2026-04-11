// lib/core/widgets/splash_screen.dart
//
// Full-screen animated splash shown during app startup.
// Displays the Audio Calm logo, animated progress bar, real init stage labels,
// live percentage counter, audio visualizer bars, and floating sparkles.
//
// HOW IT WORKS:
//   main.dart creates a SplashNotifier and passes its stream to this widget.
//   As each real init step completes in main(), it calls:
//       splashNotifier.advance(index)
//   The splash animates smoothly to the corresponding percentage and label.
//
// USAGE:
//   // In AudioCalmApp or a router wrapper:
//   if (!_initDone) return SplashScreen(notifier: widget.splashNotifier);
//
// STAGES (must match _kStages list below AND calls in main.dart):
//   0  → Initializing Hive                  →  8%
//   1  → Registering adapters               → 16%
//   2  → Opening storage boxes              → 28%
//   3  → Loading download registry          → 38%
//   4  → Starting audio service             → 52%
//   5  → Connecting audio handler           → 64%
//   6  → Restoring playback state           → 74%
//   7  → Loading position history           → 83%
//   8  → Preparing content cache            → 93%
//   9  → Ready                              → 100%

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

// ─── Stage definitions ────────────────────────────────────────────────────────

class _Stage {
  final String label;
  final double pct; // 0..100
  const _Stage(this.label, this.pct);
}

const List<_Stage> _kStages = [
  _Stage('Initializing Hive database',      8),
  _Stage('Registering adapters',            16),
  _Stage('Opening storage boxes',           28),
  _Stage('Loading download registry',       38),
  _Stage('Starting audio service',          52),
  _Stage('Connecting audio handler',        64),
  _Stage('Restoring playback state',        74),
  _Stage('Loading position history',        83),
  _Stage('Preparing content cache',         93),
  _Stage('Ready',                          100),
];

const List<String> _kTips = [
  'Long-press ♡ on an episode to mark it incomplete',
  'Swipe left or right on the player to skip tracks',
  'Tap EQ on any song to tune your sound profile',
  'Downloads are AES-encrypted and stored securely',
  'Your listening position is saved automatically',
  'Multi-part episodes play seamlessly end to end',
];

// ─── SplashNotifier ───────────────────────────────────────────────────────────
// Create one instance in main() and pass it to both the splash widget
// and to your init functions so they can call advance().

class SplashNotifier {
  final _controller = StreamController<int>.broadcast();

  // Buffer every event so the widget can replay them if it mounts late.
  final List<int> _history = [];
  int _lastStage = -1;

  Stream<int> get stream => _controller.stream;

  /// The most recent stage index fired (or -1 if none yet).
  int get lastStage => _lastStage;

  /// All stage indices fired so far (in order).
  List<int> get history => List.unmodifiable(_history);

  /// Call this as each init step completes. [stageIndex] = 0..9.
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

  // ── Animation controllers ──────────────────────────────────────────────────
  late final AnimationController _logoCtrl;   // logo fade+rise (one-shot)
  late final AnimationController _panelCtrl;  // bottom panel fade (one-shot)
  late final AnimationController _ringsCtrl;  // expanding ring loop
  late final AnimationController _glowCtrl;   // logo glow breathe loop
  late final AnimationController _barsCtrl;   // audio bars bounce loop

  // ── Progress state ─────────────────────────────────────────────────────────
  double _displayPct = 0;   // what's shown on screen (animated)
  double _targetPct  = 0;   // what we're animating toward
  String _stageLabel = 'Initializing…';
  bool   _done = false;

  // ── Tip ────────────────────────────────────────────────────────────────────
  late final String _tip;

  // ── Smooth progress ticker ─────────────────────────────────────────────────
  late final Ticker _progressTicker;

  // ── Stage subscription ─────────────────────────────────────────────────────
  StreamSubscription<int>? _stageSub;

  // ── Bar heights (randomised once) ─────────────────────────────────────────
  final List<double> _barMaxH = [];
  final math.Random _rng = math.Random();

  @override
  void initState() {
    super.initState();

    // Pick tip
    _tip = _kTips[DateTime.now().millisecond % _kTips.length];

    // Build bar heights
    const barCount = 18;
    for (int i = 0; i < barCount; i++) {
      _barMaxH.add(6 + _rng.nextDouble() * 18);
    }

    // Controllers
    _logoCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    _panelCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _ringsCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _glowCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..repeat(reverse: true);
    _barsCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);

    // Start logo animation; also start panel immediately so it's visible
    // even if the logo takes a full second to animate in.
    _logoCtrl.forward();
    _panelCtrl.forward();

    // Smooth progress ticker: nudges _displayPct toward _targetPct each frame
    _progressTicker = createTicker((_) {
      if (!mounted) return;
      if (_displayPct < _targetPct) {
        setState(() {
          _displayPct = (_displayPct + 1.0).clamp(0.0, _targetPct);
        });
      }
    })..start();

    // ── Replay any stage events that fired BEFORE this widget mounted ──────
    // main() starts init before runApp(), so several stages may already be
    // done by the time initState() runs. Replay them all synchronously, then
    // subscribe for future events.
    for (final stage in widget.notifier.history) {
      _onStage(stage);
    }
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

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        alignment: Alignment.center,
        children: [
          _buildBackground(),
          _buildRings(),
          _buildFloorGlow(),
          _buildSparkles(),
          _buildLogoSection(),
          _buildBottomPanel(),
        ],
      ),
    );
  }

  // ── Background ─────────────────────────────────────────────────────────────
  Widget _buildBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.25),
          radius: 1.3,
          colors: [
            Color(0xFF0B2214),
            Color(0xFF040C07),
            Colors.black,
          ],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
    );
  }

  // ── Expanding rings ────────────────────────────────────────────────────────
  Widget _buildRings() {
    return AnimatedBuilder(
      animation: _ringsCtrl,
      builder: (_, __) => CustomPaint(
        size: Size.infinite,
        painter: _RingsPainter(_ringsCtrl.value),
      ),
    );
  }

  // ── Floor glow ─────────────────────────────────────────────────────────────
  Widget _buildFloorGlow() {
    return Positioned(
      bottom: -60,
      child: AnimatedBuilder(
        animation: _glowCtrl,
        builder: (_, __) {
          final intensity = 0.12 + _glowCtrl.value * 0.10;
          return Container(
            width: 420,
            height: 180,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  Color.fromRGBO(0, 200, 60, intensity),
                  Colors.transparent,
                ],
                radius: 0.65,
              ),
              borderRadius: BorderRadius.circular(210),
            ),
          );
        },
      ),
    );
  }

  // ── Floating sparkles ──────────────────────────────────────────────────────
  Widget _buildSparkles() {
    return const _SparkleField();
  }

  // ── Logo + brand ───────────────────────────────────────────────────────────
  Widget _buildLogoSection() {
    return Positioned(
      top: 0, bottom: 220, left: 0, right: 0,
      child: Center(
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOut)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo with glow
                AnimatedBuilder(
                  animation: _glowCtrl,
                  builder: (_, child) {
                    final g = _glowCtrl.value;
                    return Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color.fromRGBO(0, 255, 80, 0.45 + g * 0.35),
                            blurRadius: 35 + g * 35,
                            spreadRadius: 0,
                          ),
                          BoxShadow(
                            color: Color.fromRGBO(0, 180, 50, 0.15 + g * 0.12),
                            blurRadius: 80 + g * 40,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                      child: child,
                    );
                  },
                  child: Image.asset(
                    'assets/icons/logo.png',
                    width: 160,
                    height: 160,
                    fit: BoxFit.contain,
                    // Graceful fallback if asset path differs
                    errorBuilder: (_, __, ___) => _FallbackLogo(glow: _glowCtrl),
                  ),
                ),

                const SizedBox(height: 20),

                // Brand name
                AnimatedBuilder(
                  animation: _glowCtrl,
                  builder: (_, __) {
                    final g = _glowCtrl.value;
                    return Text(
                      'AUDIO CALM',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 5,
                        color: const Color(0xFFDDFFE8),
                        shadows: [
                          Shadow(
                            color: Color.fromRGBO(0, 255, 80, 0.55 + g * 0.35),
                            blurRadius: 18 + g * 18,
                          ),
                        ],
                      ),
                    );
                  },
                ),

                const SizedBox(height: 7),

                Text(
                  'SOUND  ·  STILLNESS  ·  SLEEP',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 5,
                    color: const Color(0xFF55CC77).withOpacity(0.45),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Bottom loading panel ───────────────────────────────────────────────────
  Widget _buildBottomPanel() {
    final pct = _displayPct.round();
    final accentColor = _done
        ? const Color(0xFFAFFFCA)
        : const Color(0xFF00FF55);

    return Positioned(
      bottom: 24,
      left: 36,
      right: 36,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOut),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [

            // ── Audio visualizer bars ──────────────────────────────────────
            _AudioBars(ctrl: _barsCtrl, maxHeights: _barMaxH),

            const SizedBox(height: 14),

            // ── Stage label + percentage ───────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
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
                      _done ? '✓  ${_stageLabel}' : _stageLabel,
                      key: ValueKey(_stageLabel),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 1.8,
                        color: _done
                            ? const Color(0xFFAFFFCA).withOpacity(0.9)
                            : const Color(0xFF55CC77).withOpacity(0.75),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                // Percentage
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 300),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: accentColor,
                    shadows: [
                      Shadow(
                        color: accentColor.withOpacity(0.7),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Text('$pct%'),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // ── Progress bar ───────────────────────────────────────────────
            _ProgressBar(
              pct: _displayPct / 100.0,
              done: _done,
              accentColor: accentColor,
            ),

            const SizedBox(height: 7),

            // ── Segment ticks (20 marks) ───────────────────────────────────
            _SegmentTicks(pct: _displayPct / 100.0, count: 20),

            const SizedBox(height: 13),

            // ── Tip text ───────────────────────────────────────────────────
            Text(
              '💡  $_tip',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w300,
                letterSpacing: 0.4,
                color: const Color(0xFF3CA050).withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── _RingsPainter ────────────────────────────────────────────────────────────
// Draws 4 concentric expanding rings, each offset in phase.

class _RingsPainter extends CustomPainter {
  final double t; // 0..1, loops
  _RingsPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    const ringCount = 4;
    const maxRadius = 340.0;
    const minRadius = 90.0;
    final radii = [minRadius, 150.0, 230.0, 310.0];

    for (int i = 0; i < ringCount; i++) {
      final phase = (t + i / ringCount) % 1.0;
      // ease-out: fast expand, slow fade
      final eased = 1 - math.pow(1 - phase, 2).toDouble();
      final radius = minRadius + (maxRadius - minRadius) * eased;
      final opacity = (1 - phase) * (phase < 0.15 ? phase / 0.15 : 1.0) * 0.35;

      if (opacity <= 0) continue;

      final paint = Paint()
        ..color = const Color(0xFF00DD44).withOpacity(opacity.clamp(0, 1))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;

      canvas.drawCircle(Offset(cx, cy), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.t != t;
}

// ─── _AudioBars ───────────────────────────────────────────────────────────────
// Bouncing bars driven by _barsCtrl. Each bar has an independent phase offset
// so they don't all move in sync.

class _AudioBars extends StatelessWidget {
  final AnimationController ctrl;
  final List<double> maxHeights;

  const _AudioBars({required this.ctrl, required this.maxHeights});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(maxHeights.length, (i) {
            // Each bar uses a shifted sine so they're out of phase
            final phase = (ctrl.value + i / maxHeights.length) % 1.0;
            final factor = (math.sin(phase * math.pi)).clamp(0.15, 1.0);
            final h = (maxHeights[i] * factor).clamp(3.0, 26.0);

            final isActive = h > 12;
            return Container(
              width: 3,
              height: h,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    const Color(0xFF00BB44),
                    isActive ? const Color(0xFFAAFFCC) : const Color(0xFF00FF55),
                  ],
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: const Color(0xFF00FF55).withOpacity(0.4),
                          blurRadius: 4,
                        )
                      ]
                    : null,
              ),
            );
          }),
        );
      },
    );
  }
}

// ─── _ProgressBar ─────────────────────────────────────────────────────────────

class _ProgressBar extends StatelessWidget {
  final double pct;        // 0..1
  final bool done;
  final Color accentColor;

  const _ProgressBar({
    required this.pct,
    required this.done,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final totalW = constraints.maxWidth;
        final fillW  = totalW * pct.clamp(0.0, 1.0);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Track
            Container(
              height: 3,
              width: totalW,
              decoration: BoxDecoration(
                color: const Color(0xFF00AA33).withOpacity(0.12),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Fill
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              height: 3,
              width: fillW,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(
                  colors: done
                      ? [const Color(0xFF00AA33), const Color(0xFFAFFFCA)]
                      : [const Color(0xFF003D18), const Color(0xFF00CC44), const Color(0xFFAAFFCC)],
                  stops: done ? null : const [0.0, 0.65, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: accentColor.withOpacity(0.6),
                    blurRadius: 6,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),

            // Leading dot
            if (fillW > 4)
              Positioned(
                left: fillW - 5,
                top: -3,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accentColor,
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withOpacity(0.8),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ─── _SegmentTicks ────────────────────────────────────────────────────────────
// 20 small tick marks below the bar, lighting up as progress advances.

class _SegmentTicks extends StatelessWidget {
  final double pct;   // 0..1
  final int count;

  const _SegmentTicks({required this.pct, required this.count});

  @override
  Widget build(BuildContext context) {
    final doneTicks = (pct * count).floor();
    return Row(
      children: List.generate(count, (i) {
        final lit = i < doneTicks;
        return Expanded(
          child: Container(
            height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: lit
                  ? const Color(0xFF00FF55).withOpacity(0.65)
                  : const Color(0xFF00AA33).withOpacity(0.12),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      }),
    );
  }
}

// ─── _SparkleField ────────────────────────────────────────────────────────────
// Static layout of floating sparkle dots. Each has its own AnimationController
// so they float independently.

class _SparkleField extends StatefulWidget {
  const _SparkleField();

  @override
  State<_SparkleField> createState() => _SparkleFieldState();
}

class _SparkleFieldState extends State<_SparkleField>
    with TickerProviderStateMixin {

  final _rng = math.Random(42); // fixed seed so layout is deterministic
  late final List<_SparkleData> _sparkles;
  late final List<AnimationController> _ctrls;
  late final List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();

    const count = 22;
    _sparkles = List.generate(count, (i) => _SparkleData(
      x:    0.05 + _rng.nextDouble() * 0.90,
      y:    0.10 + _rng.nextDouble() * 0.80,
      size: 1.5 + _rng.nextDouble() * 3.0,
      opacity: 0.3 + _rng.nextDouble() * 0.5,
    ));

    _ctrls = List.generate(count, (i) => AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 2800 + _rng.nextInt(3000)),
    ));

    _anims = _ctrls.map((c) =>
      Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: c, curve: Curves.easeInOut)),
    ).toList();

    for (int i = 0; i < count; i++) {
      Future.delayed(Duration(milliseconds: _rng.nextInt(4000)), () {
        if (mounted) _ctrls[i].repeat(reverse: true);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) { c.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;

      return Stack(
        children: List.generate(_sparkles.length, (i) {
          final s = _sparkles[i];
          return Positioned(
            left:  s.x * w - s.size / 2,
            top:   s.y * h - s.size / 2,
            child: AnimatedBuilder(
              animation: _anims[i],
              builder: (_, __) => Opacity(
                opacity: (_anims[i].value * s.opacity).clamp(0.0, 1.0),
                child: Container(
                  width:  s.size,
                  height: s.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF00FF55),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00FF55).withOpacity(0.6),
                        blurRadius: s.size * 2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      );
    });
  }
}

class _SparkleData {
  final double x, y, size, opacity;
  const _SparkleData({required this.x, required this.y, required this.size, required this.opacity});
}

// ─── _FallbackLogo ────────────────────────────────────────────────────────────
// Shown if assets/images/logo.png can't be loaded.
// Recreates the clam+headphones+orb shape in pure Flutter widgets.

class _FallbackLogo extends StatelessWidget {
  final AnimationController glow;
  const _FallbackLogo({required this.glow});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: glow,
      builder: (_, __) => CustomPaint(
        size: const Size(160, 160),
        painter: _FallbackLogoPainter(glow.value),
      ),
    );
  }
}

class _FallbackLogoPainter extends CustomPainter {
  final double glowT;
  _FallbackLogoPainter(this.glowT);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 8;

    // Shell body
    final shellPaint = Paint()
      ..color = const Color(0xFF0F4020)
      ..style = PaintingStyle.fill;
    final shellStroke = Paint()
      ..color = const Color(0xFF00CC44)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final shellPath = Path()
      ..moveTo(cx - 60, cy - 5)
      ..quadraticBezierTo(cx - 50, cy - 50, cx, cy - 55)
      ..quadraticBezierTo(cx + 50, cy - 50, cx + 60, cy - 5)
      ..quadraticBezierTo(cx + 55, cy + 35, cx + 35, cy + 45)
      ..quadraticBezierTo(cx, cy + 55, cx - 35, cy + 45)
      ..quadraticBezierTo(cx - 55, cy + 35, cx - 60, cy - 5)
      ..close();
    canvas.drawPath(shellPath, shellPaint);
    canvas.drawPath(shellPath, shellStroke);

    // Headphone band
    final hpPaint = Paint()
      ..color = const Color(0xFF00AA33)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, cy - 20), width: 130, height: 70),
      math.pi, math.pi, false, hpPaint,
    );

    // Headphone cups
    final cupPaint = Paint()..color = const Color(0xFF005520);
    canvas.drawCircle(Offset(cx - 65, cy - 20), 10, cupPaint);
    canvas.drawCircle(Offset(cx + 65, cy - 20), 10, cupPaint);
    final cupStroke = Paint()
      ..color = const Color(0xFF00DD55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(Offset(cx - 65, cy - 20), 10, cupStroke);
    canvas.drawCircle(Offset(cx + 65, cy - 20), 10, cupStroke);

    // EQ bars inside shell
    final barPaint = Paint()
      ..color = const Color(0xFF00FF55)
      ..style = PaintingStyle.fill;
    const barHeights = [10.0, 16.0, 22.0, 18.0, 12.0, 20.0, 14.0];
    const barW = 5.0;
    final startX = cx - (barHeights.length * (barW + 3)) / 2;
    for (int i = 0; i < barHeights.length; i++) {
      final bx = startX + i * (barW + 3);
      final bh = barHeights[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(bx, cy - 28 - bh / 2, barW, bh),
          const Radius.circular(2),
        ),
        barPaint,
      );
    }

    // Glowing orb
    final glowRadius = 12.0 + glowT * 3.0;
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white, const Color(0xFF00FF55), const Color(0xFF004020)],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy + 18), radius: glowRadius));
    canvas.drawCircle(Offset(cx, cy + 18), glowRadius, glowPaint);

    // Orb outer glow
    final orbGlowPaint = Paint()
      ..color = const Color(0xFF00FF55).withOpacity(0.5 + glowT * 0.35)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + glowT * 8);
    canvas.drawCircle(Offset(cx, cy + 18), glowRadius * 1.4, orbGlowPaint);
  }

  @override
  bool shouldRepaint(_FallbackLogoPainter old) => old.glowT != glowT;
}
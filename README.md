# 🎧 Audio Calm bulid using AI — Flutter App

A production-grade mindfulness audio streaming app built with Flutter + Riverpod + Clean Architecture. Streams from a Node.js/Telegram backend. Full offline support with AES-256-CBC encryption.

---

## Quick Start

### Prerequisites
- Flutter SDK ≥ 3.2.0
- Android Studio / VS Code with Flutter extension
- Android device or emulator (API 21+)

### 1. Install dependencies
```bash
flutter pub get
```

### 2. Configure backend URL
Edit `lib/core/constants/api_constants.dart`:
```dart
static const String baseUrl = 'https://your-audio-calm-api.onrender.com';
```

### 3. Run the app
```bash
flutter run
```

---

## Architecture

```
lib/
├── main.dart                          # Bootstrap: Hive, AudioService, Riverpod
├── core/
│   ├── constants/                     # API URLs, box names, channels
│   ├── di/                            # Riverpod DI providers
│   ├── errors/                        # Typed exception hierarchy
│   ├── network/                       # Dio HTTP client
│   ├── router/                        # go_router config + player dedup guard
│   ├── theme/                         # Material 3 dark palette (Sora font)
│   └── widgets/                       # AppShell, MiniPlayer, shared widgets
└── features/
    ├── home/                          # Home screen + Continue Listening
    ├── calm_stories/                  # Series list, detail, episode list
    ├── calm_music/                    # Album grid, detail, song list
    ├── player/                        # Full player, mini player, EQ sheet
    │   ├── services/audio_handler.dart    # AudioService background handler
    │   ├── services/equalizer_service.dart # MethodChannel EQ bridge
    │   └── providers/audio_player_provider.dart
    ├── downloads/                     # AES-256 download + decrypt manager
    ├── search/                        # Full-text search
    └── favorites/                     # Hive-backed favorites
```

---

## Features Implemented

| Feature | Status |
|---|---|
| Background playback (Android/iOS notification) | ✅ |
| Lock-screen controls + artwork | ✅ |
| Bluetooth media button routing | ✅ (MainActivity.kt) |
| Headset hook / media key handling | ✅ |
| Seekbar with position restore | ✅ |
| Playback speed (0.5× – 2×) | ✅ |
| Skip forward 15s / backward 10s | ✅ |
| Swipe left/right for next/prev | ✅ |
| Loop: Off → Repeat One → Repeat All | ✅ |
| Shuffle mode | ✅ |
| AES-256-CBC download encryption | ✅ |
| Android Keystore key storage | ✅ |
| Multi-part file download + merge | ✅ |
| 4-hour decrypted temp cache | ✅ |
| Native Android Equalizer (8 presets + Custom) | ✅ |
| Continue Listening strip | ✅ |
| Shimmer loading placeholders | ✅ |
| Full-text search | ✅ |
| Per-item favourites (Hive) | ✅ |
| Mini player above nav bar | ✅ |
| Full player slide-up animation | ✅ |
| Navigation dedup guard (/player) | ✅ |
| Material 3 dark theme + Sora font | ✅ |

---

## Android Native (Bluetooth Integration)

**`android/app/src/main/kotlin/com/audiocalm/app/MainActivity.kt`**

- Extends `AudioServiceActivity` from `audio_service` plugin
- Overrides `onKeyDown` / `onKeyUp` to route all media keys (play/pause, next, prev, headset hook, fast-forward, rewind, stop) to `AudioService`
- All media key handling is delegated via `super.onKeyDown/onKeyUp()` so `audio_service` handles the actual response

**`EqualizerManager.kt`**
- Singleton object managing `android.media.audiofx.Equalizer`
- Receives calls from Flutter via `EQUALIZER_CHANNEL`
- Supports: `init`, `setEnabled`, `setBandLevel`, `getBandLevel`, `getProperties`, `release`

**Channel names (must match Dart constants):**
```
com.example.audio_series_app/equalizer
com.example.audio_series_app/file_access
com.example.audio_series_app/music_scanner
```

---

## Environment Variables

Create `lib/core/constants/api_constants.dart` with your backend URL:
```dart
static const String baseUrl = 'https://YOUR_RENDER_URL.onrender.com';
```

---

## Known Limitations

- iOS Equalizer returns no-op (MethodChannel not implemented on iOS)
- Telegram Bot API download limit is 20 MB — backend multi-part system handles this
- Render free tier has ~30–60s cold-start; use UptimeRobot to keep it alive
- AES-256-CBC uses per-file random IV (production-ready)

---

## Dependencies

See `pubspec.yaml` for full list. Key packages:
- `just_audio` ^0.9.40 — audio engine
- `audio_service` ^0.18.15 — background playback
- `flutter_riverpod` ^2.5.1 — state management
- `go_router` ^14.2.7 — navigation
- `hive_flutter` ^1.1.0 — local storage
- `encrypt` ^5.0.3 — AES-256-CBC
- `flutter_secure_storage` ^9.2.2 — key storage
- `dio` ^5.7.0 — HTTP
- `shimmer` ^3.0.0 — loading UI
- `google_fonts` ^6.2.1 — Sora typeface

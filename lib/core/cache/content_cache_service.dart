// lib/core/cache/content_cache_service.dart
//
// Persists album/series metadata between sessions so the app shows content
// INSTANTLY on relaunch — no waiting for the network.
//
// Strategy: stale-while-revalidate
//   1. On app start → return cached data immediately (feels instant)
//   2. In background → fetch fresh data from API
//   3. When fresh data arrives → update cache + notify providers
//
// Cache keys:
//   all_albums_with_songs → JSON string of full album+songs batch
//   all_series_with_episodes → JSON string of full series+episodes batch
//   cache_timestamp_albums → Unix ms timestamp
//   cache_timestamp_series → Unix ms timestamp

import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

const _kBoxName = 'content_cache_box';
const _kAlbumsKey = 'all_albums_with_songs';
const _kSeriesKey = 'all_series_with_episodes';
const _kAlbumsTs = 'cache_timestamp_albums';
const _kSeriesTs = 'cache_timestamp_series';

// Cache is considered fresh for 5 minutes — after that, always revalidate.
// Stale data still shown instantly even if older.
const _kFreshDuration = Duration(minutes: 5);

class ContentCacheService {
  ContentCacheService._();

  static Future<void> init() async {
    if (!Hive.isBoxOpen(_kBoxName)) {
      await Hive.openBox(_kBoxName);
    }
  }

  static Box get _box => Hive.box(_kBoxName);

  // ── Albums ────────────────────────────────────────────────────────────────

  static List<Map<String, dynamic>>? getCachedAlbums() {
    try {
      final raw = _box.get(_kAlbumsKey) as String?;
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveAlbums(List<Map<String, dynamic>> data) async {
    try {
      await _box.put(_kAlbumsKey, jsonEncode(data));
      await _box.put(_kAlbumsTs, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static bool isAlbumsCacheFresh() {
    try {
      final ts = _box.get(_kAlbumsTs) as int?;
      if (ts == null) return false;
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(ts),
      );
      return age < _kFreshDuration;
    } catch (_) {
      return false;
    }
  }

  // ── Series ────────────────────────────────────────────────────────────────

  static List<Map<String, dynamic>>? getCachedSeries() {
    try {
      final raw = _box.get(_kSeriesKey) as String?;
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSeries(List<Map<String, dynamic>> data) async {
    try {
      await _box.put(_kSeriesKey, jsonEncode(data));
      await _box.put(_kSeriesTs, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static bool isSeriesCacheFresh() {
    try {
      final ts = _box.get(_kSeriesTs) as int?;
      if (ts == null) return false;
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(ts),
      );
      return age < _kFreshDuration;
    } catch (_) {
      return false;
    }
  }

  // ── Clear ─────────────────────────────────────────────────────────────────

  static Future<void> clearAll() async {
    try {
      await _box.clear();
    } catch (_) {}
  }
}
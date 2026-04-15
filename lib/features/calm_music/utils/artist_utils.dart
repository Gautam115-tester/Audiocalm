// lib/features/calm_music/utils/artist_utils.dart
//
// Splits combined artist strings (e.g. "A.R. Rahman, Arijit Singh & KK")
// into individual artist names, normalises them, and deduplicates with a
// simple Levenshtein fuzzy-match so minor typos collapse to one entry.

class ArtistUtils {
  ArtistUtils._();

  // Separators used between artist names in filenames / tags.
  static final _separatorRe = RegExp(
    r'\s*(?:,|&amp;|&|\bfeat\.?\b|\bft\.?\b|\bx\b|\bvs\.?\b|\+)\s*',
    caseSensitive: false,
  );

  // Characters to strip before normalising (brackets, featured markers, etc.)
  static final _junkRe = RegExp(r'[\(\)\[\]]');

  /// Split a raw artist string into individual, trimmed names.
  /// Returns an empty list if [raw] is null or blank.
  static List<String> split(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw
        .split(_separatorRe)
        .map((s) => s.replaceAll(_junkRe, '').trim())
        .where((s) => s.length > 1)
        .toList();
  }

  /// Normalise a name into a lookup key:
  /// lowercase, collapse whitespace, strip trailing punctuation.
  static String normalise(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[^\w\s\.]'), '')
        .trim();
  }

  /// Title-case a normalised name (first letter of each word uppercased).
  static String toDisplayName(String name) {
    return name
        .split(' ')
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  // ── Levenshtein distance (max depth capped at 3 for speed) ─────────────────

  static int _lev(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    // Cap comparison length to keep it O(1) for long strings.
    final la = a.length > 30 ? a.substring(0, 30) : a;
    final lb = b.length > 30 ? b.substring(0, 30) : b;
    final prev = List<int>.generate(lb.length + 1, (i) => i);
    for (int i = 0; i < la.length; i++) {
      var prev2 = i + 1;
      for (int j = 0; j < lb.length; j++) {
        final sub = la[i] == lb[j] ? prev[j] : prev[j] + 1;
        final cur = [prev2 + 1, prev[j + 1] + 1, sub]
            .reduce((a, b) => a < b ? a : b);
        prev[j] = prev2;
        prev2 = cur;
      }
      prev[lb.length] = prev2;
    }
    return prev[lb.length];
  }

  /// Build a canonical artist registry from a list of raw album artist strings.
  ///
  /// Returns a map of:  normalised-key  →  display name (canonical spelling)
  ///
  /// Two names whose Levenshtein distance ≤ [threshold] are treated as the
  /// same artist; the *longer* of the two is kept as the canonical display name
  /// (usually the more fully-spelled version).
  static Map<String, String> buildRegistry(
    List<String?> rawArtists, {
    int threshold = 2,
  }) {
    // Step 1 – collect all individual names
    final allNames = <String>[];
    for (final raw in rawArtists) {
      allNames.addAll(split(raw));
    }

    // Step 2 – normalise and deduplicate with fuzzy matching
    // canonicalMap: normalisedKey → displayName
    final canonicalMap = <String, String>{};

    for (final name in allNames) {
      final key = normalise(name);
      if (key.isEmpty) continue;

      // Exact key match — already registered
      if (canonicalMap.containsKey(key)) continue;

      // Fuzzy match against existing keys
      String? matchedKey;
      for (final existingKey in canonicalMap.keys) {
        if (_lev(key, existingKey) <= threshold) {
          matchedKey = existingKey;
          break;
        }
      }

      if (matchedKey != null) {
        // Prefer the longer (more fully-spelled) display name
        final existing = canonicalMap[matchedKey]!;
        if (name.length > existing.length) {
          canonicalMap[matchedKey] = name;
        }
        // Also map the new key to the same canonical entry
        canonicalMap[key] = canonicalMap[matchedKey]!;
      } else {
        canonicalMap[key] = name;
      }
    }

    return canonicalMap;
  }

  /// Resolve an artist name to its canonical display form using [registry].
  /// If no fuzzy match is found, returns [name] title-cased.
  static String resolve(String name, Map<String, String> registry, {int threshold = 2}) {
    final key = normalise(name);
    if (registry.containsKey(key)) return registry[key]!;
    for (final entry in registry.entries) {
      if (_lev(key, entry.key) <= threshold) return entry.value;
    }
    return toDisplayName(name);
  }
}
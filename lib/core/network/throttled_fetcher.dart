// lib/core/network/throttled_fetcher.dart
//
// Utility that runs async tasks with a concurrency cap.
//
// WHY THIS EXISTS:
// The music/stories screens were firing all album detail + songs requests at
// once via Future.wait([...all albums...]). With 11 albums that's 22 parallel
// requests. Render's free-tier server (which cold-starts slowly) can't serve
// 22 concurrent requests within 15 s → mass timeouts visible in the logs.
//
// USAGE:
//   final results = await ThrottledFetcher.run(
//     tasks: albumIds.map((id) => () => fetchAlbumDetail(id)).toList(),
//     concurrency: 3, // at most 3 in-flight at once
//   );
//
// Results are returned in the same order as [tasks], regardless of completion
// order. Failed tasks return null (or you can pass onError to handle them).

import 'dart:async';

class ThrottledFetcher {
  ThrottledFetcher._();

  /// Run [tasks] with at most [concurrency] running simultaneously.
  ///
  /// [concurrency] defaults to 3 — a safe value for free-tier Render backends.
  /// Returns results in the same index order as [tasks].
  /// If a task throws, its slot in the result list is null (unless you provide
  /// [onError] to convert errors to values).
  static Future<List<T?>> run<T>({
    required List<Future<T> Function()> tasks,
    int concurrency = 3,
    T? Function(Object error, int index)? onError,
  }) async {
    if (tasks.isEmpty) return [];

    final results = List<T?>.filled(tasks.length, null);
    int nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= tasks.length) return;

        try {
          results[index] = await tasks[index]();
        } catch (e) {
          results[index] = onError?.call(e, index);
        }
      }
    }

    // Spawn exactly [concurrency] worker coroutines and wait for all to finish.
    final workerCount = concurrency.clamp(1, tasks.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));

    return results;
  }

  /// Convenience: run tasks and filter out null results.
  static Future<List<T>> runNonNull<T>({
    required List<Future<T> Function()> tasks,
    int concurrency = 3,
  }) async {
    final results = await run<T>(tasks: tasks, concurrency: concurrency);
    return results.whereType<T>().toList();
  }
}
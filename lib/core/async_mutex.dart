import 'dart:async';

/// Single-lane async mutex to ensure LiteRT-LM native calls (prewarm, inference,
/// idle compaction) never run concurrently on the same C++ runtime thread.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;

    return previous.then((_) => action()).whenComplete(() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
  }
}

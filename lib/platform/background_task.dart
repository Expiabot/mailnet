import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../mail/models.dart';

/// Holds a foreground service open for the duration of a bulk deletion.
///
/// Android otherwise freezes or kills the app the moment it leaves the screen,
/// and a five-thousand message run stops halfway. Every call is a no-op on
/// other platforms and never throws: losing the notification must not lose the
/// deletion.
class BackgroundTask {
  const BackgroundTask();

  static const _channel = MethodChannel('fr.mailnet/background');

  bool get _supported => !kIsWeb && Platform.isAndroid;

  /// Fires the Android 13+ notification prompt if it has not been answered yet.
  /// Call it before the user is in the middle of something.
  Future<void> prepare() => _invoke('requestNotificationPermission');

  Future<void> start(DeleteProgress progress) => _invoke('start', progress);

  Future<void> update(DeleteProgress progress) => _invoke('update', progress);

  Future<void> stop() => _invoke('stop');

  Future<void> _invoke(String method, [DeleteProgress? progress]) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method, {
        if (progress != null) 'deleted': progress.deleted,
        if (progress != null) 'total': progress.total,
      });
    } catch (e) {
      debugPrint('[mailnet] service de premier plan indisponible ($method): $e');
    }
  }
}

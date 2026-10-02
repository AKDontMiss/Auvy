import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows the platform's native toast. The class name and `show(...)` signature are
/// kept so existing call sites don't change; `icon`, `color` and `startOffset` are
/// accepted but ignored.
class AnimatedToast {
  static const MethodChannel _channel = MethodChannel('com.auvy.app/toast');

  /// Only [text] and [long] are used. This delegates to a native toast, so `context`,
  /// `icon`, `color` and `startOffset` are accepted only so existing call sites keep
  /// compiling: styling passed here won't appear. The unused `context` still trips
  /// `use_build_context_synchronously` after an await, so prefer [message] for new
  /// code and anything after an await.
  static void show(
    BuildContext context, {
    required String text,
    IconData? icon,
    Color? color,
    Offset? startOffset,
    bool long = false,
  }) {
    _show(text, long: long);
  }

  /// Direct native toast (no BuildContext needed).
  static void message(String text, {bool long = false}) => _show(text, long: long);

  static void _show(String text, {bool long = false}) {
    if (text.trim().isEmpty) return;
    // .catchError, not try/catch: the call is not awaited, so its failure is
    // asynchronous and a synchronous catch around it never fires. A toast is
    // the least important thing in the app and must never be the reason an
    // unhandled error reaches the zone handler.
    _channel
        .invokeMethod('show', {'message': text, 'long': long})
        .catchError((_) => null);
  }
}

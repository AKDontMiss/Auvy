import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows the phone's built-in (Android) system Toast.
///
/// The old custom animated overlay UI has been REMOVED — every in-app message
/// now routes through the native Android Toast (like Spotify), so it renders
/// consistently over any screen and matches the OS look. The class name and
/// `show(...)` signature are kept so the ~60 existing call sites don't change;
/// `icon`/`color`/`startOffset` are accepted for source compatibility but are
/// ignored by the native toast.
class AnimatedToast {
  static const MethodChannel _channel = MethodChannel('com.auvy.app/toast');

  /// EVERY PARAMETER EXCEPT [text] AND [long] IS IGNORED.
  ///
  /// This delegates to a NATIVE toast, so there is no Flutter overlay to place,
  /// tint or decorate: `context`, `icon`, `color` and `startOffset` are accepted
  /// only so the ~68 existing call sites keep compiling. Two things follow, and
  /// both have already caused work:
  ///
  ///  • An icon or colour passed here does NOT appear. Do not spend time styling
  ///    a toast through this call and wonder why nothing changes.
  ///  • The `context` is never used, so a call after an `await` is harmless at
  ///    runtime, but it still trips `use_build_context_synchronously`, and it
  ///    teaches the next reader that holding a context across an await is fine
  ///    here. It is not fine anywhere else.
  ///
  /// Prefer [message] for anything new, and for any call that follows an await.
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

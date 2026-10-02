import 'dart:ui' show FlutterView, PlatformDispatcher;

import 'package:flutter/widgets.dart';

/// The rectangle an iOS share sheet should point at.
///
/// On iPad the share sheet is a popover and must be anchored; share_plus fails
/// the share if the rect is missing, zero-sized or off-screen. Android and iPhone
/// ignore it. Passing the tapped widget makes the popover point at that control.
Rect shareOriginOf(BuildContext? context) {
  final Size screen = _screenSize(context);
  // The plugin rejects a rect that extends past the screen, so clip it.
  final Rect bounds = Offset.zero & screen;

  if (context != null && context.mounted) {
    final RenderObject? object = context.findRenderObject();
    if (object is RenderBox && object.hasSize) {
      final Rect rect = object.localToGlobal(Offset.zero) & object.size;
      final Rect clipped = rect.intersect(bounds);
      if (clipped.width >= 1 && clipped.height >= 1) return clipped;
    }
  }

  // No usable widget: anchor at the screen centre, as iOS does itself.
  return Rect.fromCenter(
    center: bounds.center,
    width: 1,
    height: 1,
  );
}

Size _screenSize(BuildContext? context) {
  if (context != null) {
    final FlutterView? view = View.maybeOf(context);
    if (view != null && view.physicalSize.width > 0) {
      return view.physicalSize / view.devicePixelRatio;
    }
  }
  // `views` can be empty very early in startup.
  final views = PlatformDispatcher.instance.views;
  if (views.isNotEmpty && views.first.physicalSize.width > 0) {
    return views.first.physicalSize / views.first.devicePixelRatio;
  }
  return const Size(390, 844);
}

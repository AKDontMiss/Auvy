import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';


final homeScrollControlProvider = StateProvider<VoidCallback?>((ref) => null);

/// Per-tab RELOAD hooks, keyed by bottom-nav index (0 Home / 1 Search /
/// 2 Library). A page registers itself here in a post-frame callback, exactly
/// like [homeScrollControlProvider].
///
/// Drives the "tap the active tab again to reload" gesture in `MainLayout`:
/// the FIRST tap on the current tab scrolls it to the top, a SECOND tap shortly
/// after refreshes its content. A tab with no entry simply doesn't reload.
final tabReloadControlProvider =
    StateProvider<Map<int, Future<void> Function()>>((ref) => {});
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/catalog_api_clients.dart';
import 'package:auvy/services/listening_policy.dart';

// STREAM SOURCES, which InnerTube clients Auvy may resolve a stream through.
//
// Auvy resolves a playable audio URL by trying a fixed chain of YouTube client
// identities in order (visionOS → Android VR ×2 → iOS → iPadOS) and taking the
// first that returns an un-throttled, directly-playable stream. That chain was a
// `const` list: when one client started failing for a particular account, region
// or track, there was nothing to do about it.
//
// The ORDER is not a preference.
// It encodes which clients are known to return URLs without a throttle gate, so
// exposing it as a drag-to-reorder list would invite people to make playback
// worse. Only membership is editable, and the resulting chain is shown as
// numbered chips so the effect of a toggle is visible before you leave.

class StreamSourcesPage extends ConsumerStatefulWidget {
  const StreamSourcesPage({super.key});

  @override
  ConsumerState<StreamSourcesPage> createState() => _StreamSourcesPageState();
}

class _StreamSourcesPageState extends ConsumerState<StreamSourcesPage> {
  Future<void> _toggle(String key, bool enable) async {
    final disabled = Set<String>.from(CatalogApiClients.disabledStreamSources);
    if (enable) {
      disabled.remove(key);
    } else {
      // Refuse to empty the chain. `CatalogApiClients.streamOrder` also falls back
      // to the full list, but a silent fallback would leave the screen showing
      // every source off while all of them were still in use, so the refusal
      // happens here, where it can be explained.
      final remaining = CatalogApiClients.streamSourceInfo
          .where((s) => s.key != key && !disabled.contains(s.key))
          .length;
      if (remaining == 0) {
        AnimatedToast.message('At least one source has to stay on');
        return;
      }
      disabled.add(key);
    }
    await ListeningPolicy.setDisabledStreamSources(disabled);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final active = CatalogApiClients.streamSourceInfo
        .where((s) => !CatalogApiClients.disabledStreamSources.contains(s.key))
        .toList();

    return SettingsSubPage(
      title: 'Stream sources',
      header: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.045),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.055)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Resolve order',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5)),
            const SizedBox(height: 4),
            Text(
              'Auvy asks each of these for a playable audio URL and takes the '
              'first that answers. Turning one off skips it entirely.',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.66), fontSize: 11.5, height: 1.4),
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  for (var i = 0; i < active.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: themeColor.withOpacity(i == 0 ? 0.22 : 0.10),
                          borderRadius: BorderRadius.circular(50),
                          border: Border.all(
                              color: themeColor.withOpacity(i == 0 ? 0.55 : 0.0)),
                        ),
                        child: Text('${i + 1}. ${active[i].name}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      children: [
        Column(children: [
          for (var i = 0; i < CatalogApiClients.streamSourceInfo.length; i++) ...[
            if (i > 0) const SettingsDivider(),
            _sourceRow(CatalogApiClients.streamSourceInfo[i]),
          ],
        ]),
        // Not a warning bolted on afterwards: switching sources off is the one
        // thing on this screen that can stop music playing, and the honest place
        // to say so is under the switches that do it.
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Text(
            'Some tracks are only served by one of these. If songs start failing '
            'to play, turn the sources back on — the defaults are the chain that '
            'works for the widest catalogue.',
            style: TextStyle(color: Colors.white38, fontSize: 11.5, height: 1.45),
          ),
        ),
      ],
    );
  }

  Widget _sourceRow(({String key, String name, String detail}) source) {
    final enabled = !CatalogApiClients.disabledStreamSources.contains(source.key);
    return SettingsToggleRow(
      icon: Icons.cloud_download_rounded,
      tint: const Color(0xFF80DEEA),
      title: source.name,
      subtitle: source.detail,
      value: enabled,
      onChanged: (v) => _toggle(source.key, v),
    );
  }
}

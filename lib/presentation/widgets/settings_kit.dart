import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';

// Shared Settings row widgets, so sub-pages (Privacy, Theme, Stream sources) can
// live in their own files. `settings_page.dart` keeps its `_ToggleRow` /
// `_NavRow` / … names as aliases onto these.

/// Hairline between rows inside a card. Indented past the icon chip so the rule
/// starts at the text, the way iOS Settings does it.
class SettingsDivider extends StatelessWidget {
  const SettingsDivider();
  @override
  Widget build(BuildContext context) =>
      Divider(color: Colors.white.withOpacity(0.06), height: 1, indent: 62);
}

/// The tinted rounded-square icon that leads every settings row.
class SettingsIconChip extends StatelessWidget {
  final IconData icon;
  final Color tint;
  const SettingsIconChip({super.key, required this.icon, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: tint.withOpacity(0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: tint, size: 18),
    );
  }
}

class SettingsToggleRow extends ConsumerWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsToggleRow({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            SettingsIconChip(icon: icon, tint: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.85,
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeColor: Colors.black,
                activeTrackColor: themeColor,
                inactiveThumbColor: Colors.white70,
                inactiveTrackColor: Colors.white.withOpacity(0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsNavRow extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const SettingsNavRow({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticService.selection();
        onTap();
      },
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            SettingsIconChip(icon: icon, tint: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.white.withOpacity(0.25)),
          ],
        ),
      ),
    );
  }
}

/// An ACTION row: same anatomy as [SettingsNavRow] but reads as a verb rather
/// than a destination, so destructive actions can be tinted without being
/// mistaken for a page you can back out of.
class SettingsActionRow extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Paints the label in [tint] too. For irreversible actions only — used
  /// sparingly, it still means something.
  final bool destructive;

  const SettingsActionRow({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticService.selection();
        onTap();
      },
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            SettingsIconChip(icon: icon, tint: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: destructive ? tint : Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared scaffold for a settings sub-page so they all look identical.
/// The page title the way the app's other pages draw it (History, What's
/// New): a back arrow and a large title in a plain row that scrolls with the
/// page. No bar and no block behind it. Settings, its sub-pages and About use
/// it so they look like the rest of the app.
class AuvyPageHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;

  const AuvyPageHeader({super.key, required this.title, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class SettingsSubPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// Rendered above the cards, outside them. For a preview or an explanation
  /// that belongs to the whole screen rather than to any one row.
  final Widget? header;

  const SettingsSubPage({
    super.key,
    required this.title,
    required this.children,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    // The same backdrop and title row as Settings itself and the app's other
    // pages, rather than a flat colour under a toolbar.
    return DynamicBackground(
      force: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 120),
            physics: const BouncingScrollPhysics(),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: AuvyPageHeader(title: title),
              ),
              if (header != null)
                Padding(padding: const EdgeInsets.only(bottom: 14), child: header),
              for (final child in children)
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.045),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.055)),
                  ),
                  child: child,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small uppercase caption above a card, matching the main Settings sections.
class SettingsGroupLabel extends StatelessWidget {
  final String label;
  const SettingsGroupLabel(this.label, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: Colors.white.withOpacity(0.66),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
      );
}

/// The single source of truth for the desktop settings taxonomy: an ordered
/// list of all 8 sections plus a search index over their items.
///
/// Wave 2 agents add real controls by editing the relevant `sections/*.dart`
/// body widget (and declaring items here for search) — the shell and prefs
/// store do not change. Adding a whole new section is the only reason to edit
/// the [kSettingsSections] list.
library;

import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../sections/about_section.dart';
import '../sections/advanced_section.dart';
import '../sections/agents_chat_section.dart';
import '../sections/appearance_section.dart';
import '../sections/general_section.dart';
import '../sections/notifications_section.dart';
import '../sections/profiles_section.dart';
import '../sections/server_devices_section.dart';
import '../sections/shortcuts_section.dart';
import 'settings_item.dart';
import 'settings_section.dart';

/// All settings sections, in taxonomy order (SPEC-13 §"Section taxonomy").
final List<SettingsSection> kSettingsSections = [
  SettingsSection(
    id: 'general',
    title: 'General',
    icon: PhosphorIconsLight.slidersHorizontal,
    builder: (_) => const GeneralSection(),
    items: const [
      SettingsItem(
        id: 'general.startup',
        title: 'Startup',
        help: 'Launch at login and restore the last window or session.',
        keywords: ['launch', 'login', 'restore', 'boot'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'general.language',
        title: 'Language & region',
        help: 'Interface language and regional formats.',
        keywords: ['locale', 'i18n', 'region'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'general.update',
        title: 'Software update',
        help: 'Update channel and check for updates.',
        keywords: ['upgrade', 'channel', 'version'],
        availability: SettingsAvailability.comingSoon,
      ),
    ],
  ),
  SettingsSection(
    id: 'appearance',
    title: 'Appearance',
    icon: PhosphorIconsLight.palette,
    builder: (_) => const AppearanceSection(),
    items: const [
      SettingsItem(
        id: 'appearance.theme',
        title: 'Theme',
        help: 'System, Light, or Dark appearance.',
        keywords: ['dark', 'light', 'system', 'mode', 'color scheme'],
      ),
      SettingsItem(
        id: 'appearance.accent',
        title: 'Accent color',
        help: 'The single accent hue used for active and selected states.',
        keywords: ['color', 'highlight', 'green'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'appearance.text_code',
        title: 'Text & code',
        help: 'UI text scale; monospace code font (coming soon).',
        keywords: ['font', 'scale', 'size', 'monospace', 'text'],
      ),
      SettingsItem(
        id: 'appearance.layout',
        title: 'Layout',
        help: 'Default sidebar width and start collapsed.',
        keywords: ['sidebar', 'width', 'collapsed', 'fold'],
      ),
      SettingsItem(
        id: 'appearance.chat_rendering',
        title: 'Chat rendering',
        help: 'Markdown, code highlight theme, and timestamps.',
        keywords: ['markdown', 'highlight', 'timestamps'],
        availability: SettingsAvailability.comingSoon,
      ),
    ],
  ),
  SettingsSection(
    id: 'agents_chat',
    title: 'Agents & Chat',
    icon: PhosphorIconsLight.robot,
    builder: (_) => const AgentsChatSection(),
    items: const [
      SettingsItem(
        id: 'agents_chat.default_agent',
        title: 'Default agent & model',
        help: 'The agent and model used for new sessions.',
        keywords: ['model', 'llm', 'default'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'agents_chat.per_agent',
        title: 'Per-agent config',
        help: 'Binary path and API-key location per agent.',
        keywords: ['binary', 'api key', 'path'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'agents_chat.approvals',
        title: 'Approval & permissions policy',
        help: 'How agent tool calls are approved.',
        keywords: ['permissions', 'approval', 'policy'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'agents_chat.composer',
        title: 'Composer',
        help: 'Send on Enter vs ⌘-Enter.',
        keywords: ['enter', 'send', 'shortcut'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'agents_chat.pr_actions',
        title: 'PR actions',
        help:
            'Editable canned prompts for the composer\'s PR actions '
            '(Create PR, Fix PR, Resolve comments).',
        keywords: [
          'pr',
          'pull request',
          'prompt',
          'create pr',
          'fix pr',
          'resolve comments',
          'github',
        ],
      ),
    ],
  ),
  SettingsSection(
    id: 'server_devices',
    title: 'Server & Devices',
    icon: PhosphorIconsLight.hardDrives,
    builder: (_) => const ServerDevicesSection(),
    items: const [
      SettingsItem(
        id: 'server_devices.endpoint',
        title: 'Endpoint',
        help: 'The host and port the daemon binds and the client connects to.',
        keywords: ['host', 'port', 'connection'],
      ),
      SettingsItem(
        id: 'server_devices.lifecycle',
        title: 'Lifecycle',
        help: 'Start, stop, restart, and autostart the daemon.',
        keywords: ['start', 'stop', 'restart', 'daemon', 'autostart'],
      ),
      SettingsItem(
        id: 'server_devices.cli',
        title: 'CLI',
        help: 'Resolved makit CLI path and install command.',
        keywords: ['install', 'path', 'command line'],
      ),
      SettingsItem(
        id: 'server_devices.paired',
        title: 'Paired devices',
        help: 'List and revoke paired devices.',
        keywords: ['devices', 'revoke', 'pairing'],
      ),
      SettingsItem(
        id: 'server_devices.pair',
        title: 'Pair new device',
        help: 'Pair a new device via QR code.',
        keywords: ['qr', 'pair', 'add device'],
      ),
      SettingsItem(
        id: 'server_devices.sessions',
        title: 'Running sessions',
        help: 'Active sessions (idle/exited hidden); history and cleanup.',
        keywords: ['sessions', 'running', 'history'],
      ),
      SettingsItem(
        id: 'server_devices.fingerprint',
        title: 'Fingerprint / TLS trust',
        help: 'Certificate fingerprint and TLS trust.',
        keywords: ['tls', 'certificate', 'fingerprint', 'trust'],
      ),
      SettingsItem(
        id: 'server_devices.unpair',
        title: 'Unpair this device',
        help: 'Remove this device\'s pairing (danger).',
        keywords: ['unpair', 'remove', 'danger'],
      ),
    ],
  ),
  SettingsSection(
    id: 'profiles',
    title: 'Profiles',
    icon: PhosphorIconsLight.cube,
    builder: (_) => const ProfilesSection(),
    items: const [
      SettingsItem(
        id: 'profiles.list',
        title: 'Profiles',
        help:
            'Every server profile: name, home, size, running state, and '
            'per-profile Start/Stop/Rename/Delete.',
        keywords: [
          'profile',
          'profiles',
          'work',
          'personal',
          'dev build',
          'server instance',
          'start',
          'stop',
          'rename',
        ],
      ),
      SettingsItem(
        id: 'profiles.new',
        title: 'New profile',
        help: 'Create a new named server profile with its own home and port.',
        keywords: ['new profile', 'create profile', 'add profile'],
      ),
      SettingsItem(
        id: 'profiles.delete',
        title: 'Delete profile',
        help:
            'Erase a profile across all four of its stores; your worktrees, '
            'repos and other profiles are never touched.',
        keywords: ['delete profile', 'remove profile', 'danger', 'erase'],
      ),
      SettingsItem(
        id: 'profiles.reclaim',
        title: 'Stale profiles',
        help:
            'Review and bulk-delete dev profiles whose source folder is gone.',
        keywords: ['stale', 'orphan', 'orphaned', 'reclaim', 'cleanup'],
      ),
    ],
  ),
  SettingsSection(
    id: 'notifications',
    title: 'Notifications',
    icon: PhosphorIconsLight.bell,
    builder: (_) => const NotificationsSection(),
    items: const [
      SettingsItem(
        id: 'notifications.local',
        title: 'Local notifications',
        help: 'Local notifications, background wake, and reminder delay.',
        keywords: ['alerts', 'background', 'wake', 'reminder', 'delay'],
      ),
      SettingsItem(
        id: 'notifications.per_type',
        title: 'Per-type mute & approval reminders',
        help: 'Mute specific notification types; approval reminders.',
        keywords: ['mute', 'reminders', 'approval'],
        availability: SettingsAvailability.comingSoon,
      ),
    ],
  ),
  SettingsSection(
    id: 'shortcuts',
    title: 'Shortcuts',
    icon: PhosphorIconsLight.keyboard,
    builder: (_) => const ShortcutsSection(),
    items: const [
      SettingsItem(
        id: 'shortcuts.chat',
        title: 'Chat scope shortcuts',
        help: 'Shortcuts active while the message field is focused.',
        keywords: ['keyboard', 'chord', 'rebind', 'composer'],
      ),
      SettingsItem(
        id: 'shortcuts.window',
        title: 'Window scope shortcuts',
        help: 'Shortcuts active anywhere in the window.',
        keywords: ['keyboard', 'chord', 'rebind', 'global'],
      ),
    ],
  ),
  SettingsSection(
    id: 'advanced',
    title: 'Advanced',
    icon: PhosphorIconsLight.wrench,
    builder: (_) => const AdvancedSection(),
    items: const [
      SettingsItem(
        id: 'advanced.developer',
        title: 'Developer',
        help: 'Fake server toggle, logs, and diagnostics.',
        keywords: ['fake', 'logs', 'diagnostics', 'debug'],
      ),
      SettingsItem(
        id: 'advanced.status',
        title: 'Status',
        help: 'Process id, uptime, and protocol version.',
        keywords: ['pid', 'uptime', 'protocol', 'version'],
      ),
      SettingsItem(
        id: 'advanced.telemetry',
        title: 'Telemetry',
        help: 'Anonymous usage telemetry.',
        keywords: ['analytics', 'usage'],
        availability: SettingsAvailability.comingSoon,
      ),
      SettingsItem(
        id: 'advanced.reset_all',
        title: 'Reset all settings',
        help: 'Clear every changed preference and return to defaults.',
        keywords: ['reset', 'defaults', 'clear'],
      ),
    ],
  ),
  SettingsSection(
    id: 'about',
    title: 'About',
    icon: PhosphorIconsLight.info,
    builder: (_) => const AboutSection(),
    items: const [
      SettingsItem(
        id: 'about.version',
        title: 'Version & links',
        help: 'App version, protocol version, and links.',
        keywords: ['version', 'protocol', 'links', 'about'],
      ),
    ],
  ),
];

/// A single search hit: the matching [item] and the id of the section that
/// owns it (for deep-linking / navigation).
class SettingsSearchResult {
  /// Creates a result.
  const SettingsSearchResult({required this.sectionId, required this.item});

  /// The id of the owning section.
  final String sectionId;

  /// The matching item.
  final SettingsItem item;
}

/// A reusable search over an arbitrary list of sections. Defaults to the
/// app-wide [kSettingsSections]. Returns items whose title, keywords, or help
/// contain [query] (case-insensitive); an empty/whitespace query returns no
/// results.
List<SettingsSearchResult> searchSettings(
  String query, {
  List<SettingsSection>? sections,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final results = <SettingsSearchResult>[];
  for (final section in sections ?? kSettingsSections) {
    for (final item in section.items) {
      if (_matches(item, q)) {
        results.add(SettingsSearchResult(sectionId: section.id, item: item));
      }
    }
  }
  return results;
}

bool _matches(SettingsItem item, String q) {
  if (item.title.toLowerCase().contains(q)) return true;
  if (item.help.toLowerCase().contains(q)) return true;
  for (final keyword in item.keywords) {
    if (keyword.toLowerCase().contains(q)) return true;
  }
  return false;
}

/// The Activity list — the durable half of the status layer, and the answer to
/// "what just happened?".
///
/// One widget for both surfaces: the phone pushes it as a screen
/// ([ActivityScreen]), the desktop opens it in a dialog ([showActivityDialog]).
/// A hover-anchored `OverlayPortal` popover (the `PortsPopover` house pattern)
/// would be the third rendering of one list for no new capability — this is a
/// list you *read*, not a glyph you peek at.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import 'status_center.dart';
import 'status_event.dart';
import 'status_providers.dart';
import 'status_tone.dart';

/// Compact "how long ago", in the units a person would say out loud.
String activityAgo(DateTime ts, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(ts);
  if (d.inSeconds < 10) return 'now';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

class ActivityView extends ConsumerStatefulWidget {
  const ActivityView({super.key, this.onOpenSession});

  /// How a session-bound event gets you to its session. Null on surfaces that
  /// cannot navigate (the row simply omits the affordance).
  final void Function(String sessionId)? onOpenSession;

  @override
  ConsumerState<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends ConsumerState<ActivityView> {
  StreamSubscription<StatusChange>? _sub;
  StatusSeverity _floor = StatusSeverity.progress;
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    final center = ref.read(statusCenterProvider);
    // Reading the inbox is what marks it read; the badge clears as you arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) => center.markAllRead());
    _sub = center.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final center = ref.read(statusCenterProvider);
    final events = center.events
        .where((e) => e.severity.atLeast(_floor))
        .toList();
    return Column(
      children: [
        _ActivityToolbar(
          floor: _floor,
          onFloor: (f) => setState(() => _floor = f),
          onCopyAll: events.isEmpty
              ? null
              : () => Clipboard.setData(
                  ClipboardData(text: center.copyAllText()),
                ),
          onClear: center.events.isEmpty ? null : center.clear,
        ),
        Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        Expanded(
          child: events.isEmpty
              ? const _EmptyActivity()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: kSpace4),
                  itemCount: events.length,
                  separatorBuilder: (context, _) => Divider(
                    height: 1,
                    indent: kSpace16,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  itemBuilder: (context, i) {
                    final e = events[i];
                    return ActivityRow(
                      event: e,
                      expanded: _expanded.contains(e.id),
                      onToggle: () => setState(
                        () => _expanded.contains(e.id)
                            ? _expanded.remove(e.id)
                            : _expanded.add(e.id),
                      ),
                      onOpenSession: widget.onOpenSession,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ActivityToolbar extends StatelessWidget {
  const _ActivityToolbar({
    required this.floor,
    required this.onFloor,
    required this.onCopyAll,
    required this.onClear,
  });

  final StatusSeverity floor;
  final ValueChanged<StatusSeverity> onFloor;
  final VoidCallback? onCopyAll;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace8,
        vertical: kSpace4,
      ),
      child: Row(
        children: [
          const SizedBox(width: kSpace8),
          Text(
            floor == StatusSeverity.progress
                ? 'Everything'
                : '${statusSeverityLabel(floor)} and worse',
            style: text.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          PopupMenuButton<StatusSeverity>(
            tooltip: 'Filter',
            icon: const Icon(PhosphorIconsLight.funnel, size: 16),
            initialValue: floor,
            onSelected: onFloor,
            itemBuilder: (context) => [
              for (final s in StatusSeverity.values)
                PopupMenuItem(
                  value: s,
                  child: Text(
                    s == StatusSeverity.progress
                        ? 'Everything'
                        : statusSeverityLabel(s),
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(PhosphorIconsLight.copy, size: 16),
            onPressed: onCopyAll,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(PhosphorIconsLight.trash, size: 16),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

class ActivityRow extends StatelessWidget {
  const ActivityRow({
    super.key,
    required this.event,
    required this.expanded,
    required this.onToggle,
    this.onOpenSession,
  });

  final StatusEvent event;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(String sessionId)? onOpenSession;

  bool get _canExpand =>
      event.hasDetail || (event.sessionId != null && onOpenSession != null);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: _canExpand ? onToggle : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace16,
          vertical: kSpace10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: kSpace2),
                  child: Icon(
                    statusGlyph(event.severity),
                    size: 15,
                    color: statusColor(cs, event.severity),
                  ),
                ),
                const SizedBox(width: kSpace10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(event.displayTitle, style: text.bodyMedium),
                      const SizedBox(height: kSpace2),
                      Row(
                        children: [
                          Text(
                            event.source,
                            style: text.labelXs?.copyWith(color: cs.outline),
                          ),
                          Text(
                            '  ·  ${activityAgo(event.ts)}',
                            style: text.labelXs?.copyWith(color: cs.outline),
                          ),
                          if (event.hasDetail && !expanded) ...[
                            const SizedBox(width: kSpace6),
                            Icon(
                              PhosphorIconsLight.caretRight,
                              size: 10,
                              color: cs.outline,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: kSpace8),
              if (event.hasDetail)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(kSpace8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(kRadius8),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: SelectableText(
                    event.detail!.trimRight(),
                    style: text.bodySmall?.mono,
                  ),
                ),
              const SizedBox(height: kSpace4),
              Row(
                children: [
                  if (event.hasDetail)
                    _RowAction(
                      tooltip: 'Copy this entry',
                      icon: PhosphorIconsLight.copy,
                      label: 'Copy',
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: event.toClipboardText()),
                      ),
                    ),
                  if (event.sessionId != null && onOpenSession != null)
                    _RowAction(
                      tooltip: 'Open session',
                      icon: PhosphorIconsLight.arrowSquareOut,
                      label: 'Open session',
                      onPressed: () => onOpenSession!(event.sessionId!),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 13),
      label: Text(label),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.labelSmall,
      ),
    ),
  );
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kSpace32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(PhosphorIconsLight.tray, size: 28, color: cs.outline),
            const SizedBox(height: kSpace12),
            Text('Nothing yet', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: kSpace4),
            Text(
              'Outcomes, warnings and failures land here — with the error text, '
              'ready to copy.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

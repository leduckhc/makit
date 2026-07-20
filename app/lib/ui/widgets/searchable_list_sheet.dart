import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'sheet_header.dart';

/// Fraction of the screen height that a searchable sheet may grow to. Keeps a
/// sliver of the background visible so the sheet always reads as dismissible
/// (and the drag handle stays reachable) even when its list is long.
const _kMaxHeightFraction = 0.85;

/// Present a filterable list in a modal bottom sheet capped at
/// [_kMaxHeightFraction] of the screen height.
///
/// A search button in the header reveals a text field that filters [items]
/// via [matches] (case-insensitive matching is the caller's responsibility).
/// [tileBuilder] renders each visible item; tapping one should pop the sheet
/// with the selection. When [items] is empty, [emptyState] (if provided) is
/// shown and search is hidden.
Future<T?> showSearchableListSheet<T>({
  required BuildContext context,
  required String title,
  required List<T> items,
  required Widget Function(BuildContext, T) tileBuilder,
  required bool Function(T, String) matches,
  Widget? emptyState,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SearchableListSheet<T>(
      title: title,
      items: items,
      tileBuilder: tileBuilder,
      matches: matches,
      emptyState: emptyState,
    ),
  );
}

class _SearchableListSheet<T> extends StatefulWidget {
  const _SearchableListSheet({
    required this.title,
    required this.items,
    required this.tileBuilder,
    required this.matches,
    this.emptyState,
  });

  final String title;
  final List<T> items;
  final Widget Function(BuildContext, T) tileBuilder;
  final bool Function(T, String) matches;
  final Widget? emptyState;

  @override
  State<_SearchableListSheet<T>> createState() =>
      _SearchableListSheetState<T>();
}

class _SearchableListSheetState<T> extends State<_SearchableListSheet<T>> {
  bool _searching = false;
  String _query = '';
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _controller.clear();
        _query = '';
      }
    });
  }

  List<T> get _filtered => _query.isEmpty
      ? widget.items
      : widget.items.where((x) => widget.matches(x, _query)).toList();

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * _kMaxHeightFraction;

    if (widget.items.isEmpty) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(title: widget.title),
              if (widget.emptyState != null) widget.emptyState!,
            ],
          ),
        ),
      );
    }

    final filtered = _filtered;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              title: widget.title,
              actions: IconButton(
                icon: Icon(
                  _searching
                      ? PhosphorIconsLight.magnifyingGlassMinus
                      : PhosphorIconsLight.magnifyingGlass,
                ),
                tooltip: _searching ? 'Hide search' : 'Search',
                onPressed: _toggleSearch,
              ),
            ),
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(
                      PhosphorIconsLight.magnifyingGlass,
                      size: 20,
                    ),
                    hintText: 'Filter…',
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(PhosphorIconsLight.x, size: 20),
                            tooltip: 'Clear',
                            onPressed: () {
                              _controller.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No matches for “$_query”',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: filtered.length,
                  itemBuilder: (c, i) => widget.tileBuilder(c, filtered[i]),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

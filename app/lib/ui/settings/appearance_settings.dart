import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';

/// Appearance settings on the phone: theme mode and text scale — the two
/// desktop Appearance preferences that mean anything without a window to lay
/// out. Both write to the shared preferences layer, so a phone and a paired
/// desktop keep their own copies of the same setting rather than one surface
/// having the feature and the other not.
class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key});

  /// The slider's range, matching desktop's Appearance → Text.
  static const _minScale = 0.9;
  static const _maxScale = 1.3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeValueProvider);
    final scale = ref.watch(textScaleValueProvider);
    final controller = ref.read(preferencesControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const SizedBox(
            width: 24,
            child: Center(child: Icon(PhosphorIconsLight.circleHalf, size: 24)),
          ),
          title: const Text('Theme'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: kSpace8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {mode},
                onSelectionChanged: (picked) =>
                    controller.set(themeModePreference, picked.first),
              ),
            ),
          ),
        ),
        ListTile(
          leading: const SizedBox(
            width: 24,
            child: Center(child: Icon(PhosphorIconsLight.textAa, size: 24)),
          ),
          title: const Text('Text size'),
          subtitle: Row(
            children: [
              Expanded(
                child: Slider(
                  value: scale.clamp(_minScale, _maxScale),
                  min: _minScale,
                  max: _maxScale,
                  // 0.05 steps: fine enough to tune, coarse enough that a
                  // thumb drag lands on a repeatable value.
                  divisions: ((_maxScale - _minScale) / 0.05).round(),
                  label: '${(scale * 100).round()}%',
                  onChanged: (v) => controller.set(textScalePreference, v),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${(scale * 100).round()}%',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

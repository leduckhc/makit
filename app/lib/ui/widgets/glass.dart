import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

/// Runtime toggle for the whole app:
///   false → real shader-based [LiquidGlass] (best looking, heavier GPU)
///   true  → cheap [FakeGlass] (backdrop blur, no refraction)
///
/// Flip it live from the session bar to feel the perf difference on-device.
final fakeGlassProvider = StateProvider<bool>((_) => false);

/// A floating Liquid-Glass surface for bars/toolbars. It refracts + blurs
/// whatever is painted *behind* it, so it must be stacked over scrolling
/// content (see [SessionScreen]). Honours [fakeGlassProvider].
class GlassSurface extends ConsumerWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 26,
    this.blur,
    this.tint,
  });

  final Widget child;
  final double borderRadius;

  /// Background blur strength. Higher = frostier / less see-through.
  final double? blur;

  /// Glass tint; the alpha channel controls opacity (higher = less
  /// transparent). Defaults to a very subtle white.
  final Color? tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fake = ref.watch(fakeGlassProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = LiquidRoundedSuperellipse(borderRadius: borderRadius);

    final settings = LiquidGlassSettings(
      thickness: 26,
      blur: blur ?? 12,
      glassColor: tint ?? (dark ? const Color(0x40FFFFFF) : const Color(0x33FFFFFF)),
      lightIntensity: 1.2,
      ambientStrength: 0.4,
      saturation: 1.1,
    );

    if (fake) {
      return FakeGlass(shape: shape, settings: settings, child: child);
    }
    return LiquidGlass.withOwnLayer(
      shape: shape,
      settings: settings,
      child: child,
    );
  }
}

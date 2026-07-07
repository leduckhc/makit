import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
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
      blur: blur ?? 14,
      // Light mode: 18% white tint (sweet spot between milky 35% and weak 6%).
      // High saturation (1.8) is the critical lever — it keeps refracted content
      // vivid instead of washing into grey haze (the real cause of "milky" feel).
      glassColor:
          tint ?? (dark ? const Color(0x40000000) : const Color(0x2EFFFFFF)),
      lightIntensity: dark ? 0.5 : 0.9,
      ambientStrength: dark ? 0.2 : 0.3,
      refractiveIndex: 1.35,
      saturation: 1.8,
    );

    final glass = fake
        ? FakeGlass(shape: shape, settings: settings, child: child)
        : LiquidGlass.withOwnLayer(
            shape: shape,
            settings: settings,
            child: child,
          );

    // Add light 1px border (edge definition) + soft shadow (depth).
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: dark ? Colors.white12 : Colors.white30,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.3 : 0.1),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: glass,
    );
  }
}

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
      blur: blur ?? 18,
      // Design-system glass (see design-system/pino/MASTER.md):
      // 50% neutral tint, high saturation (anti-milky), calm light intensity.
      glassColor:
          tint ?? (dark ? const Color(0x80181818) : const Color(0x80FFFFFF)),
      lightIntensity: dark ? 0.5 : 0.9,
      ambientStrength: dark ? 0.2 : 0.3,
      refractiveIndex: 1.3,
      saturation: 1.8,
    );

    final glass = fake
        ? FakeGlass(shape: shape, settings: settings, child: child)
        : LiquidGlass.withOwnLayer(
            shape: shape,
            settings: settings,
            child: child,
          );

    // Edge highlight (light border) + soft drop shadow for depth.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: glass,
    );
  }
}

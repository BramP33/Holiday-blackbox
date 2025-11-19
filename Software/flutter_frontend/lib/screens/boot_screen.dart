import 'dart:async';
import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/media_location.dart';
import '../state/backend_health.dart';
import '../state/providers.dart';
import 'root_shell.dart';

class BootScreen extends ConsumerStatefulWidget {
  const BootScreen({super.key});

  @override
  ConsumerState<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends ConsumerState<BootScreen>
    with TickerProviderStateMixin {
  late final AnimationController _zoomController;
  late final AnimationController _markerController;
  bool _scheduledNav = false;
  final Random _random = Random();
  _FallbackCity? _fallbackCity;

  @override
  void initState() {
    super.initState();
    _zoomController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2200))
      ..forward();
    _markerController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));

    _zoomController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _markerController.forward();
      }
    });
    _markerController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _goNext();
      }
    });

    Future.microtask(() {
      // Trigger backend health check and location fetch
      ref.read(backendHealthProvider);
      ref.read(lastMediaLocationProvider);
    });
    Future.delayed(const Duration(milliseconds: 4200), _goNext);
  }

  @override
  void dispose() {
    _zoomController.dispose();
    _markerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locationAsync = ref.watch(lastMediaLocationProvider);
    final healthAsync = ref.watch(backendHealthProvider);
    final MediaLocation? location = locationAsync.asData?.value;
    final hasLocationError = locationAsync.hasError;
    final hasHealthError = healthAsync.hasError;
    final bool dataResolved = locationAsync.asData != null || hasLocationError;

    if ((hasLocationError || (dataResolved && location == null)) &&
        _fallbackCity == null) {
      _fallbackCity = _fallbackCities[_random.nextInt(_fallbackCities.length)];
    }

    final _FallbackCity? fallback = _fallbackCity;
    final hasLocation = location != null;
    final Alignment alignment;
    if (hasLocation) {
      alignment = Alignment(location.alignmentX, location.alignmentY);
    } else if (fallback != null) {
      alignment = fallback.alignment;
    } else {
      alignment = Alignment.center;
    }

    final bool usingFallback = !hasLocation && fallback != null;

    final label = usingFallback
        ? '${fallback.label}, NL'
        : hasHealthError
            ? 'Waiting for backend to start…'
            : hasLocationError
                ? 'Unable to load your last location'
                : hasLocation
                    ? location.displayLabel()
                    : 'Locating your last story…';
    final locationDetails = hasLocation
        ? location.capturedAt
        : usingFallback
            ? 'Somewhere in the Netherlands'
            : null;

    return Scaffold(
      body: AnimatedBuilder(
        animation: Listenable.merge([_zoomController, _markerController]),
        builder: (context, child) {
          final zoomProgress = Curves.easeInOutCubic
              .transform(_zoomController.value.clamp(0.0, 1.0));
          final scale = lerpDouble(1.0, 2.35, zoomProgress) ?? 1.0;
          final mapOpacity = Curves.easeInOutQuad
              .transform(_zoomController.value.clamp(0.0, 1.0));
          final spotlightOpacity =
              Curves.easeOut.transform(_markerController.value.clamp(0.0, 1.0));
          final markerScale = lerpDouble(
                  0.4,
                  1.0,
                  Curves.elasticOut
                      .transform(_markerController.value.clamp(0.0, 1.0))) ??
              1.0;

          final mapAlignment = Alignment.lerp(Alignment.center,
                  Alignment(-alignment.x, -alignment.y), zoomProgress) ??
              Alignment.center;
          final markerAlignment =
              Alignment.lerp(Alignment.center, alignment, zoomProgress) ??
                  alignment;

          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF051C2C),
                  Color(0xFF0F4F4F),
                  Color(0xFF123A35)
                ],
              ),
            ),
            child: Stack(
              children: [
                Align(
                  alignment: mapAlignment,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 600),
                    opacity: mapOpacity,
                    child: Transform.scale(
                      scale: scale,
                      child: SvgPicture.asset(
                        'assets/visuals/world_map.svg',
                        colorFilter: const ColorFilter.mode(
                            Color(0x33FFFFFF), BlendMode.srcIn),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: markerAlignment,
                  child: Opacity(
                    opacity: spotlightOpacity,
                    child: Transform.scale(
                      scale: markerScale,
                      child: _SpotlightMarker(isActive: hasLocation),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(
                      markerAlignment.x * 0.92, markerAlignment.y * 0.92),
                  child: Opacity(
                    opacity: spotlightOpacity,
                    child: Transform.scale(
                      scale: markerScale,
                      child: SvgPicture.asset(
                        'assets/branding/blackbox_logo.svg',
                        width: 96,
                        height: 96,
                        colorFilter: const ColorFilter.mode(
                            Colors.white, BlendMode.srcIn),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    minimum: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: _BootStatusPanel(
                        headline: 'Blackbox is powering up…',
                        label: label,
                        details: locationDetails,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _goNext() {
    if (_scheduledNav) return;
    _scheduledNav = true;
    Future.microtask(() {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 600),
          pageBuilder: (context, animation, secondaryAnimation) {
            return FadeTransition(opacity: animation, child: const RootShell());
          },
        ),
      );
    });
  }
}

class _SpotlightMarker extends StatelessWidget {
  const _SpotlightMarker({required this.isActive});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      height: 160,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 160,
            height: 160,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x33FFFFFF), Color(0x00000000)],
                stops: [0.0, 1.0],
              ),
            ),
          ),
          if (isActive)
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: Colors.white.withOpacity(0.9), width: 3),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0xAAFFFFFF),
                      blurRadius: 20,
                      spreadRadius: 6),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BootStatusPanel extends StatelessWidget {
  const _BootStatusPanel({
    required this.headline,
    required this.label,
    this.details,
  });

  final String headline;
  final String label;
  final String? details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xAA031A24),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 20,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              headline,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            if (details != null) ...[
              const SizedBox(height: 12),
              Text(
                details!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FallbackCity {
  const _FallbackCity(this.label, this.latitude, this.longitude);

  final String label;
  final double latitude;
  final double longitude;

  Alignment get alignment {
    final x = (longitude / 180).clamp(-1.0, 1.0);
    final y = (-(latitude) / 90).clamp(-1.0, 1.0);
    return Alignment(x, y);
  }
}

const List<_FallbackCity> _fallbackCities = [
  _FallbackCity('Amsterdam', 52.3676, 4.9041),
  _FallbackCity('Rotterdam', 51.9244, 4.4777),
  _FallbackCity('Utrecht', 52.0907, 5.1214),
  _FallbackCity('The Hague', 52.0705, 4.3007),
  _FallbackCity('Eindhoven', 51.4416, 5.4697),
  _FallbackCity('Groningen', 53.2194, 6.5665),
  _FallbackCity('Leeuwarden', 53.2012, 5.7999),
  _FallbackCity('Maastricht', 50.8514, 5.6900),
  _FallbackCity('Zwolle', 52.5168, 6.0830),
  _FallbackCity('Nijmegen', 51.8126, 5.8372),
];

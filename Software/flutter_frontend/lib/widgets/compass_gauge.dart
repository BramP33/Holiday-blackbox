import 'package:flutter/material.dart';

import '../theme.dart';

class CompassGauge extends StatefulWidget {
  const CompassGauge({
    super.key,
    required this.value,
    required this.label,
    this.caption,
    this.indeterminate = false,
    this.size = 180,
  });

  final double value;
  final String label;
  final String? caption;
  final bool indeterminate;
  final double size;

  @override
  State<CompassGauge> createState() => _CompassGaugeState();
}

class _CompassGaugeState extends State<CompassGauge> {
  double _animationStart = 0;

  @override
  void initState() {
    super.initState();
    _animationStart = widget.indeterminate ? 0 : widget.value.clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant CompassGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.indeterminate) {
      _animationStart = 0;
    } else if (oldWidget.indeterminate) {
      _animationStart = 0;
    } else if (widget.value != oldWidget.value) {
      _animationStart = oldWidget.value.clamp(0.0, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.indeterminate) {
      return _buildGauge(null);
    }

    final normalized = widget.value.clamp(0.0, 1.0);
    final begin = _animationStart;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: begin, end: normalized),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      onEnd: () {
        if (_animationStart != normalized) {
          setState(() {
            _animationStart = normalized;
          });
        }
      },
      builder: (context, animatedValue, _) {
        return _buildGauge(animatedValue);
      },
    );
  }

  Widget _buildGauge(double? value) {
    final percent = value == null ? null : (value * 100).clamp(0, 100).round();
    final caption = widget.caption;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  AppColors.forest.withOpacity(0.2),
                  AppColors.forest.withOpacity(0.8),
                  AppColors.forest.withOpacity(0.2),
                ],
              ),
              border: Border.all(color: AppColors.rust.withOpacity(0.8), width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.45),
                  offset: const Offset(0, 10),
                  blurRadius: 28,
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 12,
                backgroundColor: AppColors.sage.withOpacity(0.25),
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.amber),
              ),
            ),
          ),
          Container(
            width: widget.size * 0.6,
            height: widget.size * 0.6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.charcoal,
              border: Border.all(color: AppColors.rust, width: 2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppColors.amber,
                        letterSpacing: 2.4,
                      ),
                ),
                if (percent != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '$percent%',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: AppColors.kraft,
                          fontSize: 32,
                        ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(AppColors.amber),
                    ),
                  ),
                ],
                if (caption != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    caption,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.sage,
                          fontSize: 12,
                          height: 1.2,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

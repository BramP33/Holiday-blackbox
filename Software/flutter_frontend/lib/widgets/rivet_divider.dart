import 'package:flutter/material.dart';

import '../theme.dart';

class RivetDivider extends StatelessWidget {
  const RivetDivider({
    super.key,
    this.spacing = 40,
    this.rivetSize = 6,
    this.color = AppColors.amber,
  });

  final double spacing;
  final double rivetSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final usableWidth = constraints.maxWidth;
        final int count = usableWidth.isFinite && usableWidth > 0
            ? (usableWidth / spacing).round().clamp(3, 24)
            : 8;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(count, (_) {
            return Container(
              width: rivetSize,
              height: rivetSize,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(rivetSize),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.45),
                    offset: const Offset(0, 1),
                    blurRadius: 2,
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}

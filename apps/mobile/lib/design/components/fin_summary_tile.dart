import 'package:flutter/material.dart';

import '../tokens.dart';

/// A compact, readable summary value for overview screens.
///
/// Unlike [FinMetricTile], this component accepts an API-formatted value
/// without asking the client to parse money. That keeps currency/exponent
/// decisions server-authoritative while giving the dashboard a consistent
/// visual hierarchy.
class FinSummaryTile extends StatelessWidget {
  const FinSummaryTile({
    required this.label,
    required this.value,
    this.icon,
    this.supporting,
    this.accent,
    super.key,
  });

  final String label;
  final String value;
  final IconData? icon;
  final String? supporting;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.primary;
    return Semantics(
      container: true,
      label: '$label: $value${supporting == null ? '' : ', $supporting'}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: FinRadius.cardBorder,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0B1F33).withValues(alpha: 0.055),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FinSpace.md,
              vertical: FinSpace.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 14, color: color),
                      const SizedBox(width: FinSpace.xs),
                    ],
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (supporting != null)
                      Flexible(
                        child: Text(
                          supporting!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.25,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

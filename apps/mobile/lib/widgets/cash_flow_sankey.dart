import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../design/design.dart';
import '../models/models.dart';

/// A responsive, animated cash-flow view built from server-side analytics.
///
/// The canvas never scrolls horizontally. On a phone it simplifies its inline
/// labels and lets the complete, keyboard-focusable legend carry the detail;
/// on a wider surface it labels the flow directly as well.
class CashFlowSankey extends StatefulWidget {
  const CashFlowSankey({
    required this.incomeSources,
    required this.expenseCategories,
    required this.currency,
    required this.totalIncome,
    required this.totalExpenses,
    super.key,
  });

  final List<AnalyticsBucket> incomeSources;
  final List<AnalyticsBucket> expenseCategories;
  final String currency;
  final int totalIncome;
  final int totalExpenses;

  @override
  State<CashFlowSankey> createState() => _CashFlowSankeyState();
}

class _CashFlowSankeyState extends State<CashFlowSankey>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didUpdateWidget(CashFlowSankey oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incomeSources != widget.incomeSources ||
        oldWidget.expenseCategories != widget.expenseCategories ||
        oldWidget.totalIncome != widget.totalIncome ||
        oldWidget.totalExpenses != widget.totalExpenses ||
        oldWidget.currency != widget.currency) {
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fin = context.finColors;
    final sourceRows = _flowRows(
      widget.incomeSources,
      maximum: 3,
      otherLabel: 'Other income',
      colors: [fin.income],
    );
    final categoryRows = _flowRows(
      widget.expenseCategories,
      maximum: 6,
      otherLabel: 'Other spending',
      colors: fin.chartSeries,
    );
    final income = math.max(
      math.max(widget.totalIncome, 0),
      sourceRows.fold<int>(0, (sum, row) => sum + row.amount),
    );
    final expenses = math.max(
      math.max(widget.totalExpenses, 0),
      categoryRows.fold<int>(0, (sum, row) => sum + row.amount),
    );
    final funding = math.max(income, expenses);

    if (funding == 0) return _emptyCard(context);

    final sources = [...sourceRows];
    final capturedIncome = sources.fold<int>(0, (sum, row) => sum + row.amount);
    if (income > capturedIncome) {
      sources.add(_FlowRow(
        label: sourceRows.isEmpty ? 'Income' : 'Other income',
        amount: income - capturedIncome,
        color: fin.income,
      ));
    }
    if (expenses > income) {
      sources.add(_FlowRow(
        label: 'Opening balance / credit',
        amount: expenses - income,
        color: fin.warning,
      ));
    }

    final destinations = [...categoryRows];
    final capturedExpenses =
        destinations.fold<int>(0, (sum, row) => sum + row.amount);
    if (expenses > capturedExpenses) {
      destinations.add(_FlowRow(
        label: 'Other spending',
        amount: expenses - capturedExpenses,
        color: fin.neutral,
      ));
    }
    if (income > expenses) {
      destinations.add(_FlowRow(
        label: 'Savings / remaining',
        amount: income - expenses,
        color: fin.income,
      ));
    }

    final summary = 'Money flow for this period in ${widget.currency}. '
        'Income ${_money(income, widget.currency)}; '
        'spending ${_money(expenses, widget.currency)}; '
        '${income >= expenses ? 'savings' : 'funding gap'} '
        '${_money((income - expenses).abs(), widget.currency)}.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(FinSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.account_tree_outlined,
                    size: 21,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Money flow', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'How income moved through this period',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: fin.incomeContainer,
                    borderRadius: FinRadius.pillBorder,
                  ),
                  child: Text(
                    'Live data',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: fin.onIncomeContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Semantics(
              container: true,
              label: summary,
              child: ExcludeSemantics(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final chartHeight =
                        (constraints.maxWidth * 0.42).clamp(230.0, 300.0);
                    return RepaintBoundary(
                      child: Tooltip(
                        message: summary,
                        waitDuration: const Duration(milliseconds: 350),
                        child: SizedBox(
                          key: const Key('cash-flow-sankey'),
                          width: double.infinity,
                          height: chartHeight,
                          child: AnimatedBuilder(
                            animation: _progress,
                            builder: (context, _) => CustomPaint(
                              painter: _SankeyPainter(
                                sources: sources,
                                destinations: destinations,
                                total: funding,
                                currency: widget.currency,
                                centerColor: theme.colorScheme.primary,
                                labelColor: theme.colorScheme.onSurface,
                                progress: _progress.value,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 14),
            _LegendGroup(
              title: 'Income',
              rows: sources,
              currency: widget.currency,
              total: funding,
            ),
            const SizedBox(height: 12),
            _LegendGroup(
              title: 'Spending & savings',
              rows: destinations,
              currency: widget.currency,
              total: funding,
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(FinSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Money flow', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'How income moved through this period',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            const FinEmptyState(
              icon: Icons.account_tree_outlined,
              title: 'No cash-flow activity',
              message:
                  'Choose another date range or import financial data to populate this chart.',
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendGroup extends StatelessWidget {
  const _LegendGroup({
    required this.title,
    required this.rows,
    required this.currency,
    required this.total,
  });

  final String title;
  final List<_FlowRow> rows;
  final String currency;
  final int total;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final row in rows)
                _FlowLegend(
                  row: row,
                  currency: currency,
                  total: total,
                ),
            ],
          ),
        ],
      );
}

class _FlowLegend extends StatelessWidget {
  const _FlowLegend({
    required this.row,
    required this.currency,
    required this.total,
  });

  final _FlowRow row;
  final String currency;
  final int total;

  @override
  Widget build(BuildContext context) {
    final percent = total == 0 ? 0 : (row.amount / total * 100).round();
    final message =
        '${row.label}: ${_money(row.amount, currency)} · $percent% of available cash';
    return Tooltip(
      message: message,
      child: Semantics(
        label: '$message.',
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: row.color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '${row.label}  ${_money(row.amount, currency)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlowRow {
  const _FlowRow({
    required this.label,
    required this.amount,
    required this.color,
  });

  final String label;
  final int amount;
  final Color color;
}

List<_FlowRow> _flowRows(
  List<AnalyticsBucket> buckets, {
  required int maximum,
  required String otherLabel,
  required List<Color> colors,
}) {
  final ordered = buckets.where((row) => row.total > 0).toList()
    ..sort((a, b) => b.total.compareTo(a.total));
  if (ordered.isEmpty) return [];

  final visibleCount = ordered.length > maximum ? maximum - 1 : maximum;
  final visible = ordered.take(visibleCount).toList();
  final rows = <_FlowRow>[
    for (var index = 0; index < visible.length; index++)
      _FlowRow(
        label: visible[index].label,
        amount: visible[index].total,
        color: colors[index % colors.length],
      ),
  ];
  if (ordered.length > visible.length) {
    rows.add(_FlowRow(
      label: otherLabel,
      amount: ordered
          .skip(visible.length)
          .fold<int>(0, (sum, row) => sum + row.total),
      color: colors[visible.length % colors.length],
    ));
  }
  return rows;
}

class _SankeyPainter extends CustomPainter {
  const _SankeyPainter({
    required this.sources,
    required this.destinations,
    required this.total,
    required this.currency,
    required this.centerColor,
    required this.labelColor,
    required this.progress,
  });

  final List<_FlowRow> sources;
  final List<_FlowRow> destinations;
  final int total;
  final String currency;
  final Color centerColor;
  final Color labelColor;
  final double progress;

  static const _nodeWidth = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0 || size.isEmpty) return;
    final compact = size.width < 560;
    final top = compact ? 40.0 : 16.0;
    const bottom = 16.0;
    final height = size.height - top - bottom;
    final sourceX = compact ? 12.0 : math.min(136.0, size.width * 0.22);
    final centerX = size.width * 0.46;
    final destinationX = compact
        ? size.width - 22
        : size.width - math.min(164.0, size.width * 0.26);
    final sourceRects = _nodeRects(sources, sourceX, height, top);
    final destinationRects =
        _nodeRects(destinations, destinationX, height, top);
    final center = Rect.fromLTWH(centerX, top, _nodeWidth, height);

    var centerSourceY = center.top;
    for (var index = 0; index < sources.length; index++) {
      final row = sources[index];
      final centerHeight = height * row.amount / total;
      _drawRibbon(
        canvas,
        start: Offset(sourceRects[index].right, sourceRects[index].center.dy),
        startHeight: sourceRects[index].height * progress,
        end: Offset(center.left, centerSourceY + centerHeight / 2),
        endHeight: centerHeight * progress,
        color: row.color,
      );
      centerSourceY += centerHeight;
    }

    var centerDestinationY = center.top;
    for (var index = 0; index < destinations.length; index++) {
      final row = destinations[index];
      final centerHeight = height * row.amount / total;
      _drawRibbon(
        canvas,
        start: Offset(center.right, centerDestinationY + centerHeight / 2),
        startHeight: centerHeight * progress,
        end: Offset(
            destinationRects[index].left, destinationRects[index].center.dy),
        endHeight: destinationRects[index].height * progress,
        color: row.color,
      );
      centerDestinationY += centerHeight;
    }

    for (var index = 0; index < sources.length; index++) {
      _drawNode(canvas, sourceRects[index], sources[index].color);
    }
    _drawNode(canvas, center, centerColor);
    for (var index = 0; index < destinations.length; index++) {
      _drawNode(canvas, destinationRects[index], destinations[index].color);
    }

    if (compact) {
      _drawCompactHeader(canvas, size, 'INCOME', TextAlign.left);
      _drawCompactHeader(canvas, size, 'SPENDING & SAVINGS', TextAlign.right);
      return;
    }

    var nextSourceLabelY = 0.0;
    for (var index = 0; index < sources.length; index++) {
      final labelY =
          math.max(sourceRects[index].center.dy - 15, nextSourceLabelY);
      _drawLabel(
        canvas,
        row: sources[index],
        x: 0,
        y: labelY,
        width: sourceX - 12,
        canvasHeight: size.height,
        align: TextAlign.right,
      );
      nextSourceLabelY = labelY + 32;
    }
    var nextDestinationLabelY = 0.0;
    for (var index = 0; index < destinations.length; index++) {
      final labelY = math.max(
          destinationRects[index].center.dy - 15, nextDestinationLabelY);
      _drawLabel(
        canvas,
        row: destinations[index],
        x: destinationX + 16,
        y: labelY,
        width: size.width - destinationX - 18,
        canvasHeight: size.height,
        align: TextAlign.left,
      );
      nextDestinationLabelY = labelY + 32;
    }
  }

  void _drawNode(Canvas canvas, Rect rect, Color color) {
    final animated = Rect.fromCenter(
      center: rect.center,
      width: rect.width,
      height: math.max(1, rect.height * progress),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(animated, const Radius.circular(5)),
      Paint()..color = color,
    );
  }

  List<Rect> _nodeRects(
      List<_FlowRow> rows, double x, double height, double top) {
    if (rows.isEmpty) return [];
    const gap = 8.0;
    final available = math.max(height - gap * (rows.length - 1), 1.0);
    var y = top;
    return rows.map((row) {
      final rowHeight = available * row.amount / total;
      final rect = Rect.fromLTWH(x, y, _nodeWidth, rowHeight);
      y += rowHeight + gap;
      return rect;
    }).toList();
  }

  void _drawRibbon(
    Canvas canvas, {
    required Offset start,
    required double startHeight,
    required Offset end,
    required double endHeight,
    required Color color,
  }) {
    final controlX = (start.dx + end.dx) / 2;
    final path = Path()
      ..moveTo(start.dx, start.dy - startHeight / 2)
      ..cubicTo(controlX, start.dy - startHeight / 2, controlX,
          end.dy - endHeight / 2, end.dx, end.dy - endHeight / 2)
      ..lineTo(end.dx, end.dy + endHeight / 2)
      ..cubicTo(controlX, end.dy + endHeight / 2, controlX,
          start.dy + startHeight / 2, start.dx, start.dy + startHeight / 2)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.34));
  }

  void _drawCompactHeader(
      Canvas canvas, Size size, String text, TextAlign align) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: labelColor.withValues(alpha: 0.72),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.46);
    painter.paint(
      canvas,
      Offset(align == TextAlign.left ? 0 : size.width - painter.width, 5),
    );
  }

  void _drawLabel(
    Canvas canvas, {
    required _FlowRow row,
    required double x,
    required double y,
    required double width,
    required double canvasHeight,
    required TextAlign align,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        style: TextStyle(color: labelColor, fontSize: 12, height: 1.2),
        children: [
          TextSpan(text: '${row.label}\n'),
          TextSpan(
            text: _money(row.amount, currency),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: math.max(width, 1));
    painter.paint(
      canvas,
      Offset(x, y.clamp(0, canvasHeight - painter.height).toDouble()),
    );
  }

  @override
  bool shouldRepaint(covariant _SankeyPainter oldDelegate) =>
      oldDelegate.sources != sources ||
      oldDelegate.destinations != destinations ||
      oldDelegate.total != total ||
      oldDelegate.currency != currency ||
      oldDelegate.centerColor != centerColor ||
      oldDelegate.labelColor != labelColor ||
      oldDelegate.progress != progress;
}

String _money(int minorUnits, String currency) =>
    '$currency ${NumberFormat.currency(
      symbol: '',
      decimalDigits: 2,
    ).format(minorUnits / 100).trim()}';

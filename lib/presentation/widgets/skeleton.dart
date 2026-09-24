import 'package:flutter/material.dart';

/// One static skeleton row — the placeholder shape of a task list item.
///
/// Deliberately not animated: an animation controller per list would cost
/// more than the content it mimics, and a static skeleton keeps widget
/// tests deterministic. Rows are wrapped in [ExcludeSemantics]; the
/// surrounding [ListSkeleton] announces "Loading".
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 48, height: 56),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 16,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 10),
                FractionallySizedBox(
                  widthFactor: 0.6,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder list while a stream loads. Visually matches [ListView.builder]
/// rows: fixed-height decorations only, so it never interferes with text
/// scaling.
class ListSkeleton extends StatelessWidget {
  /// Creates the skeleton list.
  const ListSkeleton({super.key, this.count = 6, this.semanticLabel = 'Loading'});

  /// How many rows to draw.
  final int count;

  /// What assistive technology announces.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        itemBuilder: (context, index) =>
            const ExcludeSemantics(child: _SkeletonRow()),
      ),
    );
  }
}

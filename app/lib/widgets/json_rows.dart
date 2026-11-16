import 'package:flutter/material.dart';

import '../core/json.dart';
import '../core/theme/app_theme.dart';

/// A JSON object as readable key/value rows; nested values are pretty-printed in DM Mono.
class JsonRows extends StatelessWidget {
  const JsonRows(this.data, {super.key});
  final Json data;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const Text('(empty payload)');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final e in data.entries) KeyValueRow(label: e.key, value: e.value)],
    );
  }
}

/// One labelled value. [mono] renders the value in DM Mono (ids, codes, timestamps);
/// nested JSON is always mono.
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({super.key, required this.label, required this.value, this.mono = false});
  final String label;
  final Object? value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final nested = value is Map || value is List;
    final text = value == null ? '-' : (nested ? prettyJson.convert(value) : value.toString());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(text, style: nested || mono ? AppTheme.mono(context) : null),
        ],
      ),
    );
  }
}

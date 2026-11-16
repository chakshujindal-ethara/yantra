import 'package:flutter/material.dart';

import '../format.dart';

/// A day typed as `2026-11-30` or picked from the themed calendar. The text stays the source of truth so a
/// keyboard user never needs the picker; [validator] sees the text, [parseDay] turns it into a UTC midnight.
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.controller,
    required this.label,
    this.helper,
    this.first,
    this.last,
    this.fieldKey,
    this.pickKey,
    this.optional = true,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;

  /// The earliest and latest day the calendar offers; defaults to a year either side of today.
  final DateTime? first;
  final DateTime? last;
  final Key? fieldKey;
  final Key? pickKey;

  /// An empty field is valid (the value is "none").
  final bool optional;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final first = this.first ?? now.subtract(const Duration(days: 365));
    final last = this.last ?? now.add(const Duration(days: 365));
    DateTime? current;
    try {
      current = parseDay(controller.text, label: label);
    } on FormatException {
      current = null;
    }
    var initial = current ?? now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(context: context, initialDate: initial, firstDate: first, lastDate: last, helpText: label);
    if (picked != null) controller.text = dayText(DateTime.utc(picked.year, picked.month, picked.day));
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: fieldKey,
      controller: controller,
      keyboardType: TextInputType.datetime,
      validator: (v) {
        final t = (v ?? '').trim();
        if (t.isEmpty) return optional ? null : '$label is required';
        try {
          parseDay(t, label: label);
          return null;
        } on FormatException catch (e) {
          return e.message;
        }
      },
      decoration: InputDecoration(
        labelText: optional ? '$label (optional)' : label,
        hintText: 'YYYY-MM-DD',
        helperText: helper,
        suffixIcon: IconButton(
          key: pickKey,
          tooltip: 'Pick a day',
          icon: const Icon(Icons.calendar_today_outlined, size: 18),
          onPressed: () => _pick(context),
        ),
      ),
    );
  }
}

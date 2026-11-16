import 'package:flutter/material.dart';

/// The currencies Yantra prices and pays in. INR first: pay is rupees to Indian bank accounts.
const supportedCurrencies = ['INR', 'USD', 'EUR', 'GBP'];

/// A currency picked from the list, never typed. An unknown value the record already carries (an older
/// project in another code) is kept as an extra option instead of throwing.
class CurrencyField extends StatelessWidget {
  const CurrencyField({super.key, required this.value, required this.onChanged, this.label = 'Currency', this.enabled = true});

  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final options = [...supportedCurrencies, if (value.isNotEmpty && !supportedCurrencies.contains(value)) value];
    return DropdownButtonFormField<String>(
      initialValue: value.isEmpty ? supportedCurrencies.first : value,
      decoration: InputDecoration(labelText: label),
      items: [for (final c in options) DropdownMenuItem(value: c, child: Text(c))],
      onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
    );
  }
}

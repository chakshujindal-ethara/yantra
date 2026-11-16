/// Money for display, one formatter for the whole app.
///
/// The gateway sends amounts as decimal strings with up to six places ("30.000000"). INR (and an amount
/// with no currency) reads the Indian way, `₹12,50,000.00`; other known currencies carry their symbol and
/// Western grouping, `$1,250,000.00`; an unknown code goes before the figure, `AED 1,250.00`. A string
/// that is not a number is shown as it came, so a surprising payload is still visible rather than "-".
library;

const _symbols = {'INR': '₹', 'USD': r'$', 'EUR': '€', 'GBP': '£'};

String formatMoney(String amount, {String currency = '', int decimals = 2}) {
  final text = amount.trim();
  final code = currency.trim().toUpperCase();
  final value = double.tryParse(text);
  if (value == null) return code.isEmpty || text.isEmpty ? text : '$code $text';
  return _withCurrency(_grouped(value.abs().toStringAsFixed(decimals), indian: code.isEmpty || code == 'INR'), code, negative: value < 0);
}

/// `₹28–40`: whole numbers without decimals, a single figure when the range has no spread.
String payRange(String min, String max, {String currency = ''}) {
  final code = currency.trim().toUpperCase();
  final indian = code.isEmpty || code == 'INR';
  String figure(String s) {
    final v = double.tryParse(s.trim());
    if (v == null) return s.trim();
    return _grouped(v == v.roundToDouble() ? v.round().abs().toString() : v.abs().toStringAsFixed(2), indian: indian);
  }

  final lo = figure(min);
  final hi = figure(max);
  final body = lo.isEmpty ? hi : (hi.isEmpty || hi == lo ? lo : '$lo–$hi');
  return body.isEmpty ? '' : _withCurrency(body, code, negative: false);
}

String _withCurrency(String figure, String code, {required bool negative}) {
  final sign = negative ? '-' : '';
  final symbol = _symbols[code];
  if (symbol != null) return '$sign$symbol$figure';
  return code.isEmpty ? '$sign$figure' : '$code $sign$figure';
}

/// Groups the integer part of a non-negative decimal string: 3 then 2s (Indian) or 3s (Western).
String _grouped(String fixed, {required bool indian}) {
  final dot = fixed.indexOf('.');
  final whole = dot < 0 ? fixed : fixed.substring(0, dot);
  final fraction = dot < 0 ? '' : fixed.substring(dot);
  if (whole.length <= 3) return '$whole$fraction';
  final last = whole.substring(whole.length - 3);
  var rest = whole.substring(0, whole.length - 3);
  final step = indian ? 2 : 3;
  final parts = <String>[];
  while (rest.length > step) {
    parts.insert(0, rest.substring(rest.length - step));
    rest = rest.substring(0, rest.length - step);
  }
  if (rest.isNotEmpty) parts.insert(0, rest);
  return '${parts.join(',')},$last$fraction';
}

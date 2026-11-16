import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/money.dart';

void main() {
  test('amounts are shown with two decimals and Indian grouping by default', () {
    expect(formatMoney('30.000000'), '30.00');
    expect(formatMoney('28'), '28.00');
    expect(formatMoney('1000.5'), '1,000.50');
    expect(formatMoney('12.505'), '12.51');
    expect(formatMoney('1250000'), '12,50,000.00');
    expect(formatMoney('123456789.1'), '12,34,56,789.10');
  });

  test('INR shows the rupee sign with lakh and crore grouping', () {
    expect(formatMoney('30.000000', currency: 'INR'), '₹30.00');
    expect(formatMoney('1250000', currency: 'inr'), '₹12,50,000.00');
    expect(formatMoney('-1250.5', currency: 'INR'), '-₹1,250.50');
    expect(formatMoney('999', currency: 'INR'), '₹999.00');
  });

  test('other known currencies use their symbol and Western grouping', () {
    expect(formatMoney('1250000', currency: 'USD'), r'$1,250,000.00');
    expect(formatMoney('3', currency: 'EUR'), '€3.00');
    expect(formatMoney('1234.5', currency: 'GBP'), '£1,234.50');
  });

  test('an unknown code is shown before the figure, Western grouping', () {
    expect(formatMoney('1250', currency: 'AED'), 'AED 1,250.00');
    expect(formatMoney('12.50', currency: ' '), '12.50');
  });

  test('decimals can be dropped for charts', () {
    expect(formatMoney('1250000.4', currency: 'INR', decimals: 0), '₹12,50,000');
    expect(formatMoney('12.5', decimals: 1), '12.5');
  });

  test('a non-numeric amount falls back to the raw text', () {
    expect(formatMoney('n/a'), 'n/a');
    expect(formatMoney('n/a', currency: 'INR'), 'INR n/a');
    expect(formatMoney(''), '');
    expect(formatMoney('', currency: 'INR'), '');
  });

  test('payRange: symbol, whole numbers, one figure without spread', () {
    expect(payRange('25.000000', '40', currency: 'INR'), '₹25–40');
    expect(payRange('18', '18', currency: 'INR'), '₹18');
    expect(payRange('', '40', currency: 'USD'), r'$40');
    expect(payRange('2.5', '4', currency: 'AED'), 'AED 2.50–4');
    expect(payRange('1500', '25000', currency: 'INR'), '₹1,500–25,000');
    expect(payRange('x', '', currency: ''), 'x');
  });
}

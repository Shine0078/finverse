import 'package:flutter_test/flutter_test.dart';
import 'package:finverse/screens/manual_transaction_screen.dart';

void main() {
  test('manual amounts preserve exact currency precision', () {
    expect(parseManualAmount('12.34', 2), 1234);
    expect(parseManualAmount('1.005', 3), 1005);
    expect(parseManualAmount('125', 0), 125);
    expect(parseManualAmount('0.0001', 4), 1);
    expect(parseManualAmount('1.005', 2), isNull);
    expect(parseManualAmount('1.00', 0), isNull);
    for (final invalid in ['0', '-12', 'NaN', '1e3', '1,234', '1000000000000000']) {
      expect(parseManualAmount(invalid, 2), isNull);
    }
  });
}

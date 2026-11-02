import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

void main() {
  test('parse, toString and scale-independent equality', () {
    expect(DecimalValue.parse('-123.450').toString(), '-123.450');
    expect(DecimalValue.parse('10').scale, 0);
    expect(DecimalValue.parse('.5').toString(), '0.5');
    expect(DecimalValue.parse('1.50'), DecimalValue.parse('1.5'));
    expect(DecimalValue.parse('1.50').hashCode,
        DecimalValue.parse('1.5').hashCode);
    expect(() => DecimalValue.parse('1.2.3'), throwsFormatException);
  });
}

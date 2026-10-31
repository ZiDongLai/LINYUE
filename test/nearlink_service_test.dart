import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/nearlink_service.dart';

void main() {
  test('sanitizes path traversal and Windows special characters', () {
    expect(sanitizeFileName('../bad\\name?.txt'), '.._bad_name_.txt');
    expect(sanitizeFileName('..'), 'unnamed_file');
    expect(sanitizeFileName(''), 'unnamed_file');
  });

  test('manual IPv4 parser rejects invalid IPs', () {
    expect(isValidIpv4('192.168.1.10'), isTrue);
    expect(isValidIpv4('192.168.1.999'), isFalse);
    expect(isValidIpv4('127.0.0'), isFalse);
    expect(isValidIpv4('01.2.3.4'), isFalse);
  });

  test('token is random hex with required size', () {
    final a = randomHex(24);
    final b = randomHex(24);
    expect(a.length, 48);
    expect(a, matches(RegExp(r'^[0-9a-f]+$')));
    expect(a, isNot(b));
  });
}

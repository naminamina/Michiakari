import 'package:flutter_test/flutter_test.dart';
import 'package:michiakari/main.dart';

void main() {
  test('app widget can be constructed', () {
    expect(
      const NavigationLanternApp(accessToken: ''),
      isA<NavigationLanternApp>(),
    );
  });
}

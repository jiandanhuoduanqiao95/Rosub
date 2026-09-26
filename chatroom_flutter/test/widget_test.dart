import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/main.dart';

void main() {
  testWidgets('shows login screen', (tester) async {
    await tester.pumpWidget(const ChatroomApp());

    expect(find.text('Rosub'), findsOneWidget);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('没有账号？注册'), findsOneWidget);
  });
}

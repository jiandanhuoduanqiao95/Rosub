import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/main.dart';

void main() {
  testWidgets('shows login screen', (tester) async {
    await tester.pumpWidget(const ChatroomApp());

    expect(find.text('聊天室'), findsOneWidget);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('没有账号？注册'), findsOneWidget);
  });
}

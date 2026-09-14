import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'ui/theme.dart';

void main() => runApp(const MailNetApp());

class MailNetApp extends StatelessWidget {
  const MailNetApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MailNet',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const LoginScreen(),
      );
}

import 'package:material_ui/material_ui.dart';

import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenterritorioApp());
}

class OpenterritorioApp extends StatelessWidget {
  const OpenterritorioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OPENTERITORIO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0F14),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF35C2FF),
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101722),
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

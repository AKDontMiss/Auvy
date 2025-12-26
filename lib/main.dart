import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/main_layout.dart';

// Entry point of the application.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Restrict the app to portrait mode for a consistent layout.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const ProviderScope(child: MyApp()));
}

// Root widget that initializes the application theme and initial screen.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Auvy', 
      theme: ThemeData.dark(),
      home: const MainLayout(),
    );
  }
}
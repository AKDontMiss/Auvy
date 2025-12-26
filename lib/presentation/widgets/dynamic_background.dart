import 'package:flutter/material.dart';

// Wrapper widget that provides a consistent tiled background pattern for the app.
class DynamicBackground extends StatelessWidget {
  final Widget child;

  const DynamicBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.black, 
        image: DecorationImage(
          // Uses a repeating pattern image to fill the background.
          image: AssetImage('assets/images/bg_pattern.png'),
          fit: BoxFit.none, 
          repeat: ImageRepeat.repeat, 
          opacity: 0.4, 
        ),
      ),
      child: child,
    );
  }
}
import 'package:flutter/material.dart';

// Universal image component that handles both local assets and network URLs.
class AuvyImage extends StatelessWidget {
  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;

  const AuvyImage({
    super.key, 
    required this.path, 
    this.width, 
    this.height, 
    this.fit = BoxFit.cover, 
  });

  @override
  Widget build(BuildContext context) {
    Widget image;
    final cleanPath = path.trim();

    // Determine if the source is a local asset or a network URL.
    if (cleanPath.startsWith('assets/')) {
      image = Image.asset(
        cleanPath, 
        width: width, 
        height: height, 
        fit: fit, 
        errorBuilder: (c, e, s) => Container(
          color: Colors.grey[900], 
          width: width, 
          height: height, 
          child: const Icon(Icons.broken_image, color: Colors.white24)
        ),
      );
    } else {
      image = Image.network(
        cleanPath, 
        width: width, 
        height: height, 
        fit: fit, 
        errorBuilder: (c, e, s) => Container(
          color: Colors.grey[900], 
          width: width, 
          height: height, 
          child: const Icon(Icons.music_note, color: Colors.white24)
        ),
      );
    }

    // Apply a standard rounded corner to all images.
    return ClipRRect(
      borderRadius: BorderRadius.circular(35),
      child: image,
    );
  }
}
# Auvy

**Auvy** is a minimalist, high-performance music streaming application built with Flutter. Developed as a hobby project by an aspiring electrical engineer, the app focuses on clean system architecture, efficient data pipelines, and a fluid user experience.

---

### 🚧 Project Status: Work in Progress
**Much is to be done yet.** This application is currently in active development. While the core streaming engine and UI are functional, many features are still being refined, and new capabilities are being integrated regularly.

---

## 🎧 Overview

Auvy aggregates metadata and audio streams from multiple platforms into a single, cohesive interface. By leveraging reactive state management and a multi-client stream extraction strategy, it provides a seamless listening experience without the clutter of traditional streaming apps.

## ✨ Key Features

* **Intelligent Music Discovery**: A dynamic home feed that generates "Quick Picks" and personalized sections based on listening history and user-selected moods such as "Relax," "Focus," or "Energize".
* **Unified Search Engine**: A comprehensive search system that categorizes results into songs, artists, albums, and playlists by pulling data from diverse music APIs.
* **Time-Synced Lyrics**: Integrated support for synchronized lyrics that automatically scroll in tandem with audio playback for an immersive experience.
* **Advanced Queue Management**: Flexible control allowing users to toggle between a "Manual Mode" for precise queueing and an "Autofill" mode that automatically suggests related tracks.
* **Library & Persistence**: Full support for user-curated data, including liked songs, subscribed artists, and custom playlists, all persisted locally for a consistent experience.

### Audio Pipeline & Stream Extraction
Auvy utilizes a sophisticated multi-client strategy to ensure stable playback. The application cycles through various internal API configurations—including TV, Desktop, and Mobile identities—to resolve the highest quality raw audio streams available.

### Reactive State Architecture
The application is built on **Riverpod**, ensuring the UI remains synchronized with the underlying audio engine in real-time.
* **Proactive Buffer Recovery**: The system monitors audio buffer health and proactively re-resolves stream URLs if a potential interruption is detected, preventing playback gaps.
* **Audio Visualizer Engine**: The player provides real-time audio intensity data used to drive reactive UI elements and waveforms.

### UI & Motion Design
The interface is designed for tactile feedback and high scannability:
* **3D Motion**: A 3D flip animation allows users to switch seamlessly between album artwork and the lyrics viewer.
* **Gesture Controls**: Support for horizontal swipes for track skipping, double-taps for seeking, and long-presses for playback speed adjustments.
* **Dynamic Components**: Features an animated mini-player with rotating artwork and responsive equalizer waveforms.

---
*Created by an aspiring electrical engineer. This project is a labor of love and remains under constant development.*

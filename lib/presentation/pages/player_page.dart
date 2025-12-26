import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/logic/lyrics_provider.dart';
import 'package:auvy/logic/library_provider.dart';
import 'package:auvy/data/lyrics_model.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/player_menu_sheet.dart'; 
import 'package:auvy/presentation/widgets/animated_toast.dart'; 

// Full-screen music player screen providing detailed controls, lyrics, and queue management.
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> with TickerProviderStateMixin {
  late AnimationController _flipController;
  late Animation<double> _flipAnimation;
  double _currentAngle = 0.0;
  double _targetAngle = 0.0;

  double _dragOffset = 0.0;
  late AnimationController _slideRecenterController;
  late Animation<double> _slideAnimation;

  final List<RippleModel> _ripples = [];
  late AnimationController _rippleController;

  bool _showLeftFeedback = false; 
  bool _showRightFeedback = false; 
  bool _isSpeedingUp = false;      
  Timer? _feedbackTimer;

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _slideRecenterController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _rippleController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..addListener(() {
      setState(() { _ripples.removeWhere((r) => r.animationValue >= 1.0); });
    });
  }

  @override
  void dispose() {
    _flipController.dispose();
    _slideRecenterController.dispose();
    _rippleController.dispose();
    _feedbackTimer?.cancel();
    super.dispose();
  }

  // Triggers temporary visual feedback icons for fast-forward and rewind actions.
  void _triggerFeedback(bool isLeft) { setState(() { if (isLeft) { _showLeftFeedback = true; _showRightFeedback = false; } else { _showRightFeedback = true; _showLeftFeedback = false; } }); _feedbackTimer?.cancel(); _feedbackTimer = Timer(const Duration(milliseconds: 600), () { if (mounted) setState(() { _showLeftFeedback = false; _showRightFeedback = false; }); }); }
  
  // Initiates the 3D flip animation between artwork and lyrics.
  void _handleFlip(double velocity) { double direction = velocity < 0 ? 1.0 : -1.0; _targetAngle += direction * pi; _flipAnimation = Tween<double>(begin: _currentAngle, end: _targetAngle).animate(CurvedAnimation(parent: _flipController, curve: Curves.easeOutBack)); _flipController.reset(); _flipController.forward(); _currentAngle = _targetAngle; }
  
  // Creates an expanding ripple effect on the screen.
  void _triggerRipple() { setState(() { _ripples.add(RippleModel(startTime: DateTime.now().millisecondsSinceEpoch)); }); if (!_rippleController.isAnimating) _rippleController.repeat(); }
  
  // Handles track skipping or recentering the song title based on horizontal swipe distance.
  void _handleDragEnd(double screenWidth, PlayerNotifier notifier) { final threshold = screenWidth / 3; if (_dragOffset.abs() > threshold) { if (_dragOffset < 0) notifier.playNext(); else notifier.playPrevious(); } _slideAnimation = Tween<double>(begin: _dragOffset, end: 0).animate(CurvedAnimation(parent: _slideRecenterController, curve: Curves.easeOut)); _slideRecenterController.reset(); _slideRecenterController.forward(); _slideRecenterController.addListener(() => setState(() => _dragOffset = _slideAnimation.value)); }
  
  // Opens a sheet to adjust the audio playback speed.
  void _showSpeedMenu(BuildContext context, PlayerNotifier notifier) { HapticFeedback.mediumImpact(); showModalBottomSheet(context: context, backgroundColor: const Color(0xFF1E1E1E), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) { return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [const SizedBox(height: 10), Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(2))), const Padding(padding: EdgeInsets.all(16), child: Text("Playback Speed", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))), _buildSpeedOption(ctx, notifier, 0.5), _buildSpeedOption(ctx, notifier, 1.0), _buildSpeedOption(ctx, notifier, 1.5), _buildSpeedOption(ctx, notifier, 2.0), _buildSpeedOption(ctx, notifier, 3.0), const SizedBox(height: 20)])); }); }
  
  // Sub-widget for selecting a specific playback speed option.
  Widget _buildSpeedOption(BuildContext context, PlayerNotifier notifier, double speed) { return ListTile(title: Text("${speed}x", style: const TextStyle(color: Colors.white)), onTap: () { notifier.setSpeed(speed); Navigator.pop(context); }); }

  // Opens a modal sheet for viewing and reordering upcoming tracks in the queue.
  void _showQueueSheet(BuildContext context) {
    showModalBottomSheet(
      context: context, 
      backgroundColor: Colors.transparent, 
      isScrollControlled: true, 
      builder: (context) { 
        return DraggableScrollableSheet(
          initialChildSize: 0.6, 
          minChildSize: 0.4, 
          maxChildSize: 0.9, 
          builder: (context, scrollController) { 
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E1E), 
                borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))
              ), 
              child: Column(
                children: [
                  Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 16), decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(2)))), 
                  
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Up Next", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        Consumer(builder: (context, ref, _) {
                          final isManual = ref.watch(playerProvider.select((s) => s.isManualMode));
                          
                          return InkWell(
                            onTap: () {
                              ref.read(playerProvider.notifier).toggleManualMode();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: isManual ? const Color(0xFFFD9A01) : Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Icon(isManual ? Icons.edit_note : Icons.auto_awesome, color: isManual ? Colors.black : Colors.white70, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    isManual ? "MANUAL" : "AUTOFILL", 
                                    style: TextStyle(color: isManual ? Colors.black : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  
                  Expanded(
                    child: Consumer(
                      builder: (context, ref, child) {
                        final playerState = ref.watch(playerProvider);
                        final notifier = ref.read(playerProvider.notifier);
                        final currentIndex = playerState.currentIndex;
                        final queue = playerState.queue;
                        final futureTracks = (currentIndex + 1 < queue.length) ? queue.sublist(currentIndex + 1) : <Song>[];
                        
                        if (futureTracks.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32.0),
                              child: Text(
                                playerState.isManualMode ? "Empty queue. Add songs manually." : "Filling upcoming tracks...", 
                                style: const TextStyle(color: Colors.grey),
                                textAlign: TextAlign.center
                              ),
                            )
                          );
                        }
                        
                        return ReorderableListView.builder(
                          scrollController: scrollController,
                          buildDefaultDragHandles: false, 
                          onReorder: (oldIndex, newIndex) => notifier.reorderQueue(oldIndex, newIndex), 
                          itemCount: futureTracks.length, 
                          itemBuilder: (context, index) { 
                            final song = futureTracks[index]; 
                            return ListTile(
                              key: ValueKey('queue_${song.id}_$index'), 
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(4), 
                                child: (song.image.isNotEmpty && song.image.startsWith('http')) 
                                  ? Image.network(song.image, width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey[800],width:40,height:40)) 
                                  : Container(color:Colors.grey[800],width:40,height:40)
                              ), 
                              title: Text(song.title, style: const TextStyle(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis), 
                              subtitle: Text(song.artist, style: const TextStyle(color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis), 
                              trailing: ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle, color: Colors.white54, size: 24)),
                            ); 
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(playerProvider);
    final song = ps.currentSong;
    final lyricsAsync = ref.watch(lyricsProvider);
    final notifier = ref.read(playerProvider.notifier);
    final isLiked = ref.watch(libraryProvider.select((s) => s.likedSongIds.contains(song?.id ?? '')));
    final screenWidth = MediaQuery.of(context).size.width;

    if (song == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                children: [
                  Positioned(bottom: 0, left: 0, right: 0, height: 475, child: Opacity(opacity: 0.15, child: VisualWaveform(isPlaying: ps.isPlaying, intensity: ps.audioIntensity))),
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 30), onPressed: () => Navigator.pop(context)),
                            Expanded(child: Column(children: [Text("PLAYING FROM ${ps.playbackSource.toUpperCase()}", style: const TextStyle(color: Colors.white70, fontSize: 10, letterSpacing: 1)), Text(song.albumTitle.isNotEmpty ? song.albumTitle : song.artist, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis)])),
                            IconButton(icon: const Icon(Icons.more_vert, color: Colors.white), onPressed: () => showModalBottomSheet(context: context, backgroundColor: Colors.transparent, isScrollControlled: true, builder: (context) => PlayerMenuSheet(song: song))),
                          ],
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onHorizontalDragEnd: (details) {
                            final vel = details.primaryVelocity ?? 0;
                            if (vel.abs() > 300) _handleFlip(vel);
                          },
                          child: AnimatedBuilder(
                            animation: _flipController,
                            builder: (context, child) {
                              final angle = _flipController.isAnimating ? _flipAnimation.value : _currentAngle;
                              final isBack = (angle / pi).round().isOdd;
                              final transform = Matrix4.identity()..setEntry(3, 2, 0.001)..rotateY(angle);
                              if (isBack) transform.rotateY(pi);
                              return Transform(transform: transform, alignment: Alignment.center, child: isBack ? _buildLyricsCard(lyricsAsync, ps.position, notifier) : _buildArtworkCard(song.image));
                            },
                          ),
                        ),
                      ),
                      _buildControls(context, ps, song, notifier, isLiked, screenWidth),
                    ],
                  ),
                ],
              );
            }
          ),
        ),
      ),
    );
  }

  // Generates the control panel containing buttons for play, shuffle, loop, and progress navigation.
  Widget _buildControls(BuildContext context, PlayerState ps, Song song, PlayerNotifier notifier, bool isLiked, double screenWidth) {
    return Container(
      padding: const EdgeInsets.only(bottom: 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: GestureDetector(behavior: HitTestBehavior.translucent, onDoubleTap: () { notifier.seekBackward(); _triggerFeedback(true); }, onLongPress: () => _showSpeedMenu(context, notifier), child: Container(height: 65, alignment: Alignment.center, child: _showLeftFeedback ? const _FeedbackIcon(icon: Icons.replay_5, text: "-5s") : null))),
              SizedBox(width: 150, child: Column(children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [GestureDetector(onTapDown: (details) { ref.read(libraryProvider.notifier).toggleSongLike(song); }, child: Padding(padding: const EdgeInsets.all(8.0), child: Icon(isLiked ? Icons.favorite : Icons.favorite_border, color: isLiked ? Color(0xFFFD9A01) : Colors.white, size: 26))), IconButton(onPressed: () => _showQueueSheet(context), icon: const Icon(Icons.queue_music, color: Colors.white, size: 26))]), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [IconButton(icon: Icon(Icons.shuffle, color: ps.isShuffle ? Color(0xFFFD9A01) : Colors.white, size: 26), onPressed: () => notifier.toggleShuffle()), IconButton(icon: Icon(ps.loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat, color: ps.loopMode != LoopMode.off ? Color(0xFFFD9A01) : Colors.white, size: 26), onPressed: () => notifier.cycleLoopMode())])])),
              Expanded(child: GestureDetector(behavior: HitTestBehavior.translucent, onDoubleTap: () { notifier.seekForward(); _triggerFeedback(false); }, onLongPressStart: (_) { notifier.setSpeed(2.0); setState(() => _isSpeedingUp = true); }, onLongPressEnd: (_) { notifier.setSpeed(1.0); setState(() => _isSpeedingUp = false); }, child: Container(height: 65, alignment: Alignment.center, child: _showRightFeedback ? const _FeedbackIcon(icon: Icons.forward_5, text: "+5s") : (_isSpeedingUp ? const _FeedbackIcon(icon: Icons.fast_forward, text: "2x") : null)))),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(children: [
              SliderTheme(data: SliderTheme.of(context).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: Colors.white, inactiveTrackColor: Colors.white24, thumbColor: Colors.white), child: Slider(value: ps.progress.clamp(0.0, 1.0), onChanged: (val) => notifier.seek(val))),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_formatDuration(ps.position), style: const TextStyle(color: Colors.white70, fontSize: 11)), Text(_formatDuration(ps.duration), style: const TextStyle(color: Colors.white70, fontSize: 11))]),
            ]),
          ),
          GestureDetector(onHorizontalDragUpdate: (d) => setState(() => _dragOffset += d.delta.dx), onHorizontalDragEnd: (d) => _handleDragEnd(screenWidth, notifier), onTap: () { _triggerRipple(); notifier.togglePlay(); }, child: CustomPaint(painter: WaterRipplePainter(_ripples, DateTime.now().millisecondsSinceEpoch), child: Container(width: double.infinity, height: 80, color: Colors.transparent, child: Center(child: Transform.translate(offset: Offset(_dragOffset, 0), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [SizedBox(width: screenWidth * 0.8, child: Center(child: MarqueeText(text: song.title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)))), const SizedBox(height: 2), Text(song.artist, style: const TextStyle(color: Colors.white70, fontSize: 16)), if (ps.isPlaying) const Icon(Icons.equalizer, color: Color(0xFFFD9A01), size: 14)])))))),
        ],
      ),
    );
  }

  // Generates the album art card with shadows and rounded corners.
  Widget _buildArtworkCard(String imageUrl) { return Padding(padding: const EdgeInsets.all(24.0), child: Center(child: AspectRatio(aspectRatio: 1, child: Hero(tag: 'current_artwork', child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 10))], image: DecorationImage(image: NetworkImage(imageUrl), fit: BoxFit.cover))))))); }
  
  // Generates the lyrics card with automated scrolling to match current playback time.
  Widget _buildLyricsCard(AsyncValue<LyricsData?> lyricsAsync, Duration pos, PlayerNotifier n) { return Container(margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10), decoration: BoxDecoration(color: Colors.black.withOpacity(0.3), borderRadius: BorderRadius.circular(16)), child: lyricsAsync.when(data: (l) => (l == null || l.lines.isEmpty) ? const Center(child: Text("No lyrics", style: TextStyle(color: Colors.white))) : LyricsViewer(lyrics: l, currentPosition: pos, onLineTapped: (t) => n.seek(t)), loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF53B1E1))), error: (e, s) => const Center(child: Text("Error", style: TextStyle(color: Colors.red))))); }
  
  // Converts a Duration object into a human-readable mm:ss string.
  String _formatDuration(Duration d) { final s = d.inSeconds.remainder(60).toString().padLeft(2, '0'); return "${d.inMinutes}:$s"; }
}

// Visual component that renders an animated equalizer-style waveform background.
class VisualWaveform extends StatefulWidget {
  final bool isPlaying; final double intensity;
  const VisualWaveform({super.key, required this.isPlaying, required this.intensity});
  @override State<VisualWaveform> createState() => _VisualWaveformState();
}
class _VisualWaveformState extends State<VisualWaveform> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override void initState() { super.initState(); _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(); }
  @override void didUpdateWidget(VisualWaveform old) { super.didUpdateWidget(old); if (widget.isPlaying) _controller.repeat(); else _controller.stop(); }
  @override void dispose() { _controller.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) { return AnimatedBuilder(animation: _controller, builder: (c, h) => CustomPaint(painter: WaveformPainter(_controller.value, widget.isPlaying, widget.intensity))); }
}

// Custom painter used to draw individual bars of the audio waveform visualizer.
class WaveformPainter extends CustomPainter {
  final double animation; final bool isPlaying; final double intensity;
  WaveformPainter(this.animation, this.isPlaying, this.intensity);
  @override void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white..strokeWidth = 3..style = PaintingStyle.fill;
    final barCount = 40; final spacing = size.width / barCount;
    for (int i = 0; i < barCount; i++) {
      double h = isPlaying ? (10 + (intensity * 60) + sin((animation * pi * 4) + (i * 0.5)) * (10 + (intensity * 60) * 0.2)) : 4;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(i * spacing, size.height / 2), width: 4, height: h.abs()), const Radius.circular(2)), paint);
    }
  }
  @override bool shouldRepaint(covariant WaveformPainter old) => true;
}

// Small UI element displayed temporarily when seeking forward or backward.
class _FeedbackIcon extends StatelessWidget { 
  final IconData icon; final String text; 
  const _FeedbackIcon({required this.icon, required this.text}); 
  @override Widget build(BuildContext context) { 
    return Container(
      padding: const EdgeInsets.all(8), 
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(50)), 
      child: Column(
        mainAxisSize: MainAxisSize.min, 
        children: [
          Icon(icon, color: Colors.white, size: 24), 
          Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10))
        ]
      )
    ); 
  } 
}

// Model for managing the life cycle and animation state of water ripple effects.
class RippleModel { final int startTime; RippleModel({required this.startTime}); double get animationValue => ((DateTime.now().millisecondsSinceEpoch - startTime) / 1500).clamp(0.0, 1.0); }

// Custom painter for rendering expanding circular ripples behind the main controls.
class WaterRipplePainter extends CustomPainter { final List<RippleModel> ripples; final int now; WaterRipplePainter(this.ripples, this.now); @override void paint(Canvas canvas, Size size) { final center = Offset(size.width / 2, size.height / 2); final maxR = size.width * 0.8; for (var r in ripples) { final p = r.animationValue; if (p >= 1.0) continue; final paint = Paint()..color = Colors.white.withOpacity((1.0 - p) * 0.4)..style = PaintingStyle.stroke..strokeWidth = 2 + (4 * (1 - p)); canvas.drawCircle(center, p * maxR, paint); } } @override bool shouldRepaint(WaterRipplePainter old) => true; }

// Component for displaying long track titles that scroll horizontally when they exceed space.
class MarqueeText extends StatefulWidget { final String text; final TextStyle style; const MarqueeText({super.key, required this.text, required this.style}); @override State<MarqueeText> createState() => _MarqueeTextState(); } class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin { late ScrollController _sc; late AnimationController _ac; @override void initState() { super.initState(); _sc = ScrollController(); _ac = AnimationController(vsync: this, duration: const Duration(seconds: 10))..addListener(() { if (_sc.hasClients) _sc.jumpTo(_sc.position.maxScrollExtent * _ac.value); }); _ac.repeat(reverse: true); } @override void dispose() { _ac.dispose(); _sc.dispose(); super.dispose(); } @override Widget build(BuildContext context) { return SingleChildScrollView(scrollDirection: Axis.horizontal, controller: _sc, physics: const NeverScrollableScrollPhysics(), child: Text(widget.text, style: widget.style)); } }

// UI component for viewing and interacting with time-synced song lyrics.
class LyricsViewer extends StatefulWidget { final LyricsData lyrics; final Duration currentPosition; final Function(Duration) onLineTapped; const LyricsViewer({super.key, required this.lyrics, required this.currentPosition, required this.onLineTapped}); @override State<LyricsViewer> createState() => _LyricsViewerState(); } class _LyricsViewerState extends State<LyricsViewer> { final ItemScrollController _isc = ItemScrollController(); int _ai = 0; @override void didUpdateWidget(LyricsViewer old) { super.didUpdateWidget(old); int ni = 0; for (int i = 0; i < widget.lyrics.lines.length; i++) { if (widget.currentPosition >= widget.lyrics.lines[i].startTime) ni = i; else break; } if (ni != _ai) { setState(() => _ai = ni); if(_isc.isAttached) _isc.scrollTo(index: _ai, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut, alignment: 0.5); } } @override Widget build(BuildContext context) { return ScrollablePositionedList.builder(itemScrollController: _isc, padding: const EdgeInsets.symmetric(vertical: 200, horizontal: 16), itemCount: widget.lyrics.lines.length, itemBuilder: (c, i) { final isActive = i == _ai; return Material(color: Colors.transparent, child: InkWell(onTap: () => widget.onLineTapped(widget.lyrics.lines[i].startTime), child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: AnimatedDefaultTextStyle(duration: const Duration(milliseconds: 200), style: TextStyle(color: isActive ? Colors.white : Colors.white.withOpacity(0.4), fontSize: isActive ? 26 : 18, fontWeight: isActive ? FontWeight.bold : FontWeight.w600, height: 1.4), child: Text(widget.lyrics.lines[i].words, textAlign: TextAlign.center))))); }); } }
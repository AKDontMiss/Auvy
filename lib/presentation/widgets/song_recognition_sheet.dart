// lib/presentation/widgets/song_recognition_sheet.dart
//
// The user-facing surface for song recognition. Opens as a bottom sheet, listens
// through the mic, fingerprints the audio and either shows the matched track
// (with a one-tap "Play on Auvy") or a friendly no-match/error state with retry.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/song_recognition_service.dart';
import 'package:auvy/services/recognition_history.dart';
import 'package:auvy/services/audio_capture_service.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';

/// How the audio to identify is obtained.
enum ListenSource {
  /// Microphone — music in the room.
  mic,

  /// This device's own playback (Instagram, a browser, a game).
  device,
}

/// Opens the recognition sheet.
///
/// [source] defaults to the microphone, which starts listening immediately.
/// [ListenSource.device] instead shows a primed screen first, because Android
/// throws its own screen-capture consent dialog at the user and firing that
/// unannounced reads like the app doing something alarming.
Future<void> showSongRecognitionSheet(
  BuildContext context, {
  ListenSource source = ListenSource.mic,
}) {
  HapticService.medium();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    // Render on the ROOT navigator so the sheet sits above MainLayout's
    // mini-player overlay (which otherwise clips the bottom of the sheet).
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.6),
    builder: (_) => _SongRecognitionSheet(source: source),
  );
}

/// Identifies PCM the quick-settings tile already captured.
///
/// Opens straight into the identifying state — the audio is in hand, so there is
/// nothing to prime, consent for, or listen to.
Future<void> showPendingCaptureResult(BuildContext context, Uint8List pcm) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.6),
    builder: (_) => _SongRecognitionSheet(
      source: ListenSource.device,
      pendingPcm: pcm,
    ),
  );
}

class _SongRecognitionSheet extends ConsumerStatefulWidget {
  final ListenSource source;

  /// Already-captured audio (tile path). When present, recognition starts at once
  /// and no capture is attempted.
  final Uint8List? pendingPcm;

  const _SongRecognitionSheet({required this.source, this.pendingPcm});

  @override
  ConsumerState<_SongRecognitionSheet> createState() =>
      _SongRecognitionSheetState();
}

class _SongRecognitionSheetState extends ConsumerState<_SongRecognitionSheet>
    with SingleTickerProviderStateMixin {
  final SongRecognitionService _service = SongRecognitionService();
  late final AnimationController _pulse;

  RecognitionPhase? _phase;
  RecognitionOutcome? _outcome;
  String? _inlineNote;

  /// Which control is waiting on a catalogue lookup ('play' | 'album' |
  /// 'artist'), so only that one shows a spinner and the rest disable.
  String? _busyAction;

  /// The recognised track resolved to a real Auvy [Song] — cached so tapping
  /// Play then Artist doesn't run the same search twice.
  Song? _resolved;

  /// (done, total) while the local fingerprint index is being built; null when
  /// idle. Only ever non-null on the first run, or after new tracks were cached.
  (int, int)? _indexProgress;

  bool get _busy => _outcome == null;

  /// Capture mode waits for a tap before starting; mic mode listens immediately.
  /// Android throws a full-screen "Auvy will capture everything on your screen"
  /// warning at the user, and firing that the instant a sheet opens reads like the
  /// app doing something it shouldn't.
  bool _awaitingCaptureStart = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    if (widget.pendingPcm != null) {
      // A tile capture is already in hand — identify it straight away. Nothing to
      // prime, consent for, or listen to.
      _start();
    } else if (widget.source == ListenSource.device) {
      _awaitingCaptureStart = true;
    } else {
      _start();
    }
  }

  Future<void> _start() async {
    setState(() {
      _outcome = null;
      _inlineNote = null;
      _awaitingCaptureStart = false;
      _phase = RecognitionPhase.requestingPermission;
    });

    final outcome = widget.source == ListenSource.device
        ? await _captureAndRecognise()
        : await _service.recognize(
            onPhase: (p) {
              if (mounted) setState(() => _phase = p);
            },
          );
    // The notification comes FIRST, before any mounted check
    //
    // THE SHADE IS NOT THIS WIDGET'S TO ABANDON. The tile posted
    // "Identifying…" as a promise, and replacing it is an OS-level duty that
    // outlives the sheet. Both earlier versions of this code returned on
    // `!mounted` before ever reaching the notify, so dismissing the sheet while
    // recognition ran left "Identifying…" standing for ever, which is exactly the
    // stuck state that made the feature look broken.
    //
    // Only for the quick-settings path: a mic or long-press identification
    // happened with the user watching this sheet, so a notification about
    // something already on screen would just be noise.
    if (widget.pendingPcm != null) {
      if (outcome.isSuccess) {
        final r = outcome.result!;
        await AudioCaptureService.notifyFound(r.title, r.artist);
      } else {
        // Says which of the two actually happened: "no match" and "something went
        // wrong" call for different responses from the user.
        await AudioCaptureService.notifyFound(
          outcome.isError ? 'Could not identify' : 'No match found',
          outcome.message ??
              (outcome.isError
                  ? 'Something went wrong listening.'
                  : 'Nothing recognisable in that audio.'),
        );
      }
    }

    // History is also worth keeping whether or not the sheet survived — the user
    // asked what was playing, and the answer belongs in their list either way.
    if (outcome.isSuccess) {
      final r = outcome.result!;
      await RecognitionHistory.add(RecognitionEntry(
        title: r.title,
        artist: r.artist,
        coverArtUrl: r.bestCoverArt,
        at: DateTime.now(),
      ));
    }

    // Everything past here touches the widget, so now the check matters.
    if (!mounted) return;
    if (outcome.isSuccess) HapticService.medium();
    setState(() => _outcome = outcome);
  }

  /// Capture this device's audio, then identify it through the same Shazam path
  /// the microphone uses.
  ///
  /// Failures are translated into the specific reason rather than a generic error:
  /// "you declined the prompt", "that app blocks capture" and "recognition failed"
  /// send the user to three completely different next actions, and collapsing them
  /// would leave them retrying something that can never work.
  /// True when app-audio capture was blocked and we switched to the mic, so
  /// the sheet can say so rather than silently behaving differently.
  bool _viaMicFallback = false;

  Future<RecognitionOutcome> _captureAndRecognise() async {
    try {
      // A tile capture is already recorded — never re-capture, which would prompt
      // for consent and record the wrong moment.
      final pcm = widget.pendingPcm ??
          await AudioCaptureService.capture(seconds: 8.0);
      if (!mounted) return RecognitionOutcome.error('Cancelled.');
      return await _service.recognizeFromPcm(
        pcm,
        onPhase: (p) {
          if (mounted) setState(() => _phase = p);
        },
      );
    } on CaptureException catch (e) {
      switch (e.reason) {
        case CaptureFailure.denied:
          return RecognitionOutcome.error(
              'Auvy needs the screen-capture permission to hear this device\'s '
              'audio. Android asks every time — nothing is recorded or saved.');
        case CaptureFailure.noAudio:
          // FALL BACK TO THE MICROPHONE, do not dead-end
          //
          // Silence here almost always means the source app OPTED OUT of
          // playback capture (android:allowAudioPlaybackCapture="false").
          // TikTok, Spotify, Netflix and YouTube all do. Android does not
          // report that as an error — it hands over a buffer of zeros, so the
          // only signal is the silence check in AudioCaptureService.
          //
          // There is no way to defeat that, and there should not be. But the
          // speaker is still playing the song, which is exactly what Shazam
          // itself listens to, so the microphone works on every app ever
          // written. Retrying automatically turns a dead end into a result
          // instead of asking the user to know why it failed and which mode to
          // pick.
          if (!mounted) return RecognitionOutcome.error('Cancelled.');
          if (!await _service.hasPermission()) {
            return RecognitionOutcome.error(
                'That app blocks audio capture. Auvy can listen through the '
                'microphone instead — grant microphone access and try again.');
          }
          if (mounted) setState(() => _viaMicFallback = true);
          return await _service.recognize(
            onPhase: (p) {
              if (mounted) setState(() => _phase = p);
            },
          );
        case CaptureFailure.unsupported:
          return RecognitionOutcome.error(
              'Capturing app audio needs Android 10 or newer. Use the microphone '
              'instead.');
        case CaptureFailure.other:
          return RecognitionOutcome.error(e.message);
      }
    }
  }

  /// Resolves the recognised track to a real Auvy [Song].
  ///
  /// Every action needs this, not just Play: an album or artist page can't be
  /// opened from a title string alone — it needs the real ids, artwork and album
  /// name that only a catalogue lookup provides. Cached in [_resolved] so tapping
  /// Play then Artist doesn't search twice.
  Future<Song?> _resolveSong() async {
    if (_resolved != null) return _resolved;
    final result = _outcome?.result;
    if (result == null) return null;
    final songs = await ref
        .read(searchServiceProvider)
        .search(result.searchQuery, 'track');
    if (songs.isEmpty) return null;
    _resolved = songs.first;
    return _resolved;
  }

  /// Runs [action] with the resolved song, showing a spinner on the tapped
  /// control and reporting failure inline instead of silently doing nothing.
  Future<void> _withResolved(String busyKey, void Function(Song) action) async {
    if (_busyAction != null) return;
    HapticService.medium();
    setState(() {
      _busyAction = busyKey;
      _inlineNote = null;
    });
    try {
      final song = await _resolveSong();
      if (!mounted) return;
      if (song == null) {
        setState(() {
          _busyAction = null;
          _inlineNote = "Couldn't find this track on Auvy.";
        });
        return;
      }
      action(song);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busyAction = null;
        _inlineNote = 'Something went wrong. Try again.';
      });
    }
  }

  void _playResult() => _withResolved('play', (song) {
        ref
            .read(playerProvider.notifier)
            .playSong(song, source: 'Song Recognition');
        Navigator.of(context).maybePop();
      });

  /// The sheet lives on the ROOT navigator, so it must be dismissed before
  /// pushing onto the active tab — otherwise the destination renders behind it.
  void _openAlbum() => _withResolved('album', (song) {
        final album = ContentMenus.buildAlbumForSong(song);
        Navigator.of(context).maybePop();
        AppNavigation.pushOnActiveTab(
          AlbumPage(album: album, artistName: song.artist, fallbackTrack: song),
          name: AppNavigation.albumTag(album),
        );
      });

  void _openArtist() => _withResolved('artist', (song) async {
        final rootCtx = Navigator.of(context, rootNavigator: true).context;
        Navigator.of(context).maybePop();
        // Same disambiguation the track menus use: a multi-artist track asks
        // which artist was meant, and the channel id is resolved so same-named
        // artists don't collide.
        final chosen = await ContentMenus.pickArtist(rootCtx, song);
        if (chosen == null) return;
        final targetId =
            await ContentMenus.resolveArtistTarget(ref, song, chosen);
        final pseudo = Song(
          id: targetId,
          title: chosen,
          artist: chosen,
          image: song.image,
        );
        AppNavigation.pushOnActiveTab(
          ArtistPage(artist: pseudo),
          name: AppNavigation.artistTag(pseudo),
        );
      });

  @override
  void dispose() {
    _pulse.dispose();
    _service.cancel();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF14141A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 12,
        bottom: 24 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grabber
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: _awaitingCaptureStart
                ? _buildCapturePrimer(accent)
                : _busy
                    ? _buildBusy(accent)
                    : _buildOutcome(accent, _outcome!),
          ),
        ],
      ),
    );
  }

  /// Shown BEFORE capture mode starts, so Android's screen-capture warning is
  /// expected rather than alarming.
  ///
  /// That dialog says Auvy will "capture everything displayed on your screen",
  /// which is the generic MediaProjection wording — Auvy only ever reads the audio
  /// stream, never any pixels. Saying so here, before the prompt appears, is the
  /// difference between the user tapping Allow and force-quitting the app.
  Widget _buildCapturePrimer(Color accent) {
    return Column(
      key: const ValueKey('primer'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withOpacity(0.13),
            border: Border.all(color: accent.withOpacity(0.35), width: 1.5),
          ),
          child: Icon(Icons.speaker_phone_rounded, size: 32, color: accent),
        ),
        const SizedBox(height: 18),
        const Text('Identify this device’s audio',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'Start whatever is playing in the other app, then tap Listen. Auvy reads '
          'the audio directly — no microphone, so background noise doesn’t matter.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Colors.white.withOpacity(0.72), fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 15, color: Colors.white.withOpacity(0.4)),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Android will ask to “record or cast your screen”. That is its '
                  'standard wording — Auvy only reads audio, never your screen, and '
                  'nothing is saved. It has to ask every time.',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66),
                      fontSize: 11.5,
                      height: 1.45),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _start,
            icon: const Icon(Icons.graphic_eq_rounded, size: 20),
            label: const Text('Listen',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text('Cancel',
              style: TextStyle(color: Colors.white.withOpacity(0.78))),
        ),
      ],
    );
  }

  // Listening / processing
  Widget _buildBusy(Color accent) {
    // First-run indexing takes visibly longer than anything else here, so it gets
    // its own label with a count — otherwise it reads as the app having hung.
    final progress = _indexProgress;
    final label = progress != null
        ? 'Learning your library… ${progress.$1}/${progress.$2}'
        : switch (_phase) {
            RecognitionPhase.requestingPermission => 'Preparing…',
            RecognitionPhase.listening => 'Listening…',
            // "Identifying" now covers the local-library match too, which runs
            // before Shazam is contacted at all.
            RecognitionPhase.processing => 'Identifying…',
            RecognitionPhase.querying => 'Searching Shazam…',
            null => 'Listening…',
          };
    final listening = _phase == RecognitionPhase.listening ||
        _phase == RecognitionPhase.requestingPermission;

    return Column(
      key: const ValueKey('busy'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 180,
          width: 180,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  if (listening) ...[
                    _ring(accent, 0.0),
                    _ring(accent, 0.5),
                  ],
                  Container(
                    height: 96,
                    width: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [accent, accent.withOpacity(0.65)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withOpacity(0.45),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: listening
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            // Neutral glyph, not the Shazam mark. See the note in
                            // search_page.dart.
                            child: const Icon(Icons.graphic_eq_rounded,
                                size: 56, color: Colors.white),
                          )
                        : const Padding(
                            padding: EdgeInsets.all(28),
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
        // Level meter only while the mic is actually open. Showing it during
        // indexing or the Shazam round-trip would imply Auvy is still listening
        // when it isn't.
        if (listening) ...[
          const SizedBox(height: 4),
          _ListeningBars(pulse: _pulse, accent: accent),
        ],
        const SizedBox(height: 20),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          // The hint has to match the phase: "keep your phone near the music" is
          // wrong once the mic has closed and it's fingerprinting or querying.
          //
          // The mic-fallback case was TRACKED BUT NEVER SHOWN. _viaMicFallback
          // has always been set when app-audio capture came back silent (apps
          // like TikTok, Spotify and Netflix set allowAudioPlaybackCapture=false
          // and Android hands over a buffer of zeros rather than an error), but
          // nothing rendered it, so the behaviour silently changed under the
          // user and identifying muted playback just looked broken. Saying it
          // out loud is the difference between "this is useless" and "turn the
          // volume up".
          _indexProgress != null
              ? 'One-time setup so Auvy can match offline'
              : listening
                  ? (_viaMicFallback
                      ? 'That app blocks recording — listening on the microphone. Play it out loud.'
                      : 'Keep your phone near the music')
                  : 'Working out what that was…',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13),
        ),
        const SizedBox(height: 20),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text('Cancel',
              style: TextStyle(color: Colors.white.withOpacity(0.78))),
        ),
      ],
    );
  }

  Widget _ring(Color accent, double phaseOffset) {
    final t = (_pulse.value + phaseOffset) % 1.0;
    final size = 96 + t * 84;
    return Opacity(
      opacity: (1.0 - t) * 0.5,
      child: Container(
        height: size,
        width: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: accent.withOpacity(0.6), width: 2),
        ),
      ),
    );
  }

  // Result / no-match / error
  Widget _buildOutcome(Color accent, RecognitionOutcome outcome) {
    switch (outcome.state) {
      case RecognitionState.success:
        return _buildSuccess(accent, outcome.result!);
      case RecognitionState.noMatch:
      case RecognitionState.error:
        return _buildMiss(accent, outcome);
    }
  }

  Widget _buildSuccess(Color accent, SongRecognitionResult r) {
    final cover = r.bestCoverArt;
    return Column(
      key: const ValueKey('success'),
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 150,
            width: 150,
            child: cover != null
                ? CachedNetworkImage(
                    imageUrl: cover,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                        color: Colors.white.withOpacity(0.06)),
                    errorWidget: (_, __, ___) => _coverFallback(accent),
                  )
                : _coverFallback(accent),
          ),
        ),
        const SizedBox(height: 18),
        // Title and artist are TAPPABLE — the title opens the album, the artist
        // opens the artist page. Recognising a song and then having to retype its
        // name into search to explore it was the obvious dead end here. Each needs
        // a catalogue lookup first (see _resolveSong), so each shows its own
        // spinner rather than a single global one.
        _TappableLine(
          text: r.title.isEmpty ? 'Unknown title' : r.title,
          icon: Icons.album_rounded,
          busy: _busyAction == 'album',
          // Nothing to open if the lookup can't run; also true while another
          // action holds the resolver.
          enabled: _busyAction == null,
          accent: accent,
          fontSize: 20,
          weight: FontWeight.w700,
          color: Colors.white,
          onTap: _openAlbum,
        ),
        const SizedBox(height: 6),
        _TappableLine(
          text: r.artist,
          icon: Icons.person_rounded,
          busy: _busyAction == 'artist',
          enabled: _busyAction == null && r.artist.isNotEmpty,
          accent: accent,
          fontSize: 15,
          weight: FontWeight.w500,
          color: Colors.white.withOpacity(0.72),
          onTap: _openArtist,
        ),
        if ((r.album ?? '').isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            r.album!,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13),
          ),
        ],
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _busyAction != null ? null : _playResult,
            icon: _busyAction == 'play'
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_busyAction == 'play' ? 'Finding on Auvy…' : 'Play on Auvy'),
          ),
        ),
        if (_inlineNote != null) ...[
          const SizedBox(height: 10),
          Text(_inlineNote!,
              style: TextStyle(color: Colors.orange.shade300, fontSize: 13)),
        ],
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busyAction != null ? null : _start,
          child: Text('Identify again',
              style: TextStyle(color: Colors.white.withOpacity(0.78))),
        ),
      ],
    );
  }

  Widget _coverFallback(Color accent) => Container(
        color: accent.withOpacity(0.15),
        child: Icon(Icons.music_note_rounded,
            color: accent.withOpacity(0.7), size: 48),
      );

  Widget _buildMiss(Color accent, RecognitionOutcome outcome) {
    final isError = outcome.state == RecognitionState.error;
    return Column(
      key: const ValueKey('miss'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 96,
          width: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.06),
          ),
          child: Icon(
            isError ? Icons.error_outline_rounded : Icons.search_off_rounded,
            color: Colors.white.withOpacity(0.55),
            size: 44,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          isError ? 'Something went wrong' : 'No match found',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            outcome.message ??
                'Try again in a quieter spot, closer to the speaker.',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13),
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _start,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text('Close',
              style: TextStyle(color: Colors.white.withOpacity(0.78))),
        ),
      ],
    );
  }
}

/// A title/artist line that behaves like a link: tap to open the album or artist.
///
/// Kept visually quiet — an underline or button chrome on a 20pt title would
/// fight the artwork above it. The trailing glyph is the whole affordance, and it
/// swaps to a spinner in place so the row never changes height mid-tap.
class _TappableLine extends StatelessWidget {
  final String text;
  final IconData icon;
  final bool busy;
  final bool enabled;
  final Color accent;
  final double fontSize;
  final FontWeight weight;
  final Color color;
  final VoidCallback onTap;

  const _TappableLine({
    required this.text,
    required this.icon,
    required this.busy,
    required this.enabled,
    required this.accent,
    required this.fontSize,
    required this.weight,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final glyph = busy
        ? SizedBox(
            width: fontSize * 0.8,
            height: fontSize * 0.8,
            child: CircularProgressIndicator(strokeWidth: 1.8, color: accent),
          )
        : Icon(icon, size: fontSize * 0.85, color: accent.withOpacity(0.75));

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Flexible, not Expanded: the row must hug its text so the glyph sits
            // beside the title rather than pinned to the sheet edge.
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color, fontSize: fontSize, fontWeight: weight),
              ),
            ),
            const SizedBox(width: 7),
            glyph,
          ],
        ),
      ),
    );
  }
}


/// Live level meter shown while the mic is open.
///
/// Not driven by real audio — the PCM lives on a background isolate and piping
/// amplitude to the UI would cost more than the effect is worth. It's a phase-
/// offset sine per bar, which reads as "listening" without pretending to be a
/// visualisation of the actual signal.
class _ListeningBars extends StatelessWidget {
  final Animation<double> pulse;
  final Color accent;
  const _ListeningBars({required this.pulse, required this.accent});

  static const int _bars = 7;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < _bars; i++) ...[
              _bar(i),
              if (i != _bars - 1) const SizedBox(width: 4),
            ],
          ],
        );
      },
    );
  }

  Widget _bar(int i) {
    // Offset each bar around the cycle so the group ripples instead of pumping
    // in unison. 0.5 + 0.5*sin keeps the height positive without a clamp.
    final phase = (pulse.value + i / _bars) * 2 * 3.14159;
    final level = 0.5 + 0.5 * math.sin(phase);
    return Container(
      width: 3.5,
      height: 6 + level * 20,
      decoration: BoxDecoration(
        color: accent.withOpacity(0.45 + level * 0.45),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

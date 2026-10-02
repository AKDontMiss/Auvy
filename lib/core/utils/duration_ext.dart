extension DurationFormatting on Duration {
  /// Converts a Duration to a 'mm:ss' or 'h:mm:ss' string.
  String toMmSs() {
    final minutes = inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = inHours;

    if (hours > 0) {
      return '$hours:${minutes.padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }
}
/// Human-readable byte formatting. Uses decimal MB (1 MB = 1,000,000 bytes)
/// because that is how carriers bill, and labels it so the user is not misled
/// by MiB/MB confusion.
library;

String formatBytes(int bytes) {
  if (bytes < 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  return '${value.toStringAsFixed(value >= 100 ? 0 : value >= 10 ? 1 : 2)} ${units[unit]}';
}

String formatRate(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  return '${formatBytes(bytesPerSecond.round())}/s';
}

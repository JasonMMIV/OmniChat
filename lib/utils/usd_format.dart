/// Formats a USD amount for the small message stats line and usage sheet.
///
/// The precision ladder keeps cent-scale charges readable while still
/// preserving the tiny per-request Go allowance values (for example
/// `$0.00000695`).
String? formatUsd(double? value) {
  if (value == null || value.isNaN || value.isInfinite) return null;
  if (value == 0) return r'$0';
  final magnitude = value.abs();
  final decimals = magnitude >= 0.01
      ? 4
      : magnitude >= 0.0001
      ? 6
      : 8;
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return '\$$text';
}

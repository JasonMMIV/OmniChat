// Phase 2.1 decision-gate spike (PLAN_WORKSPACE_ZERO_RESIDUE.md).
//
// Question: does Dart's File.rename on Windows replace an EXISTING target?
// AnyBuff's ADR-13 assumes Node fs.rename == MoveFileExW(REPLACE_EXISTING)
// (atomic replace on NTFS). Dart's File.rename has no documented
// replace-guarantee on Windows — this spike settles which atomic-write
// variant OmniChat must adopt (2.2 rename-replace vs 2.3 staging dir).
//
// Run: dart run tool/windows_rename_spike.dart
import 'dart:io';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('omnichat_rename_spike_');
  try {
    final target = File('${dir.path}${Platform.pathSeparator}target.txt');
    await target.writeAsString('OLD-CONTENT');

    final temp = File('${dir.path}${Platform.pathSeparator}stage.tmp');
    await temp.writeAsString('NEW-CONTENT');

    try {
      final renamed = await temp.rename(target.path);
      final replaced = await target.readAsString();
      final tempGone = !await temp.exists();
      final targetExists = await target.exists();

      stdout.writeln('rename() returned: ${renamed.path}');
      stdout.writeln('target exists:     $targetExists');
      stdout.writeln('target content:    $replaced');
      stdout.writeln('temp gone:         $tempGone');

      if (targetExists && replaced == 'NEW-CONTENT' && tempGone) {
        stdout.writeln('');
        stdout.writeln('RESULT: REPLACE — File.rename overwrites the existing');
        stdout.writeln('target on this platform. Adopt variant 2.2');
        stdout.writeln('(ADR-13 rename-replace, no backup sibling).');
      } else if (targetExists && replaced == 'OLD-CONTENT') {
        stdout.writeln('');
        stdout.writeln('RESULT: NO-REPLACE — File.rename refused to overwrite');
        stdout.writeln('the existing target. Adopt variant 2.3');
        stdout.writeln('(consolidated hidden staging dir).');
      } else {
        stdout.writeln('');
        stdout.writeln('RESULT: UNCLEAR — inspect the outputs above.');
      }
    } on FileSystemException catch (e) {
      // Dart rename() throws when the destination exists on some platforms.
      stdout.writeln('rename() threw: ${e.message}');
      final stillOld = await target.readAsString();
      stdout.writeln('target content after throw: $stillOld');
      stdout.writeln('');
      if (stillOld == 'OLD-CONTENT') {
        stdout.writeln('RESULT: NO-REPLACE — rename throws if destination');
        stdout.writeln('exists. Adopt variant 2.3 (hidden staging dir).');
      } else {
        stdout.writeln('RESULT: UNCLEAR — target was modified despite throw.');
      }
    }
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/snapshot.dart';

class LocalStore {
  LocalStore({File? file}) : _file = file;

  File? _file;

  Future<File> _resolve() async {
    if (_file != null) return _file!;
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return _file = File('${directory.path}/medisafe.json');
  }

  Future<Snapshot> load() async {
    final file = await _resolve();
    if (!await file.exists()) return Snapshot();
    return Snapshot.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }

  Future<void> write(Snapshot snapshot) async {
    final file = await _resolve();
    final next = File('${file.path}.next');
    await next.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    await next.rename(file.path);
  }
}

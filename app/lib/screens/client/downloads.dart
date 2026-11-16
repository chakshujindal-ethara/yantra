import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/widgets/loader.dart';
import '../../core/widgets/mono_box.dart';

/// What a client downloads for a delivered batch. Both answers go through the app's downloader (a real
/// file on the web); where no save is possible the content opens in a copyable box instead.

String _short(String s) => s.length <= 8 ? s : s.substring(0, 8);

/// The pause between two saves of one action: a browser drops a second download started in the same tick.
const downloadGap = Duration(milliseconds: 600);

/// Saves the batch's manifest as `manifest-<batch>.json`.
Future<void> downloadManifest(BuildContext context, String batchId) async {
  final scope = AppScope.of(context);
  try {
    final body = await scope.client.manifest(batchId);
    final text = prettyJson.convert(body);
    if (!context.mounted) return;
    if (!scope.downloader.supported) {
      await showMonoDialog(context, title: 'Manifest', text: text);
      return;
    }
    scope.downloader.save('manifest-${_short(batchId)}.json', utf8.encode(text), 'application/json');
    toast(context, 'Manifest downloaded');
  } on Object catch (e) {
    if (context.mounted) toast(context, describeError(e));
  }
}

/// Saves the batch's deliverable: `units-<batch>.jsonl` (one accepted unit per line) and its
/// `manifest.json`, read straight from object storage through the five-minute links. Returns the reason
/// when the batch is still held at the delivery gate (409 `batch_held`) or its retention emptied it (410
/// `batch_purged`), for the page to show; any other failure is a toast.
Future<String?> downloadDeliverable(BuildContext context, String batchId) async {
  final scope = AppScope.of(context);
  try {
    final d = await scope.client.deliverable(batchId);
    final units = await scope.uploader.fetch(Uri.parse(d.jsonl.url));
    final manifest = await scope.uploader.fetch(Uri.parse(d.manifest.url));
    if (!context.mounted) return null;
    if (!scope.downloader.supported) {
      await showMonoDialog(context, title: 'Units (${d.lineCount} lines)', text: utf8.decode(units, allowMalformed: true));
      return null;
    }
    scope.downloader.save('units-${_short(batchId)}.jsonl', units, 'application/x-ndjson');
    await Future<void>.delayed(downloadGap);
    scope.downloader.save('manifest-${_short(batchId)}-files.json', manifest, 'application/json');
    if (context.mounted) toast(context, 'Deliverable downloaded: ${d.lineCount} units');
    return null;
  } on ApiException catch (e) {
    if (e.code == 'batch_held' || e.code == 'batch_purged') return describeError(e);
    if (context.mounted) toast(context, describeError(e));
    return null;
  } on Object catch (e) {
    if (context.mounted) toast(context, describeError(e));
    return null;
  }
}

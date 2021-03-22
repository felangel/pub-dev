// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:args/args.dart';
import 'package:pool/pool.dart';

import 'package:pub_dev/account/models.dart';
import 'package:pub_dev/audit/models.dart';
import 'package:pub_dev/dartdoc/models.dart';
import 'package:pub_dev/job/backend.dart';
import 'package:pub_dev/package/models.dart';
import 'package:pub_dev/publisher/models.dart';
import 'package:pub_dev/scorecard/backend.dart';
import 'package:pub_dev/service/entrypoint/tools.dart';
import 'package:pub_dev/service/secret/models.dart';
import 'package:pub_dev/shared/configuration.dart';
import 'package:pub_dev/shared/datastore.dart';
import 'package:pub_dev/tool/neat_task/datastore_status_provider.dart';

final _argParser = ArgParser()
  ..addOption('concurrency',
      abbr: 'c', defaultsTo: '1', help: 'Number of concurrent processing.')
  ..addFlag('dry-run',
      abbr: 'n', defaultsTo: false, help: 'Do not change Datastore.')
  ..addFlag('help', abbr: 'h', defaultsTo: false, help: 'Show help.');

/// Deletes every (used) entity on staging.
Future main(List<String> args) async {
  if (envConfig.gcloudProject != 'dartlang-pub-dev') {
    print('**ERROR**: The tool is meant to be used only on staging.');
    return;
  }

  final argv = _argParser.parse(args);
  if (argv['help'] as bool == true) {
    print('Usage: dart delete_all_staging.dart');
    print('Deletes every (used) entity on staging.');
    print(_argParser.usage);
    return;
  }

  final concurrency = int.parse(argv['concurrency'] as String);
  final dryRun = argv['dry-run'] as bool;

  await withToolRuntime(() async {
    final entities = <Query, int>{
      dbService.query<AuditLogRecord>(): 500,
      dbService.query<Job>(): 500,
      dbService.query<DartdocRun>(): 100,
      dbService.query<UserInfo>(): 500,
      dbService.query<OAuthUserID>(): 500,
      dbService.query<UserSession>(): 500,
      dbService.query<User>(): 500,
      dbService.query<Like>(): 500,
      dbService.query<ScoreCardReport>(): 100,
      dbService.query<ScoreCard>(): 500,
      dbService.query<PackageVersionInfo>(): 500,
      dbService.query<PackageVersionAsset>(): 100,
      dbService.query<PackageVersion>(): 500,
      dbService.query<Package>(): 500,
      dbService.query<PublisherMember>(): 500,
      dbService.query<PublisherInfo>(): 500,
      dbService.query<Publisher>(): 500,
      dbService.query<ModeratedPackage>(): 500,
      dbService.query<NeatTaskStatus>(): 500,
      dbService.query<Secret>(): 500,
    };

    final pool = Pool(concurrency);
    for (final entity in entities.entries) {
      final futures = <Future>[];
      await _batchedQuery(
        entity.key,
        (keys) {
          final f = pool.withResource(() => _commit(keys, dryRun));
          futures.add(f);
        },
        batchSize: entity.value,
      );
      await Future.wait(futures);
    }
    await pool.close();
  });
}

Future<void> _batchedQuery<T extends Model>(
  Query<T> query,
  void Function(List<Key> keys) fn, {
  int batchSize = 100,
}) async {
  print('Running query for $T...');
  final keys = <Key>[];
  var scheduled = 0;
  await for (Model m in query.run()) {
    keys.add(m.key);
    if (keys.length >= batchSize) {
      fn(List.from(keys));
      keys.clear();
      scheduled++;
    }
  }
  if (keys.isNotEmpty) {
    fn(keys);
    scheduled++;
  }
  print('Scheduled $scheduled $T batches.');
}

Future<void> _commit(List<Key> keys, bool dryRun) async {
  if (keys.isEmpty) return;
  final first = keys.first;
  final label = dryRun ? 'NOT deleting' : 'Deleting';
  print('$label ${keys.length} of ${first.type} (e.g. ${first.id})');
  if (!dryRun) {
    await dbService.commit(deletes: keys);
  }
}

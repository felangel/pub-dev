// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:gcloud/storage.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'configuration.dart';
import 'scheduler_stats.dart';
import 'task_client.dart';
import 'versions.dart';

class WorkerEntryMessage {
  final int workerIndex;
  final SendPort protocolSendPort;
  final SendPort statsSendPort;

  WorkerEntryMessage({
    @required this.workerIndex,
    @required this.protocolSendPort,
    @required this.statsSendPort,
  });
}

class WorkerProtocolMessage {
  final SendPort taskSendPort;

  WorkerProtocolMessage({@required this.taskSendPort});
}

Future startIsolates({
  @required Logger logger,
  @required void workerEntryPoint(WorkerEntryMessage message),
}) async {
  int workerStarted = 0;

  Future startWorkerIsolate() async {
    workerStarted++;
    final workerIndex = workerStarted;
    logger.info('About to start worker isolate #$workerIndex...');
    final ReceivePort errorReceivePort = new ReceivePort();
    final ReceivePort protocolReceivePort = new ReceivePort();
    final ReceivePort statsReceivePort = new ReceivePort();
    await Isolate.spawn(
      workerEntryPoint,
      new WorkerEntryMessage(
        workerIndex: workerIndex,
        protocolSendPort: protocolReceivePort.sendPort,
        statsSendPort: statsReceivePort.sendPort,
      ),
      onError: errorReceivePort.sendPort,
      onExit: errorReceivePort.sendPort,
      errorsAreFatal: true,
    );
    final WorkerProtocolMessage protocolMessage =
        (await protocolReceivePort.take(1).toList()).single;
    registerTaskSendPort(protocolMessage.taskSendPort);
    registerSchedulerStatsStream(statsReceivePort as Stream<Map>);
    logger.info('Worker isolate #$workerIndex started.');

    StreamSubscription errorSubscription;

    Future close() async {
      unregisterTaskSendPort(protocolMessage.taskSendPort);
      await errorSubscription?.cancel();
      errorReceivePort.close();
      protocolReceivePort.close();
      statsReceivePort.close();
    }

    errorSubscription = errorReceivePort.listen((e) async {
      logger.severe('ERROR from worker isolate #$workerIndex', e);
      await close();
      // restart isolate after a brief pause
      await new Future.delayed(new Duration(minutes: 1));
      await startWorkerIsolate();
    });
  }

  for (int i = 0; i < envConfig.workerCount; i++) {
    await startWorkerIsolate();
  }
}

Future initFlutterSdk(Logger logger) async {
  if (envConfig.flutterSdkDir == null) {
    logger.warning('FLUTTER_SDK is not set, assuming flutter is in PATH.');
  } else {
    // If the script exists, it is very likely that we are inside the appengine.
    // In local development environment the setup should happen only once, and
    // running the setup script multiple times should be safe (no-op if
    // FLUTTER_SDK directory exists).
    if (FileSystemEntity.isFileSync('/project/app/script/setup-flutter.sh')) {
      logger.warning('Setting up flutter checkout. This may take some time.');
      final ProcessResult result =
          await Process.run('/project/app/script/setup-flutter.sh', []);
      if (result.exitCode != 0) {
        logger.shout(
            'Failed to checkout flutter (exited with ${result.exitCode})\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}');
      } else {
        logger.info('Flutter checkout completed.');
      }
    }
  }
}

Future initDartdoc(Logger logger) async {
  Future<bool> checkVersion() async {
    final pr =
        await Process.run('pub', ['global', 'run', 'dartdoc', '--version']);
    if (pr.exitCode == 0) {
      final RegExp versionRegExp = new RegExp(r'dartdoc version: (.*)$');
      final match = versionRegExp.firstMatch(pr.stdout.toString().trim());
      if (match == null) {
        throw new Exception('Unable to parse dartdoc version: ${pr.stdout}');
      }
      final version = match.group(1).trim();
      return version == dartdocVersion;
    } else {
      return false;
    }
  }

  final exists = await checkVersion();
  if (exists) return;

  final pr = await Process
      .run('pub', ['global', 'activate', 'dartdoc', dartdocVersion]);
  if (pr.exitCode != 0) {
    final message = 'Failed to activate dartdoc (exited with ${pr.exitCode})\n'
        'stdout: ${pr.stdout}\nstderr: ${pr.stderr}';
    logger.shout(message);
    throw new Exception(message);
  }

  final matches = await checkVersion();
  if (!matches) {
    final message = 'Failed to setup dartdoc.';
    logger.shout(message);
    throw new Exception(message);
  }
}

Future<Bucket> getOrCreateBucket(Storage storage, String name) async {
  if (!await storage.bucketExists(name)) {
    await storage.createBucket(name);
  }
  return storage.bucket(name);
}

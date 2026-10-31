import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/core/services/chat/storage/sqlite_chat_storage.dart';

/// Opt-in benchmark:
///
/// flutter test test/benchmark/chat_storage_benchmark_test.dart \
///   --dart-define=RUN_CHAT_STORAGE_BENCHMARK=true \
///   --dart-define=BENCH_SCALE=1 \
///   --dart-define=BENCH_PAYLOAD_BYTES=4096 \
///   -r expanded
///
/// `BENCH_SCALE=1` uses 50 conversations × 100 messages (half assistant, each
/// with one tool event). Increase the scale/payload for the 250 MB / 16k event
/// profile. Results are printed as one JSON object so they can be copied into
/// the migration report.
const bool _runBenchmark = bool.fromEnvironment('RUN_CHAT_STORAGE_BENCHMARK');
const int _scale = int.fromEnvironment('BENCH_SCALE', defaultValue: 1);
const int _payloadBytes = int.fromEnvironment(
  'BENCH_PAYLOAD_BYTES',
  defaultValue: 4096,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sqlite chat storage benchmark',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'omnichat_benchmark_',
      );
      final results = <String, Object?>{};
      SqliteChatStorage? storage;
      try {
        storage = SqliteChatStorage(
          directory: directory,
          appVersion: 'benchmark',
          background: false,
        );
        final seedWatch = Stopwatch()..start();
        await storage.initialize();
        final conversations = 50 * _scale;
        final messagesPerConversation = 100 * _scale;
        final payload = 'x' * _payloadBytes;
        var eventCount = 0;
        var messageCount = 0;

        for (var c = 0; c < conversations; c++) {
          final conversationId = 'bench-conv-$c';
          final messages = <ChatMessage>[];
          for (var m = 0; m < messagesPerConversation; m++) {
            final role = m.isEven ? 'user' : 'assistant';
            final id = '$conversationId-m$m';
            messages.add(
              ChatMessage(
                id: id,
                role: role,
                content: 'message $m in $conversationId',
                conversationId: conversationId,
              ),
            );
          }
          await storage.restoreConversation(
            Conversation(
              id: conversationId,
              title: 'Benchmark $c',
              messageIds: messages.map((m) => m.id).toList(),
            ),
            messages,
          );
          for (var m = 1; m < messages.length; m += 2) {
            await storage.setToolEvents(messages[m].id, <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call-$conversationId-$m',
                'name': 'file_read',
                'arguments': <String, dynamic>{'path': 'benchmark.txt'},
                'content': payload,
              },
            ]);
            eventCount++;
          }
          messageCount += messages.length;
        }
        seedWatch.stop();

        await storage.dispose();
        storage = null;

        final coldStartWatch = Stopwatch()..start();
        storage = SqliteChatStorage(
          directory: directory,
          appVersion: 'benchmark',
          background: false,
        );
        await storage.initialize();
        coldStartWatch.stop();

        final conversationWatch = Stopwatch()..start();
        await storage.ensureConversationLoaded('bench-conv-0');
        conversationWatch.stop();

        final detailWatch = Stopwatch()..start();
        await storage.loadToolEventDetail(
          assistantMessageId: 'bench-conv-0-m1',
          toolCallId: 'call-bench-conv-0-1',
        );
        detailWatch.stop();

        final upsertResults = <String, int>{};
        final lastAssistant = 'bench-conv-0-m${messagesPerConversation - 1}';
        for (final entry in <String, int>{
          '1kb': 1024,
          '100kb': 100 * 1024,
          '1mb': 1024 * 1024,
          '10mb': 10 * 1024 * 1024,
        }.entries) {
          final samples = <int>[];
          for (var run = 0; run < 3; run++) {
            final content = '${entry.key}-$run-${'y' * entry.value}';
            final watch = Stopwatch()..start();
            await storage.setToolEvents(lastAssistant, <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call-upsert-${entry.key}-$run',
                'name': 'file_read',
                'arguments': <String, dynamic>{'path': 'upsert.txt'},
                'content': content,
              },
            ]);
            watch.stop();
            samples.add(watch.elapsedMilliseconds);
          }
          samples.sort();
          upsertResults[entry.key] = samples[1];
        }

        results
          ..['platform'] = Platform.operatingSystem
          ..['scale'] = _scale
          ..['payload_bytes'] = _payloadBytes
          ..['conversations'] = conversations
          ..['messages'] = messageCount
          ..['tool_events'] = eventCount
          ..['seed_ms'] = seedWatch.elapsedMilliseconds
          ..['cold_start_ms'] = coldStartWatch.elapsedMilliseconds
          ..['rss_after_cold_start_bytes'] = ProcessInfo.currentRss
          ..['load_conversation_ms'] = conversationWatch.elapsedMilliseconds
          ..['loaded_conversation_messages'] = storage
              .getMessages('bench-conv-0')
              .length
          ..['load_tool_detail_ms'] = detailWatch.elapsedMilliseconds
          ..['upsert_ms'] = upsertResults;
        // ignore: avoid_print
        print('CHAT_STORAGE_BENCHMARK ${jsonEncode(results)}');
      } finally {
        await storage?.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
    skip: _runBenchmark
        ? false
        : 'Set RUN_CHAT_STORAGE_BENCHMARK=true to run this benchmark.',
    timeout: const Timeout(Duration(hours: 1)),
  );
}

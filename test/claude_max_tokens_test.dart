// max_tokens negotiation for the Claude sender — contract tests for
// lib/core/services/api/claude_max_tokens.dart and LearnedMaxOutputCaps.
//
// Anthropic requires `max_tokens` on every /v1/messages request, so the
// value we send *is* the ceiling. The historical hard-coded 4096 capped
// replies at ~3% of what current models emit; these tests pin down the
// replacement: start high, adopt the ceiling the server states, and never
// drop to 4096 when it refuses to say.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart' show SharedPreferences;

import 'package:OmniChat/core/services/api/claude_max_tokens.dart';
import 'package:OmniChat/core/services/api/learned_max_output_caps.dart';
import 'package:OmniChat/core/services/backup/data_sync.dart'
    show SharedPreferencesAsync;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ceilingBody =
      '{"type":"error","error":{"type":"invalid_request_error",'
      '"message":"max_tokens: 64001 > 64000, which is the maximum allowed '
      'number of output tokens for claude-opus-4-5-20251101"}}';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LearnedMaxOutputCaps.debugReset();
  });

  group('parseClaudeOutputCeiling', () {
    test('reads the ceiling stated in Anthropic 400 bodies', () {
      expect(parseClaudeOutputCeiling(ceilingBody), 64000);
      expect(
        parseClaudeOutputCeiling(
          'max_tokens: 1000000 > 64000, which is the maximum allowed',
        ),
        64000,
      );
      expect(
        parseClaudeOutputCeiling(
          'Invalid max_tokens for claude-3-opus-20240229: '
          'max_tokens: 21333 > 4096, which is the maximum allowed number '
          'of output tokens',
        ),
        4096,
        reason: 'even a stated ceiling below the floor is a stated ceiling',
      );
    });

    test('returns null when the body discloses no ceiling', () {
      expect(parseClaudeOutputCeiling('{"message":"model: not_found"}'), isNull);
      expect(
        parseClaudeOutputCeiling(
          'prompt is too long: 190000 tokens > 200000 maximum',
        ),
        isNull,
      );
      expect(parseClaudeOutputCeiling(''), isNull);
    });

    test('reads third-party bound wordings', () {
      expect(
        parseClaudeOutputCeiling(
          'max_tokens must be less than or equal to 8192',
        ),
        8192,
      );
      expect(
        parseClaudeOutputCeiling('max_tokens: 128000 must not exceed 8192'),
        8192,
      );
      expect(
        parseClaudeOutputCeiling('max_tokens must be <= 8192'),
        8192,
      );
      expect(
        parseClaudeOutputCeiling(
          'Invalid max_tokens value, the valid range of max_tokens is [1, 8192]',
        ),
        8192,
      );
      expect(
        parseClaudeOutputCeiling('allows a maximum of 64000 output tokens'),
        64000,
      );
      expect(
        parseClaudeOutputCeiling('you can request at most 32000 output tokens'),
        32000,
      );
    });

    test('bound variants never shadow the overflow body', () {
      expect(
        parseClaudeOutputCeiling(
          'prompt is too long: 190000 tokens > 200000 maximum',
        ),
        isNull,
        reason: 'the window number is not an output ceiling',
      );
      expect(
        parseClaudeOutputCeiling(
          'messages: array too long (at most 100 allowed)',
        ),
        isNull,
      );
      expect(
        parseClaudeOutputCeiling(
          'prompt is too long: at most 200000 tokens',
        ),
        isNull,
        reason: 'window wording must not be read as an output ceiling',
      );
    });
  });

  group('claudeMaxTokensNextOn400', () {
    test('adopts the stated ceiling instead of guessing', () {
      expect(
        claudeMaxTokensNextOn400(
          errorBody: ceilingBody,
          current: claudeMaxTokensInitial,
          attempts: 0,
        ),
        64000,
      );
    });

    test('never retries the value that just failed', () {
      expect(
        claudeMaxTokensNextOn400(
          errorBody: ceilingBody,
          current: 64000,
          attempts: 1,
        ),
        isNull,
        reason: 'retrying an identical max_tokens would loop forever',
      );
    });

    test('gives up once attempts are exhausted', () {
      expect(
        claudeMaxTokensNextOn400(
          errorBody: ceilingBody,
          current: claudeMaxTokensInitial,
          attempts: claudeMaxTokensMaxAttempts,
        ),
        isNull,
      );
    });

    test('leaves a value the caller pinned completely alone', () {
      expect(
        claudeMaxTokensNextOn400(
          errorBody: ceilingBody,
          current: claudeMaxTokensInitial,
          attempts: 0,
          pinned: true,
        ),
        isNull,
        reason: 'customBody max_tokens is the caller\'s explicit choice',
      );
    });

    test('unrelated 400s surface unchanged', () {
      expect(
        claudeMaxTokensNextOn400(
          errorBody: '{"message":"model: not_found"}',
          current: claudeMaxTokensInitial,
          attempts: 0,
        ),
        isNull,
        reason: 'an unrelated failure must not buy a wasted retry',
      );
    });

    test('prompt-too-long uses only the room left, never below the floor', () {
      expect(
        claudeMaxTokensNextOn400(
          errorBody: 'prompt is too long: 180000 tokens > 200000 maximum',
          current: claudeMaxTokensInitial,
          attempts: 0,
        ),
        20000,
        reason: 'the leftover window is this request\'s output room',
      );
      expect(
        claudeMaxTokensNextOn400(
          errorBody: 'prompt is too long: 195000 tokens > 200000 maximum',
          current: claudeMaxTokensInitial,
          attempts: 0,
        ),
        isNull,
        reason: '5000 is below claudeMaxTokensFloor, so we refuse',
      );
      expect(
        claudeMaxTokensNextOn400(
          errorBody: 'prompt is too long: 190000 tokens > 200000 maximum',
          current: claudeMaxTokensFloor,
          attempts: 0,
        ),
        isNull,
        reason: 'already at the floor, and slack (10000) is below it',
      );
    });

    test('unreadable max_tokens rejections drop to the floor once', () {
      const body = '{"message":"max_tokens must not exceed the provider cap"}';
      expect(
        claudeMaxTokensNextOn400(
          errorBody: body,
          current: claudeMaxTokensInitial,
          attempts: 0,
        ),
        claudeMaxTokensFloor,
      );
      expect(
        claudeMaxTokensNextOn400(
          errorBody: body,
          current: claudeMaxTokensFloor,
          attempts: 1,
        ),
        isNull,
        reason: 'the floor is the hard lower bound — below it, throw',
      );
    });
  });

  group('negotiation constants', () {
    test('the floor replaces the old 4096 fallback', () {
      expect(claudeMaxTokensFloor, 12800);
      expect(claudeMaxTokensFloor, greaterThan(4096));
      expect(claudeMaxTokensInitial, 128000);
      expect(claudeMaxTokensInitial, greaterThan(claudeMaxTokensFloor));
      expect(claudeMaxTokensMaxAttempts, 2);
    });
  });

  group('claudeThinkingBudgetForMaxTokens', () {
    test('leaves a budget the ceiling can carry alone', () {
      expect(claudeThinkingBudgetForMaxTokens(32000, 128000), 32000);
      expect(claudeThinkingBudgetForMaxTokens(1024, 12800), 1024);
    });

    test('shrinks a budget the ceiling cannot carry below max_tokens', () {
      expect(claudeThinkingBudgetForMaxTokens(32000, 12800), 12799);
      expect(claudeThinkingBudgetForMaxTokens(16000, 16000), 15999);
    });

    test('passes off / auto budgets through untouched', () {
      expect(claudeThinkingBudgetForMaxTokens(null, 12800), isNull);
      expect(claudeThinkingBudgetForMaxTokens(0, 12800), 0);
    });

    test('refuses to invent a sub-minimum budget', () {
      expect(
        claudeThinkingBudgetForMaxTokens(32000, 1024),
        32000,
        reason: 'below the 1024-token minimum there is nothing to send',
      );
    });
  });

  group('parseClaudePromptTooLongWindow', () {
    test('reads the stated window', () {
      expect(
        parseClaudePromptTooLongWindow(
          'prompt is too long: 180000 tokens > 200000 maximum',
        ),
        200000,
      );
    });

    test('returns null for unrelated bodies', () {
      expect(parseClaudePromptTooLongWindow(ceilingBody), isNull);
      expect(parseClaudePromptTooLongWindow(''), isNull);
    });
  });

  group('LearnedMaxOutputCaps', () {
    test('round-trips a stated ceiling and keeps the minimum', () async {
      await LearnedMaxOutputCaps.record('provider', 'claude-x', 64000);
      expect(await LearnedMaxOutputCaps.lookup('provider', 'claude-x'), 64000);
      expect(LearnedMaxOutputCaps.peek('provider', 'claude-x'), 64000);

      await LearnedMaxOutputCaps.record('provider', 'claude-x', 128000);
      expect(
        await LearnedMaxOutputCaps.lookup('provider', 'claude-x'),
        64000,
        reason: 'a raised ceiling would restart the reject-and-retry loop',
      );

      await LearnedMaxOutputCaps.record('provider', 'claude-x', 32000);
      expect(await LearnedMaxOutputCaps.lookup('provider', 'claude-x'), 32000);
    });

    test('scopes entries per provider and unknown models learn nothing', () async {
      await LearnedMaxOutputCaps.record('a', 'claude-x', 64000);
      expect(await LearnedMaxOutputCaps.lookup('b', 'claude-x'), isNull);
      expect(await LearnedMaxOutputCaps.lookup('a', 'claude-y'), isNull);
    });

    test('drops values outside the sane band', () async {
      await LearnedMaxOutputCaps.record('p', 'm', 512);
      expect(await LearnedMaxOutputCaps.lookup('p', 'm'), isNull);
      await LearnedMaxOutputCaps.record('p', 'm', 1000000);
      expect(await LearnedMaxOutputCaps.lookup('p', 'm'), isNull);
    });

    test('persists under a key that backups skip', () async {
      await LearnedMaxOutputCaps.record('p', 'm', 64000);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LearnedMaxOutputCaps.prefsKey), contains('64000'));

      final snapshot = await SharedPreferencesAsync.instance;
      final map = await snapshot.snapshot();
      expect(
        map.containsKey(LearnedMaxOutputCaps.prefsKey),
        isFalse,
        reason: 'learned ceilings are device observations, not user data',
      );
    });

    test('rememberClaudeOutputCeiling stores only parseable ceilings', () async {
      await rememberClaudeOutputCeiling(
        'p',
        'm',
        'prompt is too long: 190000 tokens > 200000 maximum',
      );
      expect(await LearnedMaxOutputCaps.lookup('p', 'm'), isNull);

      await rememberClaudeOutputCeiling('p', 'm', ceilingBody);
      expect(await LearnedMaxOutputCaps.lookup('p', 'm'), 64000);
    });
  });
}

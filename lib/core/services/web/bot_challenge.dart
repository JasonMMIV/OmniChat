// Bot-challenge detection for web_fetch.
//
// Verification pages are not content. A plain HTTP client cannot solve AWS
// WAF, Cloudflare Turnstile, hashcash or Reddit's JS challenge, so the tool
// returns a short `bot_challenge` error instead of extracting the challenge
// HTML as if it were the article.

enum BotChallengeKind {
  awsWaf('AWS WAF'),
  cloudflare('Cloudflare'),
  hashcash('hashcash'),
  reddit('Reddit'),
  dataDome('DataDome'),
  perimeterX('PerimeterX'),
  imperva('Imperva'),
  akamai('Akamai'),
  generic('bot-verification');

  const BotChallengeKind(this.label);

  final String label;
}

class BotChallenge {
  const BotChallenge({required this.kind, required this.marker});

  final BotChallengeKind kind;

  /// The literal marker that matched, kept for debugging and tests.
  final String marker;

  String get provider => kind.label;
}

class BotChallengeDetector {
  BotChallengeDetector._();

  static const Set<int> _challengeStatuses = <int>{202, 401, 403, 429, 503};

  /// Detects a verification page in [html]. [status] keeps the generic
  /// fallback and Turnstile detection conservative: a normal 200 page that
  /// embeds a Turnstile widget must not be classified as a challenge.
  static BotChallenge? detect(String html, {int? status}) {
    if (html.isEmpty) return null;
    final lower = html.toLowerCase();

    final aws = _awsWaf(lower, status);
    if (aws != null) return aws;

    final cloudflare = _cloudflare(lower, status);
    if (cloudflare != null) return cloudflare;

    final hashcash = _hashcash(lower);
    if (hashcash != null) return hashcash;

    final reddit = _reddit(lower);
    if (reddit != null) return reddit;

    final dataDome = _dataDome(lower, status);
    if (dataDome != null) return dataDome;

    final perimeterX = _perimeterX(lower, status);
    if (perimeterX != null) return perimeterX;

    final imperva = _imperva(lower, status);
    if (imperva != null) return imperva;

    final akamai = _akamai(lower, status);
    if (akamai != null) return akamai;

    if (status != null && _challengeStatuses.contains(status)) {
      return _generic(lower);
    }
    return null;
  }

  static BotChallenge? _awsWaf(String lower, int? status) {
    if (lower.contains('gokuprops')) {
      return const BotChallenge(
        kind: BotChallengeKind.awsWaf,
        marker: 'gokuprops',
      );
    }
    if (status != null &&
        _challengeStatuses.contains(status) &&
        lower.contains('token.awswaf.com')) {
      return const BotChallenge(
        kind: BotChallengeKind.awsWaf,
        marker: 'token.awswaf.com',
      );
    }
    if (status != null &&
        _challengeStatuses.contains(status) &&
        lower.contains('awswafintegration') &&
        _hasHumanVerificationCopy(lower)) {
      return const BotChallenge(
        kind: BotChallengeKind.awsWaf,
        marker: 'awswafintegration',
      );
    }
    return null;
  }

  static BotChallenge? _cloudflare(String lower, int? status) {
    for (final marker in const <String>['cf-chl', 'cf_chl_opt', '__cf_chl']) {
      if (lower.contains(marker)) {
        return BotChallenge(kind: BotChallengeKind.cloudflare, marker: marker);
      }
    }
    if (status != null &&
        _challengeStatuses.contains(status) &&
        lower.contains('challenges.cloudflare.com') &&
        _hasHumanVerificationCopy(lower)) {
      return const BotChallenge(
        kind: BotChallengeKind.cloudflare,
        marker: 'challenges.cloudflare.com',
      );
    }
    return null;
  }

  static BotChallenge? _hashcash(String lower) {
    for (final marker in const <String>['/__challenge/', 'hashcash_config']) {
      if (lower.contains(marker)) {
        return BotChallenge(kind: BotChallengeKind.hashcash, marker: marker);
      }
    }
    if (lower.contains('hashcash') &&
        lower.contains('checking your browser')) {
      return const BotChallenge(
        kind: BotChallengeKind.hashcash,
        marker: 'hashcash',
      );
    }
    return null;
  }

  static BotChallenge? _reddit(String lower) {
    if (lower.contains('jsc_token')) {
      return const BotChallenge(
        kind: BotChallengeKind.reddit,
        marker: 'jsc_token',
      );
    }
    if (lower.contains('js_challenge') &&
        lower.contains('reddit.com') &&
        lower.contains('<form')) {
      return const BotChallenge(
        kind: BotChallengeKind.reddit,
        marker: 'js_challenge',
      );
    }
    return null;
  }

  static BotChallenge? _dataDome(String lower, int? status) {
    for (final marker in const <String>[
      'captcha-delivery.com',
      'geo.captcha-delivery.com',
    ]) {
      if (lower.contains(marker)) {
        return BotChallenge(kind: BotChallengeKind.dataDome, marker: marker);
      }
    }
    if (status != null &&
        _challengeStatuses.contains(status) &&
        lower.contains('datadome') &&
        _hasHumanVerificationCopy(lower)) {
      return const BotChallenge(
        kind: BotChallengeKind.dataDome,
        marker: 'datadome',
      );
    }
    return null;
  }

  static BotChallenge? _perimeterX(String lower, int? status) {
    for (final marker in const <String>[
      'px-captcha',
      '_pxcaptcha',
      'captcha.px-cdn.net',
    ]) {
      if (lower.contains(marker)) {
        return BotChallenge(kind: BotChallengeKind.perimeterX, marker: marker);
      }
    }
    if (status != null &&
        _challengeStatuses.contains(status) &&
        lower.contains('perimeterx') &&
        _hasHumanVerificationCopy(lower)) {
      return const BotChallenge(
        kind: BotChallengeKind.perimeterX,
        marker: 'perimeterx',
      );
    }
    return null;
  }

  static BotChallenge? _imperva(String lower, int? status) {
    for (final marker in const <String>[
      'incapsula incident',
      '_incapsula_resource',
      'request unsuccessful. incapsula',
    ]) {
      if (lower.contains(marker)) {
        return BotChallenge(kind: BotChallengeKind.imperva, marker: marker);
      }
    }
    if (status != null &&
        _challengeStatuses.contains(status) &&
        lower.contains('incapsula') &&
        _hasHumanVerificationCopy(lower)) {
      return const BotChallenge(
        kind: BotChallengeKind.imperva,
        marker: 'incapsula',
      );
    }
    return null;
  }

  static BotChallenge? _akamai(String lower, int? status) {
    for (final marker in const <String>[
      'bm-verify',
      'sec-if-cpt',
      'akamai-bot-manager',
    ]) {
      if (lower.contains(marker)) {
        return BotChallenge(kind: BotChallengeKind.akamai, marker: marker);
      }
    }
    if (status != null &&
        _challengeStatuses.contains(status) &&
        lower.contains('_abck') &&
        _hasHumanVerificationCopy(lower)) {
      return const BotChallenge(kind: BotChallengeKind.akamai, marker: '_abck');
    }
    return null;
  }

  static BotChallenge? _generic(String lower) {
    var hits = 0;
    String? marker;
    for (final candidate in const <String>[
      'checking your browser',
      'verify you are human',
      'enable javascript and cookies',
      'javascript required',
      'unusual traffic',
      'captcha',
    ]) {
      if (lower.contains(candidate)) {
        hits++;
        marker ??= candidate;
      }
    }
    if (hits < 2) return null;
    return BotChallenge(kind: BotChallengeKind.generic, marker: marker!);
  }

  static bool _hasHumanVerificationCopy(String lower) =>
      lower.contains('verify you are human') ||
      lower.contains('checking your browser') ||
      lower.contains('just a moment') ||
      lower.contains('enable javascript and cookies') ||
      lower.contains('javascript required');
}

import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'background_sync_policy.dart';
import 'local_notifications.dart';
import 'offline_cache.dart';
import 'session_store.dart';

/// Where the API lives, for this build on this platform.
///
/// Set `--dart-define=API_BASE_URL=https://api.example.com` for a deployed
/// build. Physical phones must use an explicitly configured HTTPS origin.
///
/// Left unset, the two defaults differ because the right answer does:
///
///  - **Web.** The compiled app is served by the API itself, so the API is
///    wherever the page came from.
///  - **Native.** `10.0.2.2` is the Android emulator's alias for the host
///    machine; `localhost` inside the emulator is the emulator itself.
String resolveBaseUrl() {
  const configured = String.fromEnvironment('API_BASE_URL');
  if (kReleaseMode && !kIsWeb && configured.isEmpty) {
    throw ArgumentError(
      'API_BASE_URL must be supplied for a native release build. '
      'Use a public HTTPS API origin.',
    );
  }
  final raw = configured.isNotEmpty
      ? configured
      : kIsWeb
          ? Uri.base.origin
          : defaultTargetPlatform == TargetPlatform.android
              ? 'http://10.0.2.2:3000'
              : 'http://127.0.0.1:3000';
  // A local release-web preview derives its API origin from the page itself.
  // Keep the native release invariant intact while allowing that explicitly
  // local, same-origin development case to use http://localhost.
  final localWebPreview = kIsWeb &&
      configured.isEmpty &&
      {'localhost', '127.0.0.1', '::1', '[::1]'}.contains(Uri.base.host);
  return normalizeBaseUrl(raw, release: kReleaseMode && !localWebPreview);
}

/// Validates and canonicalises an API origin before it is used to construct a
/// request. A trailing slash is removed so paths cannot become `//api/...`.
String normalizeBaseUrl(String raw, {bool? release}) {
  final value = raw.trim();
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      !{'http', 'https'}.contains(uri.scheme)) {
    throw ArgumentError.value(
        raw, 'API_BASE_URL', 'must be an absolute http:// or https:// URL');
  }
  if (uri.userInfo.isNotEmpty) {
    throw ArgumentError.value(
      raw,
      'API_BASE_URL',
      'must not contain embedded credentials',
    );
  }
  // A release artifact must never silently target a loopback or cleartext
  // origin. Debug builds retain the emulator/simulator localhost defaults;
  // physical phones use the public HTTPS deployment path.
  final isRelease = release ?? kReleaseMode;
  final isLoopback = uri.host == 'localhost' ||
      uri.host == '127.0.0.1' ||
      uri.host == '::1' ||
      uri.host == '[::1]';
  if (isRelease && isLoopback) {
    throw ArgumentError.value(
      raw,
      'API_BASE_URL',
      'release builds must not target a loopback address; use a reachable HTTPS API origin',
    );
  }
  if (isRelease && uri.scheme != 'https') {
    throw ArgumentError.value(
      raw,
      'API_BASE_URL',
      'release builds require HTTPS',
    );
  }
  if (uri.query.isNotEmpty || uri.fragment.isNotEmpty) {
    throw ArgumentError.value(
        raw, 'API_BASE_URL', 'must not include a query string or fragment');
  }
  return value.replaceFirst(RegExp(r'/+$'), '');
}

/// Formats a calendar date without converting it through UTC. Date filters
/// represent the user's local calendar day; converting midnight to ISO UTC
/// shifts it for users east of UTC.
String dateOnly(DateTime value) {
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
}

/// How long any single request may take before it is treated as failed.
///
/// Applied to *every* call, including the unauthenticated ones. A request with
/// no timeout does not fail — it hangs, and a sign-in button that spins forever
/// with no error and no way back is indistinguishable from a crashed app. That
/// is the exact shape of a server whose host went to sleep mid-request: the TCP
/// connection is accepted and then nothing ever comes back.
const Duration kRequestTimeout = Duration(seconds: 20);

/// A public, credential-free readiness probe for the API edge.
///
/// The API deliberately exposes `/healthz` outside the `/api` prefix so a
/// reverse proxy and a phone can distinguish an unreachable host from an
/// authenticated session problem without sending financial data.
class ApiConnectionCheck {
  const ApiConnectionCheck({
    required this.healthy,
    required this.statusCode,
    required this.detail,
    required this.checkedAt,
  });

  final bool healthy;
  final int? statusCode;
  final String detail;
  final DateTime checkedAt;
}

enum _RefreshFailure { none, unavailable, rejected }

/// The server did not receive this idempotent change because the device was
/// offline. The UI may keep its optimistic state; [ApiClient] will replay the
/// request when the session next resumes with connectivity.
class OfflineMutationQueuedException implements Exception {
  const OfflineMutationQueuedException(this.path);

  final String path;

  @override
  String toString() =>
      'Saved on this device. It will sync automatically when you are online.';
}

class OfflineMutationRejectedException implements Exception {
  const OfflineMutationRejectedException(
    this.path,
    this.statusCode, {
    this.method = 'PATCH',
    this.reason,
    this.enqueuedAt,
  });

  final String path;
  final int statusCode;
  final String method;
  final String? reason;
  final DateTime? enqueuedAt;

  @override
  String toString() => reason == null || reason!.isEmpty
      ? 'This change could not be saved and will not be retried automatically.'
      : reason!;
}

/// Thin client over the FINVERSE API.
///
/// It parses JSON into models but contains no financial business logic. The
/// financial rules live server-side in the domain layer
/// (see ADR-0002) so that the phone and any future web client cannot drift
/// apart in their arithmetic.
///
/// It does own one piece of protocol: attaching the access token and, when the
/// server says it has expired, exchanging the refresh token exactly once before
/// retrying. Access tokens are short-lived, so without that every screen would
/// have to handle a 401 itself.
class ApiClient implements BackgroundSyncClient {
  ApiClient(
      {http.Client? httpClient,
      String? baseUrl,
      SessionStore? sessionStore,
      OfflineCacheStore? offlineCache,
      LocalNotificationService? localNotifications})
      : _http = httpClient ?? http.Client(),
        sessionStore = sessionStore ?? SecureSessionStore(),
        offlineCache = offlineCache ?? NoopOfflineCacheStore(),
        localNotifications = localNotifications ?? LocalNotificationService(),
        baseUrl = baseUrl ?? resolveBaseUrl();

  final http.Client _http;
  final String baseUrl;
  final SessionStore sessionStore;
  final OfflineCacheStore offlineCache;
  final LocalNotificationService localNotifications;

  /// True when this build points at the device or simulator itself. This is
  /// valid for an iOS simulator, but never reaches a Windows development API
  /// from a physical iPhone.
  bool get usesLoopbackOrigin {
    final host = Uri.tryParse(baseUrl)?.host;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '[::1]';
  }

  String get connectionFailureMessage {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        usesLoopbackOrigin) {
      return 'This iPhone build is using a local-only API address. Rebuild it with API_BASE_URL set to the public HTTPS API, or to the Windows computer\'s LAN address while both devices share Wi-Fi.';
    }
    return "Couldn't reach the server. Check your connection.";
  }

  SessionTokens? _tokens;
  // A refresh rotation can succeed on the server while the platform keystore
  // is temporarily unavailable. Keep the new token in memory and retry the
  // durable write on the next authenticated request instead of falling back to
  // a server-revoked refresh token.
  SessionTokens? _pendingSessionWrite;
  Future<bool>? _refreshFuture;
  Future<int>? _replayFuture;
  _RefreshFailure _lastRefreshFailure = _RefreshFailure.none;
  final ValueNotifier<DateTime?> offlineCacheStatus = ValueNotifier(null);

  /// Number of idempotent writes waiting for connectivity. This is exposed so
  /// the shell can explain why an offline edit is still pending.
  final ValueNotifier<int> pendingMutationCount = ValueNotifier(0);
  final ValueNotifier<int> rejectedMutationCount = ValueNotifier(0);
  final List<OfflineMutationRejectedException> _rejectedMutations = [];

  /// Monotonically increasing revision for successful authenticated writes.
  ///
  /// Screens in the IndexedStack stay alive while the user moves between
  /// tabs. Broadcasting a revision lets them invalidate their reads as soon
  /// as a bank sync, categorisation, budget, or goal mutation completes,
  /// without coupling the API client to a state-management package.
  final ValueNotifier<int> dataRevision = ValueNotifier(0);

  DateTime? get offlineCacheUpdatedAt => offlineCacheStatus.value;
  bool get usedOfflineCache => offlineCacheStatus.value != null;
  void resetOfflineStatus() => offlineCacheStatus.value = null;

  void dismissRejectedMutations() {
    _rejectedMutations.clear();
    rejectedMutationCount.value = 0;
  }

  List<OfflineMutationRejectedException> get rejectedMutations =>
      List.unmodifiable(_rejectedMutations);

  void dismissRejectedMutation(OfflineMutationRejectedException mutation) {
    _rejectedMutations.remove(mutation);
    rejectedMutationCount.value = _rejectedMutations.length;
  }

  /// Called when the session is gone for good, so the app can show sign-in.
  void Function()? onSessionExpired;

  Uri _uri(String path) => Uri.parse('$baseUrl/api$path');

  /// True when a stored session was found. Call once at startup.
  @override
  Future<bool> restoreSession() async {
    _tokens = await sessionStore.read();
    final stored = _tokens;
    if (stored == null) {
      pendingMutationCount.value = 0;
      rejectedMutationCount.value = 0;
      _rejectedMutations.clear();
      return false;
    }

    // Do not let an already-expired refresh token create a confusing loop of
    // failed API calls. The server remains authoritative, but the timestamp
    // lets us clear an obviously dead local session before rendering the app.
    final refreshExpiry = stored.refreshExpiresAt.isEmpty
        ? null
        : DateTime.tryParse(stored.refreshExpiresAt);
    if (refreshExpiry != null && !refreshExpiry.isAfter(DateTime.now())) {
      await signOut(notifyServer: false);
      return false;
    }

    // A user who leaves the app for more than the short access-token lifetime
    // should return directly to a refreshed session, not to a dashboard that
    // flashes errors while its first batch of requests discovers the expiry.
    if (_accessTokenExpired(stored.accessToken) && !await _refresh()) {
      // A network outage should leave a valid refresh credential in place so
      // the offline cache can still render and the next resume can retry. Only
      // an authoritative 4xx/revocation response justifies signing out.
      if (_lastRefreshFailure == _RefreshFailure.rejected) {
        await signOut(notifyServer: false);
        return false;
      }
    }
    if (_tokens != null) {
      await _refreshPendingMutationCount();
      await replayOfflineMutations();
    }
    return _tokens != null;
  }

  bool get isAuthenticated => _tokens != null;

  /// Checks the public API edge without attaching a session token.
  ///
  /// A 503 means the host is reachable but its database is not ready; that is
  /// materially different from a timeout, and the support UI explains both.
  Future<ApiConnectionCheck> checkConnection() async {
    final checkedAt = DateTime.now();
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/healthz'))
          .timeout(const Duration(seconds: 8));
      final healthy = response.statusCode >= 200 && response.statusCode < 300;
      final detail = response.statusCode == 503
          ? 'The API is reachable, but its database is not ready.'
          : !healthy &&
                  !kIsWeb &&
                  defaultTargetPlatform == TargetPlatform.iOS &&
                  usesLoopbackOrigin
              ? connectionFailureMessage
              : healthy
                  ? 'The API is online.'
                  : 'The API responded with HTTP ${response.statusCode}.';
      return ApiConnectionCheck(
        healthy: healthy,
        statusCode: response.statusCode,
        detail: detail,
        checkedAt: checkedAt,
      );
    } on TimeoutException {
      return ApiConnectionCheck(
        healthy: false,
        statusCode: null,
        detail: 'The API did not respond within 8 seconds.',
        checkedAt: checkedAt,
      );
    } on http.ClientException {
      return ApiConnectionCheck(
        healthy: false,
        statusCode: null,
        detail: 'The API host could not be reached from this device.',
        checkedAt: checkedAt,
      );
    } catch (_) {
      return ApiConnectionCheck(
        healthy: false,
        statusCode: null,
        detail: 'The API connection could not be checked.',
        checkedAt: checkedAt,
      );
    }
  }

  bool _accessTokenExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = payload['exp'];
      return exp is num &&
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) >= exp.toInt();
    } catch (_) {
      // Test doubles and older tokens may not be JWTs. Let the API decide in
      // that case; a malformed local value is not evidence that the session is
      // expired.
      return false;
    }
  }

  Map<String, String> _headers({bool json = false}) => {
        if (json) 'content-type': 'application/json',
        if (_tokens != null) 'authorization': 'Bearer ${_tokens!.accessToken}',
      };

  Future<http.Response> _perform(
    String method,
    String path,
    Object? body,
    bool allowRetry,
  ) async {
    await _retryPendingSessionWrite();
    final request = http.Request(method, _uri(path))
      ..headers.addAll(_headers(json: body != null));
    if (body != null) request.body = jsonEncode(body);

    final response = await http.Response.fromStream(
      await _http.send(request).timeout(kRequestTimeout),
    );

    if (response.statusCode == 401 && allowRetry && _tokens != null) {
      if (await _refresh()) return _perform(method, path, body, false);
      if (_lastRefreshFailure == _RefreshFailure.rejected) {
        await signOut(notifyServer: false);
        onSessionExpired?.call();
      }
    }

    return response;
  }

  Future<dynamic> _get(String path) async {
    final owner = _cacheOwner;
    try {
      final response = await _perform('GET', path, null, true);
      if (response.statusCode >= 400) {
        // If the access token was stale but the refresh request could not
        // reach the server, this is an offline condition rather than an
        // authorization decision. Prefer the user-scoped encrypted cache and
        // keep the refresh credential for the next resume.
        if (response.statusCode == 401 &&
            _lastRefreshFailure == _RefreshFailure.unavailable) {
          return await _cachedOrThrow(
            owner,
            path,
            ApiException(path, response.statusCode, response.body),
          );
        }
        if (response.statusCode < 500) {
          throw PlanUpgradeRequiredException.maybeFrom(path, response) ??
              ApiException(path, response.statusCode, response.body);
        }
        return await _cachedOrThrow(owner, path,
            ApiException(path, response.statusCode, response.body));
      }
      if (owner != null && response.body.isNotEmpty && !_neverCache(path)) {
        try {
          await offlineCache.write(owner, path, response.body);
        } catch (_) {
          // A cache failure must never turn a successful API read into an error.
        }
      }
      return jsonDecode(response.body);
    } on PlanUpgradeRequiredException {
      // Not a network failure, so serving stale cache would be wrong: the
      // server has answered, and its answer is "upgrade".
      rethrow;
    } on ApiException {
      rethrow;
    } on TimeoutException catch (error) {
      return _cachedOrThrow(owner, path, error);
    } on http.ClientException catch (error) {
      return _cachedOrThrow(owner, path, error);
    }
  }

  Future<dynamic> _cachedOrThrow(
      String? owner, String path, Object original) async {
    if (owner != null && !_neverCache(path)) {
      try {
        final cached = await offlineCache.read(owner, path);
        if (cached != null) {
          final current = offlineCacheStatus.value;
          offlineCacheStatus.value =
              current == null || cached.updatedAt.isBefore(current)
                  ? cached.updatedAt
                  : current;
          return jsonDecode(cached.body);
        }
      } catch (_) {
        // Preserve the network error; corrupt or unavailable cache is not data.
      }
    }
    throw original;
  }

  bool _neverCache(String path) => path.startsWith('/auth/');

  String? get sessionUserId => _cacheOwner;

  String? get _cacheOwner {
    if (_tokens?.userId != null) return _tokens!.userId;
    final token = _tokens?.accessToken;
    if (token == null) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
          as Map<String, dynamic>;
      return payload['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final response = await _perform(method, path, body, true);
    if (response.statusCode >= 400) {
      throw PlanUpgradeRequiredException.maybeFrom(path, response) ??
          ApiException(path, response.statusCode, response.body);
    }
    // Auth endpoints have their own response/session lifecycle. All other
    // successful writes can change data that an already-mounted screen reads.
    if (!path.startsWith('/auth/')) dataRevision.value++;
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  Future<void> _refreshPendingMutationCount() async {
    final owner = _cacheOwner;
    if (owner == null) {
      pendingMutationCount.value = 0;
      rejectedMutationCount.value = 0;
      _rejectedMutations.clear();
      return;
    }
    try {
      pendingMutationCount.value =
          (await offlineCache.pendingMutations(owner)).length;
    } catch (_) {
      // A cache/keystore outage should not make the online session unusable.
    }
  }

  /// Replays queued idempotent writes in order. Network failures leave the
  /// remaining rows intact; client errors are discarded because retrying them
  /// forever would hide a permanent validation or permission problem.
  Future<int> replayOfflineMutations() {
    return _replayFuture ??= _replayOfflineMutations().whenComplete(() {
      _replayFuture = null;
    });
  }

  Future<int> _replayOfflineMutations() async {
    final owner = _cacheOwner;
    if (owner == null) return 0;
    List<QueuedApiMutation> pending;
    try {
      pending = await offlineCache.pendingMutations(owner);
    } catch (_) {
      return 0;
    }

    var replayed = 0;
    for (final mutation in pending) {
      dynamic body;
      try {
        body = jsonDecode(mutation.body);
      } catch (_) {
        await offlineCache.removeMutation(
            owner, mutation.method, mutation.path);
        continue;
      }

      http.Response response;
      try {
        response = await _perform(
          mutation.method,
          mutation.path,
          body,
          true,
        );
      } on TimeoutException {
        break;
      } on http.ClientException {
        break;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await offlineCache.removeMutation(
            owner, mutation.method, mutation.path);
        replayed++;
        dataRevision.value++;
        continue;
      }
      if (response.statusCode == 401 &&
          _lastRefreshFailure == _RefreshFailure.unavailable) {
        break;
      }
      if (response.statusCode == 408 || response.statusCode == 429) {
        break;
      }
      if (response.statusCode >= 400 && response.statusCode < 500) {
        await offlineCache.removeMutation(
            owner, mutation.method, mutation.path);
        _rejectedMutations.add(OfflineMutationRejectedException(
          mutation.path,
          response.statusCode,
          method: mutation.method,
          reason: _offlineRejectionReason(response.statusCode),
          enqueuedAt: mutation.enqueuedAt,
        ));
        rejectedMutationCount.value = _rejectedMutations.length;
        continue;
      }
      // A server-side outage is transient. Keep this and all following rows.
      break;
    }
    await _refreshPendingMutationCount();
    return replayed;
  }

  Future<Never> _queueOfflineMutation(
      String method, String path, Object body) async {
    final owner = _cacheOwner;
    if (owner == null) {
      throw StateError(
          'Cannot queue a mutation without an authenticated user.');
    }
    await offlineCache.enqueueMutation(owner, method, path, jsonEncode(body));
    offlineCacheStatus.value ??= DateTime.now().toUtc();
    await _refreshPendingMutationCount();
    throw OfflineMutationQueuedException(path);
  }

  String _offlineRejectionReason(int statusCode) {
    switch (statusCode) {
      case 409:
      case 412:
        return 'This change conflicted with a newer server version and was not overwritten.';
      case 403:
        return 'This change is not allowed for the current account.';
      case 404:
        return 'The original record is no longer available.';
      case 422:
      case 400:
        return 'The server rejected this change because it is no longer valid.';
      default:
        return 'This change could not be saved and will not be retried automatically.';
    }
  }

  // ------------------------------------------------------------------ auth

  Future<LegalPolicies> legalPolicies() async {
    final response = await _http.get(_uri('/legal')).timeout(kRequestTimeout);
    if (response.statusCode >= 400) {
      throw ApiException('/legal', response.statusCode, response.body);
    }
    return LegalPolicies.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<PublicUser> register(
    String email,
    String password, {
    required LegalPolicies policies,
    required bool acceptedTerms,
    required bool acceptedPrivacyNotice,
  }) {
    final body = <String, dynamic>{'email': email, 'password': password};
    if (policies.registrationRequired) {
      body.addAll({
        'acceptedTerms': acceptedTerms,
        'termsVersion': policies.terms!.version,
        'acceptedPrivacyNotice': acceptedPrivacyNotice,
        'privacyVersion': policies.privacyNotice!.version,
      });
    }
    return _authenticate('/auth/register', body);
  }

  Future<PublicUser> signIn(String email, String password) =>
      _authenticate('/auth/login', {'email': email, 'password': password});

  Future<PublicUser> verifyMfa(String challengeToken, String code) =>
      _authenticate('/auth/mfa/verify', {
        'challengeToken': challengeToken,
        'code': code,
      });

  Future<MfaStatus> mfaStatus() async =>
      MfaStatus.fromJson(await _get('/auth/mfa') as Map<String, dynamic>);

  Future<MfaEnrollment> enrollMfa(String password) async =>
      MfaEnrollment.fromJson(await _authSend(
        'POST',
        '/auth/mfa/enroll',
        {'password': password},
      ) as Map<String, dynamic>);

  Future<List<String>> enableMfa(String code) async {
    final json = await _authSend('POST', '/auth/mfa/enable', {'code': code})
        as Map<String, dynamic>;
    return (json['recoveryCodes'] as List<dynamic>).cast<String>();
  }

  Future<void> disableMfa(String password, String code) async {
    await _authSend(
        'DELETE', '/auth/mfa', {'password': password, 'code': code});
  }

  Future<dynamic> _authSend(String method, String path, Object body) async {
    final response = await _perform(method, path, body, true);
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw AuthException.fromResponse(response.statusCode, decoded);
    }
    return decoded;
  }

  Future<PublicUser> cancelAccountDeletion(String email, String password) =>
      _authenticate(
        '/auth/cancel-deletion',
        {'email': email, 'password': password},
      );

  Future<void> requestPasswordReset(String email) =>
      _publicAuthAction('/auth/password-reset/request', {'email': email});

  Future<void> confirmPasswordReset(String token, String password) =>
      _publicAuthAction(
        '/auth/password-reset/confirm',
        {'token': token, 'password': password},
      );

  Future<void> confirmEmailVerification(String token) => _publicAuthAction(
        '/auth/email-verification/confirm',
        {'token': token},
      );

  Future<void> requestEmailVerification() async {
    await _send('POST', '/auth/email-verification/request');
  }

  Future<void> _publicAuthAction(String path, Map<String, dynamic> body) async {
    final response = await _http
        .post(
          _uri(path),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(kRequestTimeout);
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw AuthException.fromResponse(response.statusCode, decoded);
    }
  }

  Future<PublicUser> _authenticate(
      String path, Map<String, dynamic> body) async {
    // Deliberately bypasses _perform: there is no session to attach or retry.
    final response = await _http
        .post(
          _uri(path),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(kRequestTimeout);

    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode >= 400) {
      throw AuthException.fromResponse(response.statusCode, decoded);
    }

    if (decoded['mfaRequired'] == true) {
      throw MfaRequiredException(
        decoded['challengeToken'] as String,
        DateTime.parse(decoded['expiresAt'] as String),
      );
    }

    final user = PublicUser.fromJson(decoded['user'] as Map<String, dynamic>);
    final nextTokens = SessionTokens.fromJson(
      decoded['tokens'] as Map<String, dynamic>,
    ).withUserId(user.id);
    // Do not expose an in-memory session until its durable copy exists. A
    // failed keystore write must leave a fresh login signed out, not half
    // authenticated until the next restart.
    await sessionStore.write(nextTokens);
    _tokens = nextTokens;
    _pendingSessionWrite = null;
    await _refreshPendingMutationCount();
    return user;
  }

  /// Share one refresh-token rotation across parallel requests. The dashboard
  /// loads resources concurrently; rotating the same token twice would look
  /// like token reuse and revoke the whole session family.
  Future<bool> _refresh() {
    final existing = _refreshFuture;
    if (existing != null) return existing;
    final future = _refreshInternal();
    _refreshFuture = future;
    future.whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
    return future;
  }

  Future<bool> _refreshInternal() async {
    final refreshToken = _tokens?.refreshToken;
    if (refreshToken == null) return false;

    _lastRefreshFailure = _RefreshFailure.none;

    try {
      final response = await _http
          .post(
            _uri('/auth/refresh'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'refreshToken': refreshToken}),
          )
          .timeout(kRequestTimeout);
      if (response.statusCode >= 500) {
        _lastRefreshFailure = _RefreshFailure.unavailable;
        return false;
      }
      if (response.statusCode >= 400) {
        _lastRefreshFailure = _RefreshFailure.rejected;
        return false;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      // A sign-out can happen while the request is in flight. Never resurrect
      // that local session with a late refresh response.
      if (_tokens?.refreshToken != refreshToken) return false;
      final userId = _cacheOwner;
      final nextTokens = SessionTokens.fromJson(
        decoded['tokens'] as Map<String, dynamic>,
      ).withUserId(userId);
      try {
        await sessionStore.write(nextTokens);
        _tokens = nextTokens;
        _pendingSessionWrite = null;
      } catch (_) {
        // The server has already rotated the refresh token, so retaining the
        // old token would guarantee the next request fails as token reuse.
        // Keep the valid replacement in memory and retry persistence on the
        // next request. Platform plugins can throw a raw exception before the
        // concrete store has a chance to wrap it, so every storage failure is
        // treated as temporarily unavailable here.
        _tokens = nextTokens;
        _pendingSessionWrite = nextTokens;
      }
      return true;
    } on TimeoutException {
      _lastRefreshFailure = _RefreshFailure.unavailable;
      return false;
    } on http.ClientException {
      _lastRefreshFailure = _RefreshFailure.unavailable;
      return false;
    } catch (_) {
      _lastRefreshFailure = _RefreshFailure.rejected;
      return false;
    }
  }

  Future<void> _retryPendingSessionWrite() async {
    final pending = _pendingSessionWrite;
    if (pending == null) return;
    try {
      await sessionStore.write(pending);
      if (identical(_pendingSessionWrite, pending)) {
        _pendingSessionWrite = null;
      }
    } catch (_) {
      // Keep the in-memory replacement alive; the next request gets another
      // bounded opportunity to persist it.
    }
  }

  Future<PublicUser> me() async =>
      PublicUser.fromJson(await _get('/auth/me') as Map<String, dynamic>);

  Future<List<AppSession>> sessions() async {
    final json = await _get('/auth/sessions') as List<dynamic>;
    return json
        .map((e) => AppSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> revokeSession(String sessionId) async {
    await _send('DELETE', '/auth/sessions/${Uri.encodeComponent(sessionId)}');
  }

  /// Revokes every server session when reachable, but always signs this
  /// device out locally. A failed network request must not leave a user stuck
  /// inside a financial session; the boolean tells the caller whether other
  /// devices were confirmed revoked.
  Future<bool> signOutEverywhere() async {
    final owner = _cacheOwner;
    var serverConfirmed = true;
    try {
      await _send('POST', '/auth/logout-all');
    } catch (_) {
      serverConfirmed = false;
    }
    _tokens = null;
    try {
      await sessionStore.clear();
    } catch (_) {
      // The in-memory session is already gone. A later launch can retry the
      // keystore deletion rather than resurrecting this in-process session.
    }
    if (owner != null) {
      try {
        await offlineCache.clearOwner(owner);
      } catch (_) {
        // Local cache cleanup is best-effort and never blocks sign-out.
      }
    }
    pendingMutationCount.value = 0;
    rejectedMutationCount.value = 0;
    _rejectedMutations.clear();
    offlineCacheStatus.value = null;
    return serverConfirmed;
  }

  /// Clears the local session, and by default tells the server to revoke it.
  ///
  /// The local clear happens regardless of whether the server call succeeds —
  /// a user tapping "sign out" on a train with no signal must still end up
  /// signed out on the device.
  Future<void> signOut({bool notifyServer = true}) async {
    final owner = _cacheOwner;
    if (notifyServer && _tokens != null) {
      try {
        await _perform('POST', '/auth/logout', null, false);
      } catch (_) {
        // Offline, or the session was already revoked server-side.
      }
    }
    _tokens = null;
    _pendingSessionWrite = null;
    // Local auth state must end even when the platform keystore or cache is
    // temporarily unavailable (for example while an iPhone is locked). A
    // cleanup failure must never leave the current UI authenticated or make
    // the sign-out action appear to have failed.
    try {
      await sessionStore.clear();
    } catch (_) {
      // The in-memory session is authoritative for this process. The next
      // platform unlock may be required before secure-storage cleanup can
      // succeed; never keep the current process inside the financial UI.
    }
    if (owner != null) {
      try {
        await offlineCache.clearOwner(owner);
      } catch (_) {
        // Cache cleanup is best-effort and never blocks sign-out.
      }
    }
    pendingMutationCount.value = 0;
    rejectedMutationCount.value = 0;
    _rejectedMutations.clear();
    offlineCacheStatus.value = null;
  }

  /// Schedules irreversible erasure after a 30-day recovery window.
  /// Credentials are cleared only after the server accepts the request.
  Future<DateTime> requestAccountDeletion(String password,
      {String? mfaCode}) async {
    final response = await _perform(
      'DELETE',
      '/auth/account',
      {
        'password': password,
        'confirmation': 'DELETE',
        if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
      },
      true,
    );
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw AuthException.fromResponse(response.statusCode, decoded);
    }

    final scheduledFor = DateTime.parse(decoded['purgeScheduledFor'] as String);
    // The server has accepted the deletion. Reuse the same best-effort local
    // cleanup as logout so a locked keystore cannot make a scheduled deletion
    // look like a failed request or resurrect the session on the next launch.
    await signOut(notifyServer: false);
    return scheduledFor;
  }

  Future<String> exportData(String password, {String? mfaCode}) async {
    final response = await _perform(
      'POST',
      '/privacy/export',
      {
        'password': password,
        if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
      },
      true,
    );
    if (response.statusCode >= 400) {
      final decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
      throw AuthException.fromResponse(response.statusCode, decoded);
    }
    return response.body;
  }

  Future<List<int>> monthlyReportPdf({String currency = 'USD'}) async {
    final response = await _perform(
        'GET',
        '/reports/monthly.pdf?currency=${Uri.encodeQueryComponent(currency)}',
        null,
        true);
    if (response.statusCode >= 400) {
      throw ApiException(
          '/reports/monthly.pdf', response.statusCode, response.body);
    }
    return response.bodyBytes;
  }

  Future<PrivacyDashboard> privacyDashboard() async {
    final json = await _get('/privacy') as Map<String, dynamic>;
    return PrivacyDashboard.fromJson(json);
  }

  Future<PrivacyDashboard> updateConsent(String kind, bool granted) async {
    final json = await _send(
      'PATCH',
      '/privacy/consents/${Uri.encodeComponent(kind)}',
      {'granted': granted},
    ) as Map<String, dynamic>;
    return PrivacyDashboard.fromJson(json);
  }

  Future<SyncResult> sync() async {
    final json = await _send('POST', '/sync') as Map<String, dynamic>;
    return SyncResult.fromJson(json);
  }

  Future<Transaction> createManualTransaction({
    required String requestId,
    required String accountId,
    required String postedAt,
    required String description,
    required String categorySlug,
    required int amount,
  }) async {
    final json = await _send('POST', '/transactions/manual', {
      'requestId': requestId,
      'accountId': accountId,
      'postedAt': postedAt,
      'description': description,
      'categorySlug': categorySlug,
      'amount': amount,
    }) as Map<String, dynamic>;
    return Transaction.fromJson(json);
  }

  Future<List<Account>> accounts() async {
    final json = await _get('/accounts') as List<dynamic>;
    return json
        .map((e) => Account.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StatementImportDetail> createStatementImport({
    required String accountId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final json = await _send('POST', '/imports/statements', {
      'accountId': accountId,
      'filename': filename,
      'mimeType': mimeType,
      'contentBase64': base64Encode(bytes),
    }) as Map<String, dynamic>;
    return StatementImportDetail.fromJson(json);
  }

  Future<List<StatementImport>> statementImports() async {
    final json = await _get('/imports/statements') as List<dynamic>;
    return json
        .whereType<Map<String, dynamic>>()
        .map(StatementImport.fromJson)
        .toList();
  }

  Future<StatementImportDetail> statementImport(String id) async {
    final json = await _get('/imports/statements/${Uri.encodeComponent(id)}')
        as Map<String, dynamic>;
    return StatementImportDetail.fromJson(json);
  }

  Future<StatementSummary> statementImportSummary(String id) async {
    final json =
        await _get('/imports/statements/${Uri.encodeComponent(id)}/summary')
            as Map<String, dynamic>;
    return StatementSummary.fromJson(json);
  }

  Future<StatementRow> editStatementRow(
    String importId,
    String rowId,
    Map<String, dynamic> patch,
  ) async {
    final json = await _send(
      'PATCH',
      '/imports/statements/${Uri.encodeComponent(importId)}/rows/${Uri.encodeComponent(rowId)}',
      patch,
    ) as Map<String, dynamic>;
    return StatementRow.fromJson(json);
  }

  Future<List<StatementRow>> decideStatementRows(
    String importId,
    List<String> rowIds,
    String decision,
  ) async {
    final json = await _send(
      'PATCH',
      '/imports/statements/${Uri.encodeComponent(importId)}/rows',
      {'rowIds': rowIds, 'decision': decision},
    ) as List<dynamic>;
    return json
        .whereType<Map<String, dynamic>>()
        .map(StatementRow.fromJson)
        .toList();
  }

  Future<StatementImport> approveStatementImport(String id) async {
    final json = await _send(
      'POST',
      '/imports/statements/${Uri.encodeComponent(id)}/approve',
    ) as Map<String, dynamic>;
    return StatementImport.fromJson(json);
  }

  Future<List<StatementRow>> splitStatementRow(
    String importId,
    String rowId,
    List<Map<String, dynamic>> parts,
  ) async {
    final json = await _send(
      'POST',
      '/imports/statements/${Uri.encodeComponent(importId)}/rows/${Uri.encodeComponent(rowId)}/split',
      {'parts': parts},
    ) as List<dynamic>;
    return json
        .whereType<Map<String, dynamic>>()
        .map(StatementRow.fromJson)
        .toList();
  }

  Future<StatementRow> mergeStatementRows(
      String importId, List<String> rowIds) async {
    final json = await _send(
      'POST',
      '/imports/statements/${Uri.encodeComponent(importId)}/rows/merge',
      {'rowIds': rowIds},
    ) as Map<String, dynamic>;
    return StatementRow.fromJson(json);
  }

  Future<void> deleteStatementSource(String id) async {
    await _send(
      'DELETE',
      '/imports/statements/${Uri.encodeComponent(id)}/source',
    );
  }

  Future<void> deleteStatementImport(String id) async {
    await _send(
      'DELETE',
      '/imports/statements/${Uri.encodeComponent(id)}',
    );
  }

  Future<List<NetWorthSnapshot>> netWorthHistory({
    required String currency,
    int limit = 365,
  }) async {
    final json = await _get(
      '/accounts/net-worth-history?currency=${Uri.encodeQueryComponent(currency)}&limit=$limit',
    ) as List<dynamic>;
    return json
        .map(
            (entry) => NetWorthSnapshot.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  Future<Account> createManualAccount({
    required String name,
    required String type,
    required String currency,
    required int balanceCurrent,
  }) async {
    final json = await _send('POST', '/accounts/manual', {
      'name': name,
      'type': type,
      'currency': currency,
      'balanceCurrent': balanceCurrent,
    }) as Map<String, dynamic>;
    return Account.fromJson(json);
  }

  Future<Account> updateManualAccount(
    String id, {
    required String name,
    required String type,
    required String currency,
    required int balanceCurrent,
  }) async {
    final json = await _send(
      'PATCH',
      '/accounts/manual/${Uri.encodeComponent(id)}',
      {
        'name': name,
        'type': type,
        'currency': currency,
        'balanceCurrent': balanceCurrent,
      },
    ) as Map<String, dynamic>;
    return Account.fromJson(json);
  }

  Future<void> deleteManualAccount(String id) async {
    await _send('DELETE', '/accounts/manual/${Uri.encodeComponent(id)}');
  }

  Future<CashFlowForecast> cashFlowForecast({
    required int days,
    required String currency,
  }) async {
    final json = await _get(
      '/cash-flow-forecast?days=$days&currency=${Uri.encodeQueryComponent(currency)}',
    ) as Map<String, dynamic>;
    return CashFlowForecast.fromJson(json);
  }

  Future<PurchaseScenario> purchaseScenario({
    required int amount,
    required String date,
    required int days,
    required String currency,
  }) async {
    final json = await _get(
      '/purchase-scenario?amount=$amount&date=${Uri.encodeQueryComponent(date)}&days=$days&currency=${Uri.encodeQueryComponent(currency)}',
    ) as Map<String, dynamic>;
    return PurchaseScenario.fromJson(json);
  }

  Future<List<Transaction>> transactions(
      {int limit = 50,
      String? search,
      String? before,
      String? accountId,
      String? categorySlug,
      String? categoryKind,
      bool? pending,
      bool? recurring,
      int? amountMin,
      int? amountMax,
      DateTime? from,
      DateTime? to}) async {
    final page = await transactionsPage(
      limit: limit,
      search: search,
      before: before,
      accountId: accountId,
      categorySlug: categorySlug,
      categoryKind: categoryKind,
      pending: pending,
      recurring: recurring,
      amountMin: amountMin,
      amountMax: amountMax,
      from: from,
      to: to,
    );
    return page.transactions;
  }

  Future<TransactionPage> transactionsPage(
      {int limit = 50,
      String? search,
      String? before,
      String? accountId,
      String? categorySlug,
      String? categoryKind,
      bool? pending,
      bool? recurring,
      int? amountMin,
      int? amountMax,
      DateTime? from,
      DateTime? to}) async {
    final params = <String, String>{'limit': '$limit'};
    void add(String key, String? value) {
      if (value != null && value.isNotEmpty) params[key] = value;
    }

    add('search', search);
    add('before', before);
    add('account', accountId);
    add('category', categorySlug);
    add('kind', categoryKind);
    add('pending', pending?.toString());
    add('recurring', recurring?.toString());
    add('minAmount', amountMin?.toString());
    add('maxAmount', amountMax?.toString());
    add('from', from == null ? null : dateOnly(from));
    add('to', to == null ? null : dateOnly(to));
    final query = Uri(queryParameters: params).query;
    final json = await _get('/transactions?$query') as Map<String, dynamic>;
    final rows = (json['transactions'] as List<dynamic>)
        .map((e) => Transaction.fromJson(e as Map<String, dynamic>))
        .toList();
    return TransactionPage(
      transactions: rows,
      nextCursor: json['nextCursor'] as String?,
      interpretation: json['interpretation'] as String?,
    );
  }

  Future<List<CategoryDefinition>> categories() async {
    final json = await _get('/categories') as Map<String, dynamic>;
    return (json['categories'] as List<dynamic>)
        .map((e) => CategoryDefinition.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Transaction>> needsReview() async {
    final json =
        await _get('/transactions/needs-review') as Map<String, dynamic>;
    return (json['transactions'] as List<dynamic>)
        .map((e) => Transaction.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Recategorize a transaction. With [createRule], the server also writes a
  /// tier-1 rule and backfills every past transaction from the same merchant —
  /// the "never make the same mistake twice" guarantee (ADR-0004).
  Future<String> recategorize(
    String transactionId,
    String categorySlug, {
    bool createRule = true,
  }) async {
    final json = await _send(
      'PATCH',
      '/transactions/$transactionId/category',
      {'categorySlug': categorySlug, 'createRule': createRule},
    ) as Map<String, dynamic>;
    return json['message'] as String? ?? 'Updated.';
  }

  Future<List<CategorizationRule>> categorizationRules() async {
    final json = await _get('/categorization-rules') as Map<String, dynamic>;
    return (json['rules'] as List<dynamic>)
        .map((e) => CategorizationRule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Recognise pasted receipt text without storing it (draft confirmation).
  Future<ReceiptScan> scanReceipt(String text) async {
    final json = await _send(
      'POST',
      '/receipts/scan',
      {'text': text},
    ) as Map<String, dynamic>;
    return ReceiptScan.fromJson(json['scan'] as Map<String, dynamic>);
  }

  /// Attach a parsed receipt to one of the user's transactions.
  Future<ReceiptRecord> attachReceipt(
    String transactionId,
    String text,
  ) async {
    final json = await _send(
      'PUT',
      '/receipts/${Uri.encodeComponent(transactionId)}',
      {'text': text},
    ) as Map<String, dynamic>;
    return ReceiptRecord.fromJson(json['receipt'] as Map<String, dynamic>);
  }

  /// Returns null when this transaction has no stored receipt.
  Future<ReceiptRecord?> receiptForTransaction(String transactionId) async {
    try {
      final json = await _get(
        '/receipts/${Uri.encodeComponent(transactionId)}',
      ) as Map<String, dynamic>;
      return ReceiptRecord.fromJson(json['receipt'] as Map<String, dynamic>);
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> deleteCategorizationRule(String ruleId) async {
    await _send(
      'DELETE',
      '/categorization-rules/${Uri.encodeComponent(ruleId)}',
    );
  }

  Future<Transaction> updateTransactionPreferences(
    String transactionId, {
    String? merchantOverride,
    String? note,
    bool? excludedFromAnalytics,
    bool? isRecurring,
    bool? duplicateReported,
  }) async {
    final body = <String, dynamic>{};
    if (merchantOverride != null) body['merchantOverride'] = merchantOverride;
    if (note != null) body['note'] = note;
    if (excludedFromAnalytics != null) {
      body['excludedFromAnalytics'] = excludedFromAnalytics;
    }
    if (isRecurring != null) body['isRecurring'] = isRecurring;
    if (duplicateReported != null) {
      body['duplicateReported'] = duplicateReported;
    }
    final path = '/transactions/$transactionId/preferences';
    try {
      final json = await _send('PATCH', path, body) as Map<String, dynamic>;
      return Transaction.fromJson(json['transaction'] as Map<String, dynamic>);
    } on TimeoutException {
      return _queueOfflineMutation('PATCH', path, body);
    } on http.ClientException {
      return _queueOfflineMutation('PATCH', path, body);
    }
  }

  Future<List<BudgetProgress>> budgetProgress() async {
    final json = await _get('/budgets/progress') as Map<String, dynamic>;
    return (json['budgets'] as List<dynamic>)
        .map((e) => BudgetProgress.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Transaction> updateTransactionTags(
    String transactionId,
    List<String> tags,
  ) async {
    final path = '/transactions/$transactionId/tags';
    final body = <String, dynamic>{'tags': tags};
    try {
      final json = await _send('PATCH', path, body) as Map<String, dynamic>;
      return Transaction.fromJson(json['transaction'] as Map<String, dynamic>);
    } on TimeoutException {
      return _queueOfflineMutation('PATCH', path, body);
    } on http.ClientException {
      return _queueOfflineMutation('PATCH', path, body);
    }
  }

  Future<Budget> createBudget(String categorySlug, int limitMinorUnits) async {
    final json = await _send('POST', '/budgets', {
      'categorySlug': categorySlug,
      // Minor units. Never send a decimal — see ADR-0003.
      'limitAmount': limitMinorUnits,
    }) as Map<String, dynamic>;
    return Budget.fromJson(json);
  }

  Future<void> deleteBudget(String budgetId) async {
    await _send('DELETE', '/budgets/$budgetId');
  }

  // ------------------------------------------------------- reconciliation

  Future<List<ReconciliationSummary>> reconciliationSummary() async {
    final json = await _get('/reconciliations/summary') as Map<String, dynamic>;
    return (json['accounts'] as List<dynamic>)
        .map((e) => ReconciliationSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Reconciliation>> reconciliations({String? accountId}) async {
    final query = accountId == null
        ? ''
        : '?account=${Uri.encodeQueryComponent(accountId)}';
    final json = await _get('/reconciliations$query') as Map<String, dynamic>;
    return (json['reconciliations'] as List<dynamic>)
        .map((e) => Reconciliation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Derives the balance without recording anything, so the user can see the
  /// comparison before committing to an assertion.
  Future<ReconciliationPreview> previewReconciliation({
    required String accountId,
    required String statementDate,
    required int observedBalance,
  }) async {
    final json = await _get(
      '/reconciliations/preview'
      '?account=${Uri.encodeQueryComponent(accountId)}'
      '&statementDate=${Uri.encodeQueryComponent(statementDate)}'
      '&observedBalance=$observedBalance',
    ) as Map<String, dynamic>;
    return ReconciliationPreview.fromJson(json);
  }

  Future<Reconciliation> recordReconciliation({
    required String accountId,
    required String statementDate,
    required int observedBalance,
    String source = 'statement',
    String? note,
  }) async {
    final json = await _send('POST', '/reconciliations', {
      'accountId': accountId,
      'statementDate': statementDate,
      // Minor units. Never a decimal — see ADR-0003.
      'observedBalance': observedBalance,
      'source': source,
      if (note != null && note.isNotEmpty) 'note': note,
    }) as Map<String, dynamic>;
    return Reconciliation.fromJson(json);
  }

  /// Withdraws an assertion. The server archives rather than deletes it.
  Future<void> withdrawReconciliation(String id) async {
    await _send('DELETE', '/reconciliations/${Uri.encodeComponent(id)}');
  }

  Future<List<GoalProgress>> goals() async {
    final json = await _get('/goals') as Map<String, dynamic>;
    return (json['goals'] as List<dynamic>)
        .map((e) => GoalProgress.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<GoalProgress> createGoal({
    required String name,
    required int targetAmount,
    int initialAmount = 0,
    String? targetDate,
  }) async {
    final json = await _send('POST', '/goals', {
      'name': name,
      'targetAmount': targetAmount,
      'initialAmount': initialAmount,
      if (targetDate != null && targetDate.isNotEmpty) 'targetDate': targetDate,
    }) as Map<String, dynamic>;
    return GoalProgress.fromJson(json);
  }

  Future<GoalProgress> addGoalContribution(String goalId, int amount) async {
    final json = await _send(
      'POST',
      '/goals/$goalId/contributions',
      {'amount': amount},
    ) as Map<String, dynamic>;
    return GoalProgress.fromJson(json);
  }

  Future<void> deleteGoal(String goalId) async {
    await _send('DELETE', '/goals/$goalId');
  }

  Future<List<SplitGroup>> splitGroups() async {
    final json = await _get('/split/groups') as Map<String, dynamic>;
    return (json['groups'] as List<dynamic>)
        .map((e) => SplitGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SplitGroup> createSplitGroup({
    required String name,
    String currency = 'USD',
  }) async {
    final json = await _send('POST', '/split/groups', {
      'name': name,
      'currency': currency,
    }) as Map<String, dynamic>;
    return SplitGroup.fromJson(json);
  }

  Future<SplitGroupDetail> splitGroupDetail(String groupId) async {
    final json = await _get('/split/groups/$groupId') as Map<String, dynamic>;
    return SplitGroupDetail.fromJson(json);
  }

  Future<void> addSplitMember(String groupId, String email) async {
    await _send('POST', '/split/groups/$groupId/invitations', {'email': email});
  }

  Future<SplitInvitation> createSplitInvitation(
      String groupId, String email) async {
    final json = await _send(
      'POST',
      '/split/groups/$groupId/invitations',
      {'email': email},
    ) as Map<String, dynamic>;
    return SplitInvitation.fromJson(json);
  }

  Future<List<SplitInvitation>> splitInvitations() async {
    final json = await _get('/split/invitations') as Map<String, dynamic>;
    return (json['invitations'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SplitInvitation.fromJson)
        .toList();
  }

  Future<void> acceptSplitInvitation(String invitationId) async {
    await _send('POST', '/split/invitations/$invitationId/accept');
  }

  Future<void> declineSplitInvitation(String invitationId) async {
    await _send('POST', '/split/invitations/$invitationId/decline');
  }

  Future<void> revokeSplitInvitation(
      String groupId, String invitationId) async {
    await _send('DELETE', '/split/groups/$groupId/invitations/$invitationId');
  }

  Future<void> removeSplitMember(String groupId, String userId) async {
    await _send(
      'DELETE',
      '/split/groups/$groupId/members/${Uri.encodeComponent(userId)}',
    );
  }

  Future<void> addSplitExpense(
    String groupId, {
    required String description,
    required int amount,
    String? paidByUserId,
    String splitMethod = 'equal',
    Map<String, int>? shares,
  }) async {
    await _send('POST', '/split/groups/$groupId/expenses', {
      'description': description,
      'amount': amount,
      if (paidByUserId != null) 'paidByUserId': paidByUserId,
      'splitMethod': splitMethod,
      if (shares != null)
        'shares': shares.entries
            .map((entry) => {'userId': entry.key, 'amount': entry.value})
            .toList(),
    });
  }

  Future<void> addSplitSettlement(
    String groupId, {
    required String toUserId,
    required int amount,
    String? note,
  }) async {
    await _send('POST', '/split/groups/$groupId/settlements', {
      'toUserId': toUserId,
      'amount': amount,
      if (note != null && note.isNotEmpty) 'note': note,
    });
  }

  Future<void> archiveSplitGroup(String groupId) async {
    await _send('POST', '/split/groups/$groupId/archive');
  }

  Future<List<BankLink>> bankLinks() async {
    final json = await _get('/bank-links') as Map<String, dynamic>;
    return (json['links'] as List<dynamic>)
        .map((row) => BankLink.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  Future<String> createBankLinkToken({
    required String password,
    String? mfaCode,
    String? linkId,
    String platform = 'android',
  }) async {
    final json = await _send(
      'POST',
      '/bank-links/link-token',
      {
        'password': password,
        'platform': platform,
        if (linkId != null) 'linkId': linkId,
        if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
      },
    ) as Map<String, dynamic>;
    return json['token'] as String;
  }

  Future<BankLink> exchangeBankToken({
    required String publicToken,
    required String institutionName,
    String? institutionId,
  }) async {
    final json = await _send('POST', '/bank-links/exchange', {
      'publicToken': publicToken,
      'institutionName': institutionName,
      if (institutionId != null) 'institutionId': institutionId,
    }) as Map<String, dynamic>;
    return BankLink.fromJson(json);
  }

  Future<void> syncBankLink(String linkId) async {
    await _send('POST', '/bank-links/$linkId/sync');
  }

  Future<void> disconnectBank(String linkId) async {
    await _send('DELETE', '/bank-links/$linkId');
  }

  @override
  Future<void> refreshConnectedBanks() async {
    final links = await bankLinks();
    Object? firstError;
    for (final link in links) {
      if (!link.needsReconnect && link.status != 'revoked') {
        try {
          await syncBankLink(link.id);
        } catch (error) {
          firstError ??= error;
        }
      }
    }
    if (firstError != null) throw firstError;
  }

  Future<List<FinanceNotification>> notifications() async {
    final json = await _get('/notifications') as Map<String, dynamic>;
    return (json['notifications'] as List<dynamic>)
        .map((row) => FinanceNotification.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  Future<void> markNotificationRead(String id) async {
    await _send('PATCH', '/notifications/$id/read');
  }

  Future<void> markAllNotificationsRead() async {
    await _send('PATCH', '/notifications/read-all');
  }

  /// Registers this device with the push provider for remote delivery. The
  /// server stores only the opaque provider token; no message or bank data is
  /// sent to it.
  Future<void> registerPushToken(
    String token,
    String platform,
  ) async {
    await _send('POST', '/push/device', {'token': token, 'platform': platform});
  }

  Future<void> unregisterPushToken(String token) async {
    await _send('DELETE', '/push/device', {'token': token});
  }

  // -------------------------------------------------------------- passkeys

  /// True when the server is configured to accept passkeys. The native
  /// platform ceremony (platform authenticator) is invoked by the UI; these
  /// methods carry the challenge and the verified credential.
  Future<bool> passkeysAvailable() async {
    final json = await _get('/webauthn/status') as Map<String, dynamic>;
    return json['available'] == true;
  }

  Future<Map<String, dynamic>> passkeyRegisterOptions({
    required String password,
    String? mfaCode,
  }) async {
    return await _send(
      'POST',
      '/webauthn/register/options',
      {
        'password': password,
        if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
      },
    ) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> passkeyRegisterVerify(
    String id, {
    required String ceremonyId,
    required String password,
    String? mfaCode,
    required String clientDataJson,
    required String attestationObject,
  }) async {
    return await _send('POST', '/webauthn/register/verify', {
      'id': id,
      'ceremonyId': ceremonyId,
      'password': password,
      if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
      'response': {
        'clientDataJSON': clientDataJson,
        'attestationObject': attestationObject,
      },
    }) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> passkeyLoginOptions({String? email}) async {
    return await _send(
      'POST',
      '/webauthn/login/options',
      {if (email != null && email.isNotEmpty) 'email': email},
    ) as Map<String, dynamic>;
  }

  Future<PublicUser> passkeyLoginVerify(
    String id, {
    required String ceremonyId,
    required String clientDataJson,
    required String authenticatorData,
    required String signature,
  }) {
    return _authenticate('/webauthn/login/verify', {
      'id': id,
      'ceremonyId': ceremonyId,
      'response': {
        'clientDataJSON': clientDataJson,
        'authenticatorData': authenticatorData,
        'signature': signature,
      },
    });
  }

  Future<List<Map<String, dynamic>>> passkeyCredentials() async {
    final json = await _get('/webauthn/credentials') as Map<String, dynamic>;
    return (json['credentials'] as List<dynamic>)
        .map((row) => row as Map<String, dynamic>)
        .toList();
  }

  Future<void> passkeyRemove(
    String credentialId, {
    required String password,
    String? mfaCode,
  }) async {
    await _send(
      'DELETE',
      '/webauthn/credentials/${Uri.encodeComponent(credentialId)}',
      {
        'password': password,
        if (mfaCode != null && mfaCode.isNotEmpty) 'mfaCode': mfaCode,
      },
    );
  }

  Future<NotificationPreferences> notificationPreferences() async {
    final json =
        await _get('/notifications/preferences') as Map<String, dynamic>;
    return NotificationPreferences.fromJson(json);
  }

  Future<NotificationPreferences> updateNotificationPreferences(
    NotificationPreferences preferences,
  ) async {
    final json = await _send(
      'PATCH',
      '/notifications/preferences',
      preferences.toJson(),
    ) as Map<String, dynamic>;
    return NotificationPreferences.fromJson(json);
  }

  Future<HealthScore> healthScore({String currency = 'USD'}) async {
    final json = await _get(
            '/health-score?currency=${Uri.encodeQueryComponent(currency)}')
        as Map<String, dynamic>;
    return HealthScore.fromJson(json);
  }

  Future<InsightsReport> insights({String currency = 'USD'}) async {
    final json =
        await _get('/insights?currency=${Uri.encodeQueryComponent(currency)}')
            as Map<String, dynamic>;
    return InsightsReport.fromJson(json);
  }

  Future<DataQualityReport> dataQuality() async {
    final json = await _get('/data-quality') as Map<String, dynamic>;
    return DataQualityReport.fromJson(json);
  }

  Future<AnalyticsReport> analytics({
    String period = 'month',
    DateTime? asOf,
    DateTime? from,
    DateTime? to,
    String currency = 'USD',
  }) async {
    final params = <String, String>{
      'period': period,
      'currency': currency,
    };
    if (asOf != null) params['asOf'] = dateOnly(asOf);
    if (from != null) params['from'] = dateOnly(from);
    if (to != null) params['to'] = dateOnly(to);
    final query = Uri(queryParameters: params).query;
    return AnalyticsReport.fromJson(
      await _get('/analytics?$query') as Map<String, dynamic>,
    );
  }

  Future<AssistantAnswer> askAssistant(
    String question, {
    String currency = 'USD',
  }) async {
    final query = Uri(queryParameters: {
      'question': question.trim(),
      'currency': currency,
    }).query;
    return AssistantAnswer.fromJson(
      await _get('/assistant?$query') as Map<String, dynamic>,
    );
  }

  Future<SubscriptionsReport> subscriptions({String currency = 'USD'}) async {
    final json = await _get(
            '/subscriptions?currency=${Uri.encodeQueryComponent(currency)}')
        as Map<String, dynamic>;
    return SubscriptionsReport.fromJson(json);
  }

  // --------------------------------------------------------------- billing

  Future<PlanSummary> planSummary() async => PlanSummary.fromJson(
      await _get('/billing/subscription') as Map<String, dynamic>);

  Future<List<BillingPlan>> billingPlans() async {
    final json = await _get('/billing/plans') as Map<String, dynamic>;
    return (json['plans'] as List<dynamic>)
        .map((row) => BillingPlan.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  /// Starts a hosted checkout and returns where to send the customer.
  ///
  /// Only a plan id crosses the wire — never a price. The server resolves what
  /// to charge from its own configuration, so a tampered client cannot ask to
  /// be sold something cheaper.
  Future<CheckoutSession> startCheckout(String plan,
      {String interval = 'month'}) async {
    final json = await _send(
      'POST',
      '/billing/checkout-session',
      {'plan': plan, 'interval': interval},
    ) as Map<String, dynamic>;
    return CheckoutSession.fromJson(json);
  }

  /// A link to the provider's own page for cancelling, changing a card, or
  /// downloading invoices. None of those flows are rebuilt in this app.
  Future<String> billingPortalUrl() async {
    final json =
        await _send('POST', '/billing/portal-session') as Map<String, dynamic>;
    return json['url'] as String;
  }

  void close() => _http.close();
}

class TransactionPage {
  const TransactionPage({
    required this.transactions,
    required this.nextCursor,
    this.interpretation,
  });

  final List<Transaction> transactions;
  final String? nextCursor;
  final String? interpretation;
}

/// A rejected sign-in or registration, with something worth showing the user.
///
/// Separate from ApiException because these are the only API errors a person is
/// expected to act on — every other failure is a bug or an outage.
class AuthException implements Exception {
  AuthException(this.message,
      {this.problems = const [], this.retryAfterSeconds});

  factory AuthException.fromResponse(
      int statusCode, Map<String, dynamic> body) {
    final problems = (body['problems'] as List<dynamic>?)?.cast<String>() ??
        const <String>[];

    // The API returns `message` as a string, or as a list when several
    // validation rules failed at once.
    final rawMessage = body['message'];
    final message = rawMessage is List
        ? rawMessage.join(' ')
        : rawMessage as String? ?? 'Something went wrong. Try again.';

    return AuthException(
      statusCode == 429
          ? 'Too many attempts. Wait a moment and try again.'
          : message,
      problems: problems,
      retryAfterSeconds: (body['retryAfterSeconds'] as num?)?.toInt(),
    );
  }

  final String message;

  /// Password-policy failures, so all of them can be fixed in one go rather
  /// than discovered one attempt at a time.
  final List<String> problems;
  final int? retryAfterSeconds;

  String get displayMessage => problems.isEmpty ? message : problems.join('\n');

  @override
  String toString() => displayMessage;
}

class MfaRequiredException implements Exception {
  const MfaRequiredException(this.challengeToken, this.expiresAt);
  final String challengeToken;
  final DateTime expiresAt;
}

class ApiException implements Exception {
  ApiException(this.path, this.statusCode, this.body);

  final String path;
  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode on $path): $body';
}

/// Turns any failure a screen can hit into something worth showing the user.
///
/// Financial apps should never render `ApiException(500 on /api/...): {...}`.
/// The detail stays in the log via [toString]; the person gets the reason and,
/// where possible, the action. Falls back to the raw value only when nothing
/// better exists, so a programming error is still visible during development.
String friendlyErrorMessage(Object error) {
  if (error is AuthException) return error.displayMessage;
  if (error is PlanUpgradeRequiredException) return error.message;
  if (error is OfflineMutationQueuedException) return error.toString();
  if (error is MfaRequiredException) {
    return 'Enter the verification code to continue.';
  }
  if (error is ApiException) {
    final parsed = _apiMessage(error);
    if (parsed != null) return parsed;
    if (error.statusCode == 503) {
      return 'The server is temporarily unavailable. Try again shortly.';
    }
    if (error.statusCode == 401) {
      return 'Your session is no longer valid. Sign in again.';
    }
    if (error.statusCode >= 500) {
      return 'Something went wrong on our side. Try again shortly.';
    }
  }
  if (error is TimeoutException) {
    return 'The server did not respond. Check your connection and try again.';
  }
  if (error is http.ClientException) {
    return "Couldn't reach the server. Check your connection.";
  }
  return error.toString();
}

/// Extracts a server-provided message (string or array) from an API error body.
String? _apiMessage(ApiException error) {
  if (error.body.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(error.body);
    if (decoded is! Map<String, dynamic>) return null;
    final message = decoded['message'];
    if (message is String && message.isNotEmpty) return message;
    if (message is List) {
      final joined = message.whereType<String>().join(' ');
      if (joined.isNotEmpty) return joined;
    }
  } catch (_) {
    // Not JSON; fall through to the generic wording.
  }
  return null;
}

/// The server refused because the user's plan does not include this.
///
/// Recognised centrally in the client rather than screen by screen, so that a
/// feature moving behind the paywall does not require every caller to learn
/// about billing. Without this, a gated route surfaces as a raw JSON blob in a
/// snackbar — which reads as a bug, not a price.
class PlanUpgradeRequiredException implements Exception {
  PlanUpgradeRequiredException({
    required this.path,
    required this.message,
    this.entitlement,
    this.requiredPlan,
  });

  /// Returns null when the response is an ordinary error, so callers can fall
  /// back to [ApiException]. A 403 is only a paywall when the server says so:
  /// an authorisation failure elsewhere must not be dressed up as an upsell.
  static PlanUpgradeRequiredException? maybeFrom(
      String path, http.Response response) {
    if (response.statusCode != 403 || response.body.isEmpty) return null;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['error'] != 'plan_upgrade_required') return null;

      final rawMessage = decoded['message'];
      return PlanUpgradeRequiredException(
        path: path,
        message: rawMessage is String
            ? rawMessage
            : 'Your plan does not include this feature.',
        entitlement: decoded['entitlement'] as String?,
        requiredPlan: decoded['requiredPlan'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  final String path;
  final String message;

  /// The named capability that was missing, e.g. `unlimited_bank_links`.
  final String? entitlement;

  /// The cheapest plan that would have allowed it.
  final String? requiredPlan;

  @override
  String toString() => message;
}

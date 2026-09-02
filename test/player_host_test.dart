import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/services/catalog_api_clients.dart';

import 'helpers/source_text.dart';

/// Which host each client's `player` request goes to, and that its Origin agrees.
///
/// ── WHY THIS PAIRING NEEDS A TEST ───────────────────────────────────────────
///
/// Metrolist sends the player request for its VISIONOS and ANDROID_VR clients to
/// `music.youtube.com` (with a matching Origin/Referer); Auvy sent everything to
/// `www.youtube.com`. Those are the two clients that carry Auvy's playback, so
/// this is the one substantive difference between the two stream chains.
///
/// The failure mode of getting it half-right is silent and confusing: a request
/// to the music host carrying a `www` Origin is a mismatched pair, and InnerTube
/// answers a mismatched pair with a refusal that looks exactly like the throttle
/// this was meant to help with. So the invariant is not "use the music host" —
/// it is "**the host and the Origin always agree**".
void main() {
  group('the player host and its Origin always agree', () {
    for (final c in CatalogApiClients.allStreamClients) {
      test('${c.clientName} ${c.clientVersion}', () {
        expect(c.playerApiUrl, startsWith(c.playerOrigin),
            reason: 'The player request would go to ${c.playerApiUrl} while '
                'claiming Origin ${c.playerOrigin}. InnerTube refuses a '
                'mismatched pair, and the refusal is indistinguishable from '
                'being throttled.');
        expect(c.playerApiUrl, endsWith('/youtubei/v1/'),
            reason: 'The player url is no longer an InnerTube base.');
      });
    }
  });

  group('opting in is per client and reversible', () {
    test('the playback clients ask the music host', () {
      // If this fails, check it is a deliberate revert rather than an accident —
      // the whole point of playerHost being nullable is that a single client can
      // be rolled back on its own.
      final onMusic = CatalogApiClients.allStreamClients
          .where((c) => c.playerHost == 'https://music.youtube.com')
          .map((c) => '${c.clientName}/${c.clientVersion}')
          .toList();
      expect(onMusic, isNotEmpty,
          reason: 'No stream client uses the music player endpoint any more.');
    });

    test('a client with no playerHost is completely unchanged', () {
      // The nullable default is what makes this safe to try: anything not opted
      // in must behave exactly as it did before the field existed.
      const plain = CatalogApiClientInfo(
        clientName: 'X',
        clientVersion: '1',
        clientId: '1',
        userAgent: 'ua',
        apiUrl: 'https://www.youtube.com/youtubei/v1/',
        origin: 'https://www.youtube.com',
      );
      expect(plain.playerApiUrl, plain.apiUrl);
      expect(plain.playerOrigin, plain.origin);
      expect(plain.headers(forPlayer: true)['Origin'],
          plain.headers()['Origin']);
    });

    test('forPlayer swaps Origin AND Referer together', () {
      // Referer is derived from the same value; a version that updated only
      // Origin would send a www Referer to the music host, which is the same
      // mismatch in a different header.
      const opted = CatalogApiClientInfo(
        clientName: 'X',
        clientVersion: '1',
        clientId: '1',
        userAgent: 'ua',
        apiUrl: 'https://www.youtube.com/youtubei/v1/',
        origin: 'https://www.youtube.com',
        playerHost: 'https://music.youtube.com',
      );
      final h = opted.headers(forPlayer: true);
      expect(h['Origin'], 'https://music.youtube.com');
      expect(h['Referer'], 'https://music.youtube.com/');
      // And the catalog headers must NOT move.
      final cat = opted.headers();
      expect(cat['Origin'], 'https://www.youtube.com');
      expect(cat['Referer'], 'https://www.youtube.com/');
    });
  });

  test('WARN: only the PLAYER call uses the player host', () {
    // Catalog traffic (search / browse / next) must keep going to apiUrl. Routing
    // it to the music host as well would be a much larger change than this one
    // is meant to be, and WEB_REMIX already lives there anyway.
    // codeOf, not readAsStringSync: the comments here name both urls while
    // explaining the split, so a raw scan would match the prose. See
    // helpers/source_text.dart.
    final code = codeOf('lib/services/catalog_api_client.dart');
    expect(code.contains(r"'${client.playerApiUrl}player?"), isTrue,
        reason: 'The player call no longer uses playerApiUrl.');
    expect(code.contains(r"'${client.playerApiUrl}$endpoint"), isFalse,
        reason: 'Catalog traffic is being routed through the player host.');
  });
}

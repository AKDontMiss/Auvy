// Auvy C1 auth Worker — Cloudflare Worker (FREE tier, no credit card).
//
// Fixes the critical "know-the-email → read/delete anyone's backup" hole
// (the C1 design) WITHOUT a second Google picker and WITHOUT breaking
// existing backups, and now also decides WHO is allowed to use cloud backup at
// all, and protects the free quota from being burned by anyone who gets hold of
// the APK.
//
// How the auth works
// ------------------
//   1. The app sends its ALREADY-authenticated YouTube session (cookies) to this
//      Worker over HTTPS.
//   2. The Worker proves the caller really owns that account by making one
//      SAPISIDHASH-authenticated call to YouTube (account/account_menu) and
//      reading back the signed-in identity. An attacker who only knows a victim's
//      email cannot do this — they lack the cookies.
//   3. uid = sha256("auvy_cloud_backup_v1::" + identity) — the SAME key the app
//      already uses (_backupKeyFor), so EXISTING backups keep working with zero
//      migration.
//   4. The Worker mints a Firebase CUSTOM TOKEN with that uid and derives a
//      per-user ENCRYPTION KEY encKey = HMAC-SHA256(SERVER_SECRET, uid). The app
//      encrypts its backup with encKey, so Firestore only ever stores ciphertext.
//
// ACCESS CONTROL (added 2026-08-04)
//
// WHY: the app is a sideloaded APK with the Worker URL compiled into it as a plain
// string (R8 does not obfuscate strings). Anyone who has the file can extract the
// endpoint. With no gate, a single script — or the app simply spreading further
// than intended — exhausts the Spark/Workers free quota, at which point cloud sync
// stops for EVERYONE, silently.
//
// So every account that signs in is RECORDED and needs approval:
//
//   pending   first time seen. Denied (403) until reviewed. Recorded so it can be
//             reviewed at all — this is the only way to know who is trying.
//   approved  allowed to mint tokens.
//   blocked   denied AND the Firebase user is disabled, which is what actually
//             kicks an existing session out (see the refresh-token note below).
//
// REFRESH TOKENS ARE WHY BLOCKING MUST TOUCH FIREBASE. Refusing to mint a new
// custom token only stops the NEXT sign-in. A client that already signed in holds
// a Firebase refresh token and would keep reading and writing its own backup
// indefinitely. Disabling the Firebase user makes that refresh fail, so access
// really ends (within the ~1h ID-token lifetime, or immediately on next refresh).
//
// OWNER (godmode)
// Identities in OWNER_IDENTITIES are auto-approved and EXEMPT from every rate
// limit, so tightening the screws can never lock the owner out of their own app.
//
// Secrets (`wrangler secret put <NAME>`):
//   FIREBASE_SA_EMAIL         service-account client_email
//   FIREBASE_SA_PRIVATE_KEY   service-account private_key (PEM, with \n newlines)
//   BACKUP_ENC_SERVER_SECRET  any long random string (the encKey pepper)
//   ADMIN_TOKEN               long random string — guards every /admin endpoint
//   OWNER_IDENTITIES          comma-separated emails/handles that get godmode
//   (OPEN_ENROLMENT is GONE — it auto-approved every new account, which is the
//    one thing this Worker exists to prevent. See the note at the record below.)
//                             (monitor-only mode — records everyone, blocks nobody)
//
// KV namespace binding (see wrangler.toml): USERS
//
// Admin API — all require header `X-Admin-Token: <ADMIN_TOKEN>`:
//   GET  /admin/users                      list every account seen, with status
//   POST /admin/approve     {"id": "..."}  approve (uid OR identity) + re-enable
//   POST /admin/disapprove  {"id": "..."}  back to pending + disable
//   POST /admin/block       {"id": "..."}  block + disable the Firebase user
//   POST /admin/unblock     {"id": "..."}  alias of /admin/approve
//   GET  /admin/stats                      today's global mint count vs the cap

const BACKUP_SALT = "auvy_cloud_backup_v1::"; // MUST match account_provider _backupSalt
const INNERTUBE_KEY = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"; // public WEB_REMIX innertube key
const ORIGIN = "https://www.youtube.com";

// Quota guards
// Sized against the FREE tiers this has to live inside: Workers ~100k req/day,
// Firestore ~50k reads + 20k writes/day, KV ~100k reads but only ~1k WRITES/day.
// That KV write ceiling is the binding constraint and dictates the design below:
// a record is written on SIGN-IN (rare per user), never per request.
const MAX_SIGNINS_PER_DAY = 40;    // per account. Generous: a sign-in happens on
                                   // app start / token refresh, not per action.
const MAX_MINTS_PER_DAY = 400;     // global. Well under the Firestore day budget
                                   // once each synced user's reads are counted.
const GLOBAL_WRITE_EVERY = 10;     // persist the global counter every Nth mint, to
                                   // stay inside the KV write budget. Coarse on
                                   // purpose. See allowGlobalMint().

// Enrolment ceiling
// A PENDING account is cheap: it never receives a token, so it never touches
// Firestore. But recording it costs one KV WRITE, and that budget (~1k/day) is the
// scarcest thing here, so an unbounded flood of strangers could still exhaust it
// even though none of them can read anything.
//
// These two make enrolment finite WITHOUT the owner having to reject anyone by
// hand: past the daily cap, or with enrolment closed, an unknown account is turned
// away and NOT recorded — costing zero writes.
const MAX_NEW_ACCOUNTS_PER_DAY = 25;
// Guard against out-approving the quota: /admin/approve refuses past this, since
// it is APPROVED users who actually consume Firestore reads and writes.
const MAX_APPROVED_ACCOUNTS = 25;
const MAX_VERIFY_PER_COOKIE_PER_DAY = 60; // pre-verify limiter, Cache API keyed by
                                   // the SAPISID hash. APPROXIMATE: the Cache API
                                   // is per-colocation, so a distributed caller
                                   // gets a higher effective ceiling. It exists to
                                   // blunt a hammering loop BEFORE the YouTube
                                   // sub-request, not as a hard security boundary —
                                   // the hard gate is approval + the global cap.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));

    // Admin surface first — it is the only GET.
    // The dashboard itself: inert HTML, no token needed to LOAD it. Every
    // action it fires still goes through the token-checked API below.
    if (url.pathname === "/admin" || url.pathname === "/admin/") {
      return cors(new Response(ADMIN_PAGE, {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          // CSP for the only HTML this Worker serves
          //
          // `default-src 'none'` is the real content here: the page is entirely
          // self-contained, so nothing should ever load from another origin. If a
          // future edit pastes in a CDN script, it fails loudly instead of
          // silently widening the surface.
          //
          //'unsafe-inline' IS REQUIRED, NOT AN OVERSIGHT. The dashboard's
          // markup, styles and its nine onclick= handlers are inline in
          // ADMIN_PAGE. Dropping it would break every button on the page. It does
          // weaken XSS protection, but the page renders no user-supplied
          // content, so there is no injection path to exploit, and forbidding all
          // external origins plus framing is the protection that actually applies
          // to this page. Move the handlers to addEventListener and this can
          // tighten to a nonce.
          "Content-Security-Policy": [
            "default-src 'none'",
            "script-src 'unsafe-inline'",
            "style-src 'unsafe-inline'",
            "img-src 'self' data:",
            "connect-src 'self'",   // its own /admin/* API calls
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors 'none'",
          ].join("; "),
        },
      }));
    }
    if (url.pathname.startsWith("/admin/")) return handleAdmin(request, env, url);

    // Update channel. See handleRelease.
    if (url.pathname.startsWith("/release/")) return handleRelease(request, env, url);

    // Playlist cover-art library. See handleCovers.
    if (url.pathname.startsWith("/covers")) return handleCovers(request, env, url);

    // Last.fm proxy — keeps the API key OFF THE CLIENT. See handleLastfm.
    if (url.pathname === "/lastfm") return handleLastfm(request, env, url);

    // Podcast feed → slim JSON, streamed and truncated. See handlePodcast.
    if (url.pathname === "/podcast") return handlePodcast(request, env, url);

    // Lyrics, cached at the edge so lrclib is asked once per track. See handleLyrics.
    if (url.pathname === "/lyrics") return handleLyrics(request, env, url);

    // Song recognition through a LICENSED provider. See handleRecognize.
    if (url.pathname === "/recognize") return handleRecognize(request, env, url);

    // Radio directory, cached — identical for every user. See handleRadio.
    if (url.pathname === "/radio") return handleRadio(request, env, url);

    // Public-domain audiobooks (LibriVox), cached. See handleAudiobooks.
    if (url.pathname === "/audiobooks") return handleAudiobooks(request, env, url);

    // ONE episode's show notes, without the phone downloading the whole feed.
    if (url.pathname === "/podcast/notes") return handlePodcastNotes(request, env, url);

    // THERE IS NO /itunes ROUTE, AND ADDING ONE MAKES THINGS WORSE.
    //
    // It was built and measured (2026-08-17): search, the genre charts and the
    // id→show lookup are byte-identical for every user, so they looked like ideal
    // edge-cache candidates. Tested against the deployed Worker they are not —
    // Apple throttles by SOURCE IP, and every user behind one Cloudflare egress IP
    // reads as a single hammering client:
    //
    //   /search  → 429 after ~5 requests (0/5 succeeded)
    //   /lookup  → 403 on 2 of 5
    //   /rss/toppodcasts → 403 on 4 of 5
    //
    // The same calls from a phone always succeed, because per-device traffic is
    // spread over thousands of residential IPs. Concentrating it is the whole
    // problem, so caching cannot fix it — a cache MISS is exactly when the request
    // is throttled. Left DIRECT in the client on purpose.
    //
    // Apple's replacement chart API (rss.applemarketingtools.com/api/v2) is not a
    // way round it either: it ignores `genre`, returning the same overall top list
    // for every id, so it cannot serve the 110 genre charts the app browses.

    if (request.method !== "POST") return cors(json({ error: "POST only" }, 405));
    if (!env.USERS) return cors(json({ error: "server misconfigured: no USERS KV" }, 500));

    let body;
    try { body = await request.json(); } catch { return cors(json({ error: "bad json" }, 400)); }

    const cookie = (body.cookie || "").trim();
    // DISPLAY HINT (never an identity)
    //
    // Accounts with no YouTube channel resolve to a numeric datasyncId, so the
    // review queue filled with rows like ds:1130... that the owner cannot match
    // to a person, and pre-approving their email creates a DIFFERENT uid that
    // the real sign-in never matches.
    //
    // CLIENT-SUPPLIED, THEREFORE UNTRUSTED. It is stored for DISPLAY only and
    // never touches the uid. Deriving identity from a value the caller sends is
    // precisely the hole this whole Worker exists to close: anyone could then
    // claim any email and read that person's backup.
    const hint = typeof body.hint === "string" &&
            body.hint.includes("@") &&
            body.hint.length <= 120
        ? body.hint.trim().toLowerCase()
        : null;
    if (!cookie) return cors(json({ error: "missing cookie" }, 400));

    // 0. Cheap limiter BEFORE the YouTube verification, so a loop cannot make us
    //    issue an unbounded number of sub-requests. Keyed by the SAPISID hash
    //    because that is all we know about the caller at this point.
    const sapisid = getSapisid(cookie);
    if (!sapisid) return cors(json({ error: "no SAPISID in cookie" }, 400));
    const cookieKey = await sha256Hex(sapisid);
    if (!(await allowVerify(cookieKey))) {
      // The owner is exempt from this one too.
      //
      // The per-account and global caps below already skip the owner, but this
      // limiter runs BEFORE identity is resolved — that is the whole point of it,
      // to blunt a hammering loop before the YouTube sub-request, so it had no
      // way to know who was calling and could lock the owner out of their own
      // service after 60 checks in a day. During heavy testing that is reachable.
      //
      // The identity ANCHOR closes the gap without giving up the protection:
      // `a:<sapisidHash>` → identity is written server-side on first sign-in, so
      // it can be consulted here. Read ONLY on the blocked path, so the normal
      // case still costs no KV operation.
      //
      // Not forgeable: the anchor is keyed by a hash of the CALLER'S OWN SAPISID
      // and holds whatever identity this Worker resolved from those cookies. A
      // stranger cannot make their own anchor claim the owner's address.
      let ownerBypass = false;
      try {
        const anchored = await env.USERS.get(aliasKey(cookieKey), { type: "text" });
        if (anchored && ownerSet(env).has(anchored.trim().toLowerCase())) {
          ownerBypass = true;
        }
      } catch { /* unreadable anchor → no bypass, fail closed */ }
      if (!ownerBypass) {
        return cors(json({ error: "too many attempts — try again tomorrow" }, 429));
      }
    }

    // 1. Verify the caller owns the account → resolve its identity with the same
    //    precedence the app uses (email || handle || name).
    let identity;
    try {
      identity = (await resolveIdentity(cookie)).identity;
    } catch (e) {
      return cors(json({ error: "verify failed: " + (e && e.message) }, 401));
    }
    if (!identity) return cors(json({ error: "could not resolve account identity" }, 401));

    // Identity anchor
    //
    // The uid is a hash of the identity, and the identity is whatever YouTube
    // answers today: `email || handle || name`. That is NOT stable. The owner's
    // account currently resolves to the HANDLE `@AKontheRUN` because account_menu
    // returns no email for it — the day it starts returning one, the identity
    // changes, the uid changes, and their entire cloud backup is orphaned with no
    // error anywhere. Same hazard for the channel-less accounts that fall through
    // to the hashed-SAPISID identity.
    //
    // So the FIRST identity seen for a given account is pinned and reused forever,
    // keyed by the SAPISID hash (already computed above for rate limiting, so this
    // costs one KV read and — once per account, ever — one write).
    //
    // If the SAPISID itself changes (a Google password change), the anchor is lost
    // and the account re-anchors on whatever it resolves to then. That is the one
    // case this cannot cover, and it is strictly better than drifting on every
    // YouTube response-shape change.
    let anchored = null;
    try {
      anchored = await env.USERS.get(aliasKey(cookieKey), { type: "text" });
    } catch (_) {}
    if (anchored && anchored !== identity) {
      console.log(`identity drift ignored — anchored to the original identity`);
      identity = anchored;
    } else if (!anchored) {
      try {
        await env.USERS.put(aliasKey(cookieKey), identity);
      } catch (_) {}
    }

    // 2. uid = the SAME key the app already uses, so existing backups match.
    const uid = await sha256Hex(BACKUP_SALT + identity.toLowerCase());
    const isOwner = ownerSet(env).has(identity.trim().toLowerCase());

    // 3. Approval gate.
    const now = Date.now();
    let rec = await getRec(env, uid);
    if (!rec) {
      // Enrolment gate
      // Refuse an unknown account WITHOUT writing a record when enrolment is
      // closed or today's intake is used up. Not recording is the point: the
      // record is the cost, so a flood must not be allowed to create records.
      // The owner is never gated.
      if (!isOwner) {
        const gate = await enrolmentAllows(env);
        if (!gate.ok) {
          // Counted, not recorded. See bumpRefused. Without this the refusal is
          // invisible to the owner, who then has no way to know the gate is what
          // is keeping someone out.
          await bumpRefused(env, gate.cause);
          return cors(json({
            error: gate.reason,
            status: "closed",
            identity,
          }, 403));
        }
      }
      rec = {
        uid,
        identity,
        // ALWAYS "pending" FOR ANYONE BUT AN OWNER. THIS IS THE ACCESS CONTROL.
        //
        // An OPEN_ENROLMENT="1" secret used to auto-approve every new account,
        // documented as "monitor-only mode" for a first rollout. The failure mode
        // is silent and total: the secret lives only on the deployed Worker, so
        // nothing in this repo shows it is on, and a brand-new account is let
        // straight in with no review. Observed exactly that way — an account that
        // had never touched the app signed in and was approved.
        //
        // A switch that disables the app's only access control, is invisible in
        // source, and defaults to unsafe when set once and forgotten is not worth
        // keeping for the convenience it bought. Approval is now unconditional:
        // review happens in /admin, which is where it was always meant to be.
        //
        // Deleting the secret alone would not be enough — it would leave the branch
        // ready to reopen the hole the next time someone set it.
        status: isOwner ? "approved" : "pending",
        firstSeenMs: now,
        lastSeenMs: now,
        signIns: 0,
        dayKey: dayKey(),
        dayCount: 0,
        // Flagged in the roster, not hidden in a comment: this account had no
        // email, no @handle and no datasyncId, so its id is derived from the
        // SAPISID cookie, which Google rotates on a password change. If that
        // happens the account re-anchors and its old backup is orphaned. There is
        // no server-side cure (nothing stabler exists to key on), so the honest
        // move is to make it VISIBLE in /admin/users rather than let it surprise
        // someone later.
        fragileId: identity.startsWith("sap:"),
        // Display only. See the hint note above.
        hintedEmail: hint,
      };
      // The ONE write for a brand-new account: without recording it there is
      // nothing to review, and the owner could never learn someone tried.
      await putRec(env, rec);
      await bumpNewAccounts(env);
    }
    if (isOwner && rec.status !== "approved") {
      rec.status = "approved";
      await putRec(env, rec);
    }

    // `identity` is echoed on every answer, including the refusals.
    //
    // The app cannot always work out who is signed in on its own: resolving the
    // account locally needs auth cookies that account_menu sometimes won't yield,
    // and when that fails the app falls back to "Guest" — with no identity, it
    // never even calls this Worker, so an unapproved user silently got a fully
    // working app and no gate at all. This Worker has ALREADY resolved the
    // identity from the caller's own cookies by this point, verified, so handing
    // it back makes the app's sign-in state depend on the same source of truth
    // that decides approval.
    if (rec.status === "blocked") {
      return cors(json({
        error: "account blocked",
        status: "blocked",
        identity,
      }, 403));
    }
    if (rec.status !== "approved") {
      return cors(json({
        error: "awaiting approval",
        status: "pending",
        identity,
      }, 403));
    }

    // 4. Per-account daily cap. Costs no extra KV write: the record is written
    //    below anyway to update lastSeen.
    if (!isOwner) {
      if (rec.dayKey !== dayKey()) { rec.dayKey = dayKey(); rec.dayCount = 0; }
      if (rec.dayCount >= MAX_SIGNINS_PER_DAY) {
        return cors(json({ error: "daily sign-in limit reached", status: "throttled", identity }, 429));
      }
      if (!(await allowGlobalMint(env))) {
        return cors(json({ error: "service busy — daily capacity reached", status: "capacity", identity }, 429));
      }
    }

    // 5. Mint the Firebase custom token + derive the per-user encryption key.
    let firebaseToken, encKey;
    try {
      firebaseToken = await mintCustomToken(uid, env);
      encKey = await hmacBase64(env.BACKUP_ENC_SERVER_SECRET, uid);
    } catch (e) {
      return cors(json({ error: "mint failed: " + (e && e.message) }, 500));
    }

    rec.lastSeenMs = now;
    rec.signIns = (rec.signIns || 0) + 1;
    rec.dayCount = (rec.dayCount || 0) + 1;
    // `identity` is the ANCHORED value by this point, so this no longer "keeps the
    // identity fresh" — it deliberately re-pins it. Letting a changed handle
    // overwrite it would change the uid and orphan the backup, which is the whole
    // reason the anchor exists.
    rec.identity = identity;
    rec.fragileId = identity.startsWith("sap:"); // backfills records made before this
    if (hint != null) rec.hintedEmail = hint;
    await putRec(env, rec);

    return cors(json({ uid, firebaseToken, encKey, identity, status: "approved" }));
  },
};

// The admin dashboard, served by the Worker itself at GET /admin.
//
// WHY SELF-HOSTED: this page holds the ADMIN_TOKEN in the browser's
// localStorage. Hosting it anywhere else would mean handing a key that can
// approve, block and disable accounts to a third party's domain. Served from
// the Worker, the page and the API it talks to are the same origin, and the
// token never leaves the owner's own machine and their own infrastructure.
//
// The page itself is PUBLIC and that is fine — it is inert HTML. Every action
// it performs goes through the same X-Admin-Token check as curl does, so
// without the token it can do precisely nothing.
// The admin dashboard, served by the Worker itself at GET /admin.
//
// WHY SELF-HOSTED: this page carries the credential that can approve, block
// and disable accounts. Hosting it on a third party domain would hand that
// key to them. Same-origin on the owner's own Worker, it never leaves their
// browser and their own infrastructure.
//
// The page itself is PUBLIC and inert. Sign-in posts to /admin/login (rate
// limited, 10 failures per hour per IP), which returns the real ADMIN_TOKEN;
// every action after that carries it in X-Admin-Token exactly as curl would.
// Loading the page grants nothing.
const ADMIN_PAGE = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="color-scheme" content="dark">
<title>Auvy — access</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%23E5484D'/%3E%3Cpath d='M9.5 22.5 16 9l6.5 13.5' stroke='white' stroke-width='2.6' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E">
<style>
  /* ── ONE STYLESHEET, NO EXTERNAL ANYTHING ─────────────────────────────────
     The CSP on this route is default-src 'none', so there is no web font, no
     icon font and no CDN available here — by design. Everything below is system
     fonts, CSS gradients and inline SVG, which is also why the page has no
     loading state: it is one document that paints immediately. */
  :root{
    color-scheme:dark;
    --bg:#0A0A0D; --glow:#1A1024;
    --card:#131319; --card-2:#17171E; --sunken:#0C0C10;
    --line:#23232C; --line-2:#2C2C37;
    --text:#F4F4F7; --dim:#8E8E9C; --faint:#5F5F6D;
    --ok:#3ECF8E; --warn:#F0B429; --bad:#F0555B; --info:#8FA2FF;
    --accent:#E5484D; --accent-2:#FF6B54;
    --r:16px; --r-sm:11px; --r-xs:9px;
    /* A hairline highlight along the top edge plus a soft drop shadow is what
       separates "a box with a border" from a surface with a sense of depth. */
    --lift:inset 0 1px 0 rgba(255,255,255,.045), 0 1px 2px rgba(0,0,0,.5),
           0 12px 28px -12px rgba(0,0,0,.65);
  }
  *{box-sizing:border-box}
  html{-webkit-text-size-adjust:100%}
  body{
    margin:0;background:var(--bg);color:var(--text);
    font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI Variable Text",
         "Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
    font-feature-settings:"cv11","ss01";
    -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
    padding:0 16px 88px;
    /* Two stacked radial washes, fixed so they read as light in the room rather
       than as a gradient that scrolls with the content. */
    background-image:
      radial-gradient(900px 480px at 12% -8%, rgba(229,72,77,.13), transparent 62%),
      radial-gradient(760px 420px at 92% -2%, rgba(120,140,255,.10), transparent 58%);
    background-attachment:fixed;background-repeat:no-repeat;
  }
  .shell{max-width:880px;margin-inline:auto}

  /* ── Header ─────────────────────────────────────────────────────────────── */
  .head{display:flex;align-items:center;gap:13px;padding:30px 2px 22px}
  .mark{
    width:40px;height:40px;border-radius:12px;flex:none;
    display:grid;place-items:center;
    background:linear-gradient(150deg,var(--accent-2),var(--accent) 62%,#B4353A);
    box-shadow:0 2px 10px rgba(229,72,77,.34),inset 0 1px 0 rgba(255,255,255,.28);
  }
  .mark svg{display:block}
  .titles{min-width:0;flex:1}
  h1{font-size:19px;margin:0;font-weight:700;letter-spacing:-.015em;line-height:1.2}
  .sub{color:var(--dim);font-size:13px;line-height:1.5}
  .head .sub{margin-top:1px}

  /* ── Surfaces ───────────────────────────────────────────────────────────── */
  .card{
    background:linear-gradient(180deg,var(--card-2),var(--card));
    border:1px solid var(--line);border-radius:var(--r);
    padding:17px 18px;margin-bottom:13px;box-shadow:var(--lift);
  }
  .card-title{font-size:14.5px;font-weight:650;letter-spacing:-.005em}
  .sec{display:flex;align-items:center;gap:8px;margin-bottom:13px}
  .sec .card-title{flex:1;min-width:0}

  /* ── Form controls ──────────────────────────────────────────────────────── */
  label{display:block;font-size:11.5px;color:var(--dim);margin:0 0 6px;
        font-weight:650;letter-spacing:.02em}
  input{
    width:100%;background:var(--sunken);border:1px solid var(--line);
    color:var(--text);border-radius:var(--r-sm);padding:12px 13px;
    font-size:15px;font-family:inherit;
    transition:border-color .16s ease, box-shadow .16s ease, background .16s ease;
  }
  input::placeholder{color:var(--faint)}
  input:hover{border-color:var(--line-2)}
  input:focus{outline:0;border-color:rgba(229,72,77,.62);background:#0E0E13;
              box-shadow:0 0 0 3.5px rgba(229,72,77,.16)}
  button{
    font:inherit;font-weight:650;border:1px solid var(--line-2);
    border-radius:var(--r-sm);padding:10px 14px;cursor:pointer;
    background:linear-gradient(180deg,#22222B,#1B1B23);color:var(--text);
    box-shadow:inset 0 1px 0 rgba(255,255,255,.05);
    transition:transform .1s ease, filter .16s ease, border-color .16s ease;
    -webkit-tap-highlight-color:transparent;
  }
  button:hover{filter:brightness(1.16);border-color:#3A3A46}
  button:active{transform:translateY(1px) scale(.985)}
  button:focus-visible,input:focus-visible,.who:focus-visible{
    outline:2px solid var(--accent);outline-offset:2px}
  button.primary{
    width:100%;padding:13px;color:#fff;border-color:transparent;
    background:linear-gradient(180deg,var(--accent-2),var(--accent) 58%,#C93C41);
    box-shadow:0 2px 12px rgba(229,72,77,.30),inset 0 1px 0 rgba(255,255,255,.26);
    letter-spacing:.005em;
  }
  .ghost{background:transparent;border-color:var(--line);color:var(--dim)}
  .ghost:hover{color:var(--text)}

  /* ── Sign-in ────────────────────────────────────────────────────────────── */
  #auth{max-width:392px;margin-inline:auto;padding:22px}
  .lock{display:flex;align-items:center;gap:7px;color:var(--dim);font-size:12px;
        justify-content:center;margin-bottom:16px}
  .gap{height:11px}

  /* ── Stat tiles ─────────────────────────────────────────────────────────── */
  .stats{display:grid;gap:9px;margin-bottom:13px;
         grid-template-columns:repeat(auto-fit,minmax(124px,1fr))}
  .stat{
    position:relative;overflow:hidden;
    background:linear-gradient(180deg,var(--card-2),var(--card));
    border:1px solid var(--line);border-radius:13px;padding:12px 13px 11px;
    box-shadow:var(--lift);
  }
  /* The accent rail, not a coloured number: it flags the tile without costing
     the figure its legibility. Present but transparent on a calm tile, so the
     text never shifts when a tile starts alerting. */
  .stat::before{content:"";position:absolute;inset:0 auto 0 0;width:2.5px;
                background:transparent}
  .stat.alert::before{background:linear-gradient(180deg,var(--warn),#C98A12)}
  .stat.alert b{color:#FFD980}
  .stat b{display:block;font-size:22px;font-weight:700;line-height:1.2;
          letter-spacing:-.02em;font-variant-numeric:tabular-nums}
  .stat span{display:block;margin-top:3px;color:var(--dim);font-size:10px;
             font-weight:650;text-transform:uppercase;letter-spacing:.085em}

  /* ── Account rows ───────────────────────────────────────────────────────── */
  .row{padding:13px 10px;margin:0 -10px;border-radius:12px;
       border-bottom:1px solid var(--line);transition:background .14s ease}
  .row:hover{background:rgba(255,255,255,.022)}
  .row:last-child{border-bottom:0}
  .top{display:flex;align-items:center;gap:10px}
  .who{flex:1;min-width:0;cursor:pointer;border-radius:8px}
  .who b{display:block;font-weight:600;font-size:14.5px;overflow:hidden;
         text-overflow:ellipsis;white-space:nowrap}
  .who small{color:var(--dim);font-size:12px;
             font-variant-numeric:tabular-nums}
  .chip{
    font-size:9.5px;font-weight:750;letter-spacing:.075em;text-transform:uppercase;
    padding:4px 8px;border-radius:99px;white-space:nowrap;
  }
  /* A tinted fill plus a 1px ring of the same hue: reads as a deliberate token
     rather than a coloured rectangle, and stays legible on the hover fill. */
  .approved{background:rgba(62,207,142,.13);color:var(--ok);
            box-shadow:inset 0 0 0 1px rgba(62,207,142,.30)}
  .pending{background:rgba(240,180,41,.13);color:var(--warn);
           box-shadow:inset 0 0 0 1px rgba(240,180,41,.30)}
  .blocked{background:rgba(240,85,91,.13);color:var(--bad);
           box-shadow:inset 0 0 0 1px rgba(240,85,91,.30)}
  .owner{background:rgba(143,162,255,.14);color:var(--info);
         box-shadow:inset 0 0 0 1px rgba(143,162,255,.30)}
  .acts{display:flex;gap:6px}
  .acts button{width:36px;height:36px;padding:0;display:grid;place-items:center;
               border-color:transparent}
  .acts svg{display:block}
  .yes{background:rgba(62,207,142,.13);color:var(--ok);
       box-shadow:inset 0 0 0 1px rgba(62,207,142,.24)}
  .no{background:rgba(240,180,41,.13);color:var(--warn);
      box-shadow:inset 0 0 0 1px rgba(240,180,41,.24)}
  .ban{background:rgba(240,85,91,.13);color:var(--bad);
       box-shadow:inset 0 0 0 1px rgba(240,85,91,.24)}
  .gone{background:rgba(255,255,255,.045);color:var(--faint);
        box-shadow:inset 0 0 0 1px rgba(255,255,255,.07)}
  .gone:hover{color:var(--dim)}
  .flag{color:var(--warn);font-size:11px;margin-top:4px;
        display:flex;align-items:center;gap:5px}
  .detail{
    display:none;margin-top:11px;padding:12px 13px;background:var(--sunken);
    border:1px solid var(--line);border-radius:var(--r-xs);
    font-size:12.5px;color:var(--dim);
  }
  .detail.open{display:block}
  .detail div{margin-bottom:4px}
  .detail div:last-child{margin-bottom:0}
  .detail code{
    color:#C3C3D0;word-break:break-all;font-size:11px;
    font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
    background:rgba(255,255,255,.04);padding:1.5px 5px;border-radius:5px;
  }
  .detail em{color:var(--faint);font-style:normal}

  /* ── Banner ─────────────────────────────────────────────────────────────── */
  .msg{padding:12px 14px;border-radius:var(--r-sm);margin-bottom:13px;
       font-size:13.5px;display:none;border:1px solid transparent}
  .msg.show{display:block}
  .msg.err{background:rgba(240,85,91,.11);color:#FFA8AB;
           border-color:rgba(240,85,91,.26)}
  .msg.good{background:rgba(62,207,142,.11);color:#8FE9BD;
            border-color:rgba(62,207,142,.26)}

  .bar{display:flex;justify-content:space-between;align-items:center;gap:12px}

  /* ── Segmented filter ───────────────────────────────────────────────────── */
  .tabs{display:flex;gap:3px;margin-bottom:11px;padding:3px;flex-wrap:wrap;
        background:var(--sunken);border:1px solid var(--line);border-radius:12px}
  .tabs button{
    flex:1 1 auto;padding:7px 12px;font-size:12.5px;font-weight:650;
    background:transparent;border-color:transparent;color:var(--dim);
    box-shadow:none;border-radius:9px;
  }
  .tabs button:hover{color:var(--text);filter:none;background:rgba(255,255,255,.04)}
  .tabs button.on{
    color:#fff;background:linear-gradient(180deg,#2E2E3A,#24242E);
    border-color:var(--line-2);box-shadow:0 1px 3px rgba(0,0,0,.45);
  }

  /* ── Search ─────────────────────────────────────────────────────────────── */
  .field{position:relative;margin-bottom:11px}
  .field svg{position:absolute;left:12px;top:50%;transform:translateY(-50%);
             color:var(--faint);pointer-events:none}
  .field input{padding-left:36px}
  .tools{display:flex;gap:9px;flex-wrap:wrap}
  .tools input{flex:1 1 170px}

  .foot{color:var(--faint);font-size:11.5px;text-align:center;margin-top:22px;
        font-variant-numeric:tabular-nums}
  .empty{color:var(--dim);font-size:13.5px;padding:22px 0;text-align:center}

  #app{animation:rise .26s ease both}
  @keyframes rise{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:none}}
  @media (prefers-reduced-motion:reduce){
    *{animation:none!important;transition:none!important}
  }
  @media (max-width:520px){
    body{padding:0 13px 72px}
    .head{padding:22px 2px 18px}
    .stats{grid-template-columns:repeat(auto-fit,minmax(104px,1fr))}
  }
</style></head><body>
<div class="shell">

<div class="head">
  <span class="mark" aria-hidden="true"><svg width="21" height="21" viewBox="0 0 24 24"
    fill="none" stroke="#fff" stroke-width="2.5" stroke-linecap="round"
    stroke-linejoin="round"><path d="M6 19 12 5l6 14"/></svg></span>
  <div class="titles">
    <h1>Auvy access</h1>
    <div class="sub">Who may use the app, and who may not.</div>
  </div>
</div>

<div id="msg" class="msg"></div>

<div class="card" id="auth">
  <div class="lock"><svg width="13" height="13" viewBox="0 0 24 24" fill="none"
    stroke="currentColor" stroke-width="2" stroke-linecap="round"
    stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2"/>
    <path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg> Restricted &mdash; operator only</div>
  <label for="u">Username</label>
  <input id="u" autocomplete="username" autocapitalize="none" spellcheck="false">
  <div class="gap"></div>
  <label for="p">Password</label>
  <input id="p" type="password" autocomplete="current-password">
  <div class="gap"></div>
  <button class="primary" onclick="signIn()">Sign in</button>
  <div id="tokfall" style="display:none">
    <div class="gap"></div>
    <label for="tok">Admin token</label>
    <input id="tok" type="password" autocomplete="off" placeholder="ADMIN_TOKEN">
    <div class="gap"></div>
    <button class="ghost" style="width:100%" onclick="useToken()">Use token</button>
  </div>
  <div class="sub" style="margin-top:13px">Stays signed in on this device until you
    sign out.</div>
</div>

<div id="app" style="display:none">
  <div class="stats" id="stats"></div>

  <div class="card bar">
    <div style="min-width:0">
      <div class="card-title">Enrolment</div>
      <div class="sub" id="enrolSub">&hellip;</div>
    </div>
    <button id="enrol" onclick="toggleEnrol()" style="flex:none">&hellip;</button>
  </div>

  <div class="card">
    <label for="pre">Approve someone before they first sign in</label>
    <div class="tools">
      <input id="pre" placeholder="email or @handle" autocapitalize="none" spellcheck="false">
      <button class="yes" style="padding:11px 18px;flex:none" onclick="preApprove()">Approve</button>
    </div>
    <div class="sub" style="margin-top:11px">Only works if you type the identity
      exactly as Auvy will see it. If it turns out different, they land in the
      queue as usual &mdash; approve them from the list then.</div>
  </div>

  <div class="card">
    <div class="sec">
      <div class="card-title">Accounts</div>
      <button class="ghost" onclick="load()">Refresh</button>
      <button class="ghost" onclick="signOut()">Sign out</button>
    </div>
    <div class="tabs" id="tabs"></div>
    <div class="field">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
        stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/>
        <path d="m20 20-3.6-3.6"/></svg>
      <input id="q" placeholder="Search name, email or uid" oninput="render()"
        autocapitalize="none" spellcheck="false">
    </div>
    <div id="list"></div>
  </div>

  <div class="foot" id="foot"></div>
</div>

</div>
<script>
const KEY='auvy_admin_token';
let TOKEN=localStorage.getItem(KEY)||'';
let USERS=[], STATS={}, enrolOpen=true, filter='all';
const NAMES={}, OPEN={};

// Inline SVG rather than emoji or an icon font: the CSP forbids an external
// font, and the entities this used before (&#10003; &#128465;) render at a
// different weight and baseline in every shell.
const svg=(d,extra)=>'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" '+
  'stroke="currentColor" stroke-width="2.2" stroke-linecap="round" '+
  'stroke-linejoin="round" aria-hidden="true">'+d+(extra||'')+'</svg>';
const I={
  check:svg('<path d="M20 6 9 17l-5-5"/>'),
  undo:svg('<path d="M3 10h7V3"/><path d="M3.3 10.3a9 9 0 1 1 1.4 8.2"/>'),
  block:svg('<path d="M18 6 6 18"/><path d="M6 6l12 12"/>'),
  forget:svg('<path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M18.5 7l-1 13h-11L5.5 7"/>'),
  warn:'<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" '+
    'stroke-width="2.2" stroke-linecap="round" aria-hidden="true">'+
    '<path d="M12 3 2 20h20L12 3Z"/><path d="M12 9v5"/><path d="M12 17.5v.5"/></svg>',
};

function msg(t,cls){const m=document.getElementById('msg');
  m.textContent=t;m.className='msg show '+cls;
  window.scrollTo({top:0,behavior:'smooth'});
  if(cls==='good')setTimeout(()=>{m.className='msg'},2800);}

async function signIn(){
  const username=document.getElementById('u').value.trim();
  const password=document.getElementById('p').value;
  if(!username||!password)return msg('Username and password, please.','err');
  try{
    const r=await fetch('/admin/login',{method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({username,password})});
    const j=await r.json().catch(()=>({}));
    if(!r.ok)throw new Error(j.error||('HTTP '+r.status));
    TOKEN=j.token;localStorage.setItem(KEY,TOKEN);
    document.getElementById('p').value='';
    load();
  }catch(e){
    // No ADMIN_USER/ADMIN_PASSWORD set yet. Rather than leave the dashboard
    // unusable, fall back to the credential that always exists.
    if(String(e.message).includes('not configured')){
      document.getElementById('tokfall').style.display='';
      msg('Password sign-in is not set up yet — use your admin token below, or set ADMIN_USER and ADMIN_PASSWORD.','err');
    } else msg(e.message,'err');
  }
}
function useToken(){
  const v=document.getElementById('tok').value.trim();
  if(!v)return msg('Paste the token first.','err');
  TOKEN=v;localStorage.setItem(KEY,v);load();
}
function signOut(){localStorage.removeItem(KEY);TOKEN='';
  document.getElementById('app').style.display='none';
  document.getElementById('auth').style.display='';
  msg('Signed out on this device.','good');}

async function api(path,body){
  const r=await fetch(path,{method:body?'POST':'GET',
    headers:Object.assign({'X-Admin-Token':TOKEN},body?{'Content-Type':'application/json'}:{}),
    body:body?JSON.stringify(body):undefined});
  const j=await r.json().catch(()=>({}));
  if(!r.ok)throw new Error(j.error||('HTTP '+r.status));
  return j;
}

function when(ms){if(!ms)return 'never';
  const d=Math.floor((Date.now()-ms)/60000);
  if(d<1)return 'just now'; if(d<60)return d+'m ago';
  if(d<1440)return Math.floor(d/60)+'h ago'; return Math.floor(d/1440)+'d ago';}
function stamp(ms){if(!ms)return '—';const d=new Date(ms);
  return d.toLocaleDateString()+' '+d.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});}

async function load(){
  try{
    const [s,u]=await Promise.all([api('/admin/stats'),api('/admin/users')]);
    STATS=s;USERS=u.users;USERS.forEach(r=>NAMES[r.uid]=r.identity);
    enrolOpen=s.enrolmentOpen;
    document.getElementById('auth').style.display='none';
    document.getElementById('app').style.display='';
    document.getElementById('enrol').textContent=enrolOpen?'Close enrolment':'Open enrolment';
    document.getElementById('enrolSub').textContent=enrolOpen
      ?'Open: an unknown account is recorded and waits here for your approval.'
      :'Closed: an unknown account is turned away and never recorded, so it cannot reach this list to be approved. Refusals are counted under "turned away".';
    document.getElementById('stats').innerHTML=
      stat(s.enrolmentOpen?'Open':'Closed','enrolment',!s.enrolmentOpen)+
      stat(s.approved+' / '+s.approvedCap,'approved',false)+
      stat(s.pending,'waiting',s.pending>0)+
      stat(s.blocked,'blocked',false)+
      stat(s.approvedHeadroom,'headroom',s.approvedHeadroom===0)+
      stat(s.mints+' / '+s.mintCap,'sign-ins today',false)+
      stat(s.newAccountsToday+' / '+s.newAccountCap,'new today',false)+
      stat(s.refusedToday||0,'turned away'+((s.refusedFull||0)>0?' (intake full)':((s.refusedClosed||0)>0?' (enrolment closed)':'')),(s.refusedToday||0)>0);
    document.getElementById('foot').textContent=
      'Day '+s.day+' · '+USERS.length+' accounts on record';
    render();
  }catch(e){
    document.getElementById('app').style.display='none';
    document.getElementById('auth').style.display='';
    if(String(e.message).includes('unauthorized')){localStorage.removeItem(KEY);TOKEN='';
      msg('Session no longer valid — sign in again.','err');}
    else msg(e.message,'err');
  }
}
const stat=(v,l,alert)=>'<div class="stat'+(alert?' alert':'')+'"><b>'+v+'</b><span>'+l+'</span></div>';

function render(){
  const q=(document.getElementById('q').value||'').toLowerCase();
  const counts={all:USERS.length,pending:0,approved:0,blocked:0};
  USERS.forEach(r=>{if(counts[r.status]!==undefined)counts[r.status]++;});
  document.getElementById('tabs').innerHTML=['all','pending','approved','blocked']
    .map(k=>'<button class="'+(filter===k?'on':'')+'" onclick="setFilter(\\''+k+'\\')">'+
      k[0].toUpperCase()+k.slice(1)+' '+counts[k]+'</button>').join('');
  let rows=USERS.filter(r=>filter==='all'||r.status===filter);
  if(q)rows=rows.filter(r=>(r.identity||'').toLowerCase().includes(q)||
    (r.hintedEmail||'').toLowerCase().includes(q)||r.uid.includes(q));
  // Waiting first: the queue is the thing that needs a decision.
  rows.sort((a,b)=>(a.status==='pending'?0:1)-(b.status==='pending'?0:1)
    ||(b.lastSeenMs||0)-(a.lastSeenMs||0));
  document.getElementById('list').innerHTML = rows.length ? rows.map(rowFor).join('')
    : '<div class="empty">Nothing here.</div>';
}
function setFilter(k){filter=k;render();}

function rowFor(r){
  const u=r.uid;
  // A machine identity (ds:… / sap:…) is unreviewable on its own. Show the
  // account the DEVICE reported, clearly marked unverified — it is supplied by
  // the client and never used for the uid.
  const machine=/^(ds|sap):/.test(r.identity||'');
  const hint=(r.hintedEmail&&machine)
    ? '<small style="color:var(--info)">device says: '+esc(r.hintedEmail)+'</small>'
    : '';
  const flag=r.fragileId?'<div class="flag">'+I.warn+'<span>Fragile id — a Google '+
    'password change orphans this account\\'s backup</span></div>':'';
  const badge=r.isOwner?'<span class="chip owner">owner</span>':'';
  return '<div class="row">'+
    '<div class="top">'+
      '<div class="who" tabindex="0" onclick="toggle(\\''+u+'\\')"><b>'+esc(r.identity)+'</b>'+
        '<small>'+(r.signIns||0)+' sign-ins · seen '+when(r.lastSeenMs)+'</small>'+hint+flag+'</div>'+
      badge+'<span class="chip '+r.status+'">'+r.status+'</span>'+
      '<div class="acts">'+
        (r.status!=='approved'?b('yes',I.check,'approve',u,'Approve'):'')+
        (r.status==='approved'?b('no',I.undo,'disapprove',u,'Back to waiting'):'')+
        (r.status!=='blocked'?b('ban',I.block,'block',u,'Block and end their session'):'')+
        b('gone',I.forget,'forget',u,'Forget this record entirely')+
      '</div>'+
    '</div>'+
    '<div class="detail'+(OPEN[u]?' open':'')+'" id="d_'+u+'">'+
      '<div>First seen: '+stamp(r.firstSeenMs)+'</div>'+
      '<div>Last seen: '+stamp(r.lastSeenMs)+'</div>'+
      '<div>Sign-ins today: '+(r.dayCount||0)+' (day '+(r.dayKey||'—')+')</div>'+
      (r.hintedEmail?'<div>Device reported: '+esc(r.hintedEmail)+' <em>(unverified — approval still keys off the identity above)</em></div>':'')+
      '<div>uid: <code>'+r.uid+'</code></div>'+
    '</div></div>';
}
const b=(c,g,act,id,title)=>
  '<button class="'+c+'" title="'+title+'" aria-label="'+title+'" onclick="act(\\''+act+'\\',\\''+id+'\\')">'+g+'</button>';
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
function toggle(u){OPEN[u]=!OPEN[u];
  const el=document.getElementById('d_'+u);if(el)el.classList.toggle('open',!!OPEN[u]);}

async function act(what,id){
  const name=NAMES[id]||id;
  if(what==='block'&&!confirm('Block '+name+'?\\n\\nThey lose access and their current session ends.'))return;
  if(what==='forget'&&!confirm('Forget '+name+'?\\n\\nThe record is deleted. They become a stranger again and re-enter the queue if they ever sign in.'))return;
  try{
    const r=await api('/admin/'+what,{id});
    // The Firebase leg is what actually ends a live session. A recorded decision
    // whose Firebase call failed looks identical in the roster, so say so.
    if(r.firebase&&String(r.firebase).startsWith('failed'))
      msg('Recorded — but Firebase did not apply it ('+r.firebase+'), so their current session may still work.','err');
    else msg('Done.','good');
    load();
  }catch(e){msg(e.message,'err');}
}

async function preApprove(){
  const id=document.getElementById('pre').value.trim();
  if(!id)return msg('Type an email or @handle first.','err');
  try{await api('/admin/approve',{id});document.getElementById('pre').value='';
    msg('Approved '+id+'.','good');load();}
  catch(e){msg(e.message,'err');}
}

async function toggleEnrol(){
  try{await api('/admin/enrolment',{open:!enrolOpen});load();}
  catch(e){msg(e.message,'err');}
}

document.getElementById('p').addEventListener('keydown',e=>{if(e.key==='Enter')signIn();});
document.getElementById('pre').addEventListener('keydown',e=>{if(e.key==='Enter')preApprove();});
if(TOKEN)load();
</script>
</body></html>`;


// Playlist cover library
//
// A set of ready-made covers the app offers when you create a playlist, so the
// choice is not "the default" or "hunt through your camera roll".
//
// WHY SERVED, NOT BUNDLED: shipping them as Flutter assets puts every image
// inside the APK forever — paid for by every user on every install, including
// the ones they never pick. Served, the APK does not grow, the set can change
// without a release, and only the chosen image is ever downloaded.
//
// WHY THIS REPO: it is already private and the Worker already holds a token
// for it (GITHUB_TOKEN, Contents: Read). Google Drive was the other candidate
// and was rejected on inspection — its API needs a separate key, and the
// keyless folder listing is undocumented HTML that would break silently.
//
//   GET /covers            → [{ name, url }]  (cached 6h)
//   GET /covers/img/<name> → the image bytes  (cached hard, immutable)
const COVERS_DIR = "covers";
// Bump this when the covers folder changes and you want every edge to drop its
// cached listing the moment you deploy.
//
// A deploy does not clear caches.default — the cache outlives the code that
// wrote it, and /admin/purge-covers only reaches the one colo that serves the
// request. Folding a version into the KEY sidesteps both: new epoch, new key,
// every region misses at once and refetches. The key is internal, so the public
// URL the app requests never changes.
const COVERS_CACHE_EPOCH = 2;

// The internal cache key for the listing. Shared by the reader and the purge
// route so they can never drift onto different keys.
function coversListKey(url) {
  const u = new URL(url.toString());
  u.pathname = "/covers";
  u.search = `?e=${COVERS_CACHE_EPOCH}`;
  return new Request(u.toString(), { method: "GET" });
}

/**
 * ── LAST.FM PROXY ───────────────────────────────────────────────────────────
 *
 * Why this exists: the API key used to be compiled INTO the APK via
 * --dart-define. That is not storage, it is publication — the value sits in the
 * binary, so anyone with the file can pull it out with standard tooling, and
 * that includes anyone the owner shares a build with AND Google, since Play
 * Protect may upload a sideloaded APK for analysis. The key now lives only here,
 * as a Worker secret, and the client sends none.
 *
 * AN ALLOWLIST, NOT A PASS-THROUGH. Forwarding whatever `method` the caller
 * asks for would turn this into a general-purpose Last.fm proxy on the owner's
 * key — including any write or auth-scoped method Last.fm ever adds. Only the
 * read-only methods Auvy actually calls are accepted; anything else is refused
 * before a request is made.
 *
 * Deliberately NOT behind the cookie/approval gate that the auth endpoint uses.
 * Artist metadata is fetched on many paths (browse, onboarding, recommendations)
 * and gating it would put a session check on cosmetic data. The exposure is a
 * proxy for PUBLIC artist information — the thing worth protecting is the key,
 * and the key stays here.
 *
 * Cached at the edge on purpose: bios and similar-artist lists barely change, so
 * repeat lookups should never reach Last.fm. That is the opposite of the
 * auth/probe endpoints, where caching in front of the Worker was a bug.
 */
/**
 * The Last.fm methods the app is allowed to call through this Worker.
 *
 * KEEP IN STEP WITH artist_metadata_service.dart — TWO WERE MISSING AND THE
 * FEATURES THEY POWER WERE SILENTLY DEAD.
 *
 * Verified against the deployed Worker on 2026-08-27: `chart.getTopTracks` and
 * `track.getTopTags` both answered `{"error":"method not allowed"}`. The client
 * treats that like any empty response, so nothing errored anywhere — the global
 * chart row simply had no content, and `getTrackTags` returned nothing, which is
 * what IntelligenceProvider uses for GENRE DETECTION. So recommendations were
 * quietly running without genre signal.
 *
 * That is the cost of an allowlist nobody re-checks: it fails closed, which is
 * right, and silently, which is not. Cross-check with
 * `grep -rhoE "'method': '[a-zA-Z.]+'" lib/` before shipping a change here.
 *
 * `sk` is refused separately below, so every method listed is read-only and no
 * authenticated write is reachable.
 */
const LASTFM_ALLOWED_METHODS = new Set([
  "artist.getinfo",
  "artist.getsimilar",
  "artist.gettoptags",
  "artist.gettopalbums",
  "artist.gettoptracks",
  "chart.gettoptracks", // global chart row — was missing
  "track.getinfo",
  "track.getsimilar",
  "track.gettoptags", // genre detection for recommendations — was missing
  "album.getinfo",
]);

async function handleLastfm(request, env, url) {
  if (request.method !== "GET") {
    return cors(json({ error: "GET only" }, 405));
  }
  const key = env.LASTFM_API_KEY;
  if (!key) {
    // Same shape the client already treats as "no data", so a missing secret
    // degrades exactly like a keyless build did rather than erroring loudly.
    return cors(json({ error: "lastfm not configured" }, 503));
  }

  const method = (url.searchParams.get("method") || "").toLowerCase();
  if (!LASTFM_ALLOWED_METHODS.has(method)) {
    return cors(json({ error: "method not allowed" }, 400));
  }


  // Rebuild the query from scratch: forward only what the caller sent, then add
  // the key ourselves. Copying the caller's params wholesale would let them
  // override `api_key` or `format`.
  const out = new URLSearchParams();
  for (const [k, v] of url.searchParams) {
    if (k === "api_key" || k === "format" || k === "sk") continue;
    if (v.length > 256) continue; // nothing legitimate is this long
    out.set(k, v);
  }
  out.set("api_key", key);
  out.set("format", "json");

  const target = `https://ws.audioscrobbler.com/2.0/?${out.toString()}`;
  try {
    const resp = await fetch(target, {
      headers: { "User-Agent": "Auvy/1.0" },
      // Edge cache: identical lookups are served without touching Last.fm.
      cf: { cacheTtl: 86400, cacheEverything: true },
    });
    const text = await resp.text();
    return cors(new Response(text, {
      status: resp.status,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "public, max-age=86400",
      },
    }));
  } catch (e) {
    return cors(json({ error: "upstream failed" }, 502));
  }
}

/**
 * ── RADIO DIRECTORY (radio-browser) ──────────────────────────────────────────
 *
 * The country index and the station lists are IDENTICAL for every user — nobody
 * gets a personalised version of "stations in Germany, most-voted first". So
 * every device fetching them separately is the same bytes travelling many times,
 * and radio-browser is another volunteer-run service.
 *
 * THE MIRROR WALK MOVES HERE, WHICH IS WHERE IT BELONGS. The app carries a
 * list of four mirrors and tries each in turn with a 12-second timeout, because
 * they go down often. On a phone that means up to 48 seconds of a user staring
 * at a spinner on a bad day, and every device rediscovering the same outage
 * independently. Done at the edge, one Worker finds the healthy mirror and every
 * listener benefits from the answer.
 *
 * The paths are ALLOWLISTED by shape rather than forwarded, so this cannot be
 * pointed at arbitrary radio-browser endpoints — including the click/vote
 * endpoints, which mutate their data and should never be reachable through a
 * cache.
 */
const RADIO_MIRRORS = [
  "https://de1.api.radio-browser.info/json",
  "https://at1.api.radio-browser.info/json",
  "https://nl1.api.radio-browser.info/json",
  "https://fi1.api.radio-browser.info/json",
];

/// Read-only browse paths the app actually uses. Anything else is refused.
const RADIO_ALLOWED = [
  /^\/countries$/,
  /^\/stations\/bycountryexact\/[^/?]+(\?.*)?$/,
  /^\/stations\/topclick(\?.*)?$/,
  /^\/stations\/topvote(\?.*)?$/,
  /^\/stations\/search(\?.*)?$/,
  /^\/stations\/bytag\/[^/?]+(\?.*)?$/,
];

async function handleRadio(request, env, url) {
  if (request.method !== "GET") return cors(json({ error: "GET only" }, 405));

  const path = url.searchParams.get("path") || "";
  if (!path.startsWith("/") || path.length > 400) {
    return cors(json({ error: "bad path" }, 400));
  }
  if (!RADIO_ALLOWED.some((re) => re.test(path))) {
    return cors(json({ error: "path not allowed" }, 400));
  }

  const cache = caches.default;
  const cacheKey = new Request(`${url.origin}/radio?path=${encodeURIComponent(path)}`, { method: "GET" });
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  // Walk the mirrors here so the phone never has to.
  for (const base of RADIO_MIRRORS) {
    try {
      const res = await fetch(`${base}${path}`, {
        // radio-browser rate-limits callers that do not identify themselves.
        headers: { "User-Agent": "Auvy/1.0", Accept: "application/json" },
      });
      if (!res.ok) continue;
      const body = await res.text();
      const out = cors(new Response(body, {
        status: 200,
        headers: { "Content-Type": "application/json; charset=utf-8" },
      }));
      // Station directories shift slowly — a new station appearing within the
      // hour is not something anyone is waiting for.
      out.headers.set("Cache-Control", "public, max-age=3600");
      try { await cache.put(cacheKey, out.clone()); } catch {}
      return out;
    } catch {
      // Dead mirror — try the next.
    }
  }
  // Every mirror failed. Not cached: this is an outage, not an answer.
  return cors(json({ error: "all radio mirrors unreachable" }, 502));
}

/**
 * ── LYRICS (all four catalogues) ─────────────────────────────────────────────
 *
 * Every device asked each catalogue directly, so the same popular track was
 * fetched again for every listener. Behind the edge cache the second request
 * onward is served by Cloudflare and never reaches the upstream at all.
 *
 * The point is as much courtesy as speed: lrclib, NetEase, KuGou and lyrics.ovh
 * are all free, community-run or unofficial endpoints with no commercial
 * backing. An app that grows should not grow its load on someone else's donated
 * infrastructure, and it identifies itself honestly in the User-Agent so they can
 * see who is calling.
 *
 * THE WHOLE SCAN IS FRONTED, NOT JUST ONE SOURCE. The client scores five
 * candidates concurrently for every track (lrclib /get, lrclib /search, NetEase,
 * KuGou, lyrics.ovh) and KuGou/NetEase each need two round-trips. Caching only
 * lrclib left the majority of the traffic un-cached, and made a manual refetch —
 * which deliberately rotates to a DIFFERENT source — the slowest path in the app
 * rather than the fastest.
 *
 * AN ALLOWLIST, NOT A URL PARAMETER. `source=` selects one of a fixed set of
 * upstream shapes and every value that reaches the upstream is re-built here from
 * validated parts (ids must be digits, access keys hex). Taking a URL from the
 * caller would turn this Worker into an open proxy pointed at Cloudflare's
 * reputation — the one thing a public endpoint must never be.
 *
 * A MISS IS CACHED TOO, BUT BRIEFLY. "No lyrics for this track" is the common
 * answer for obscure music, and re-asking on every play is the wasteful case
 * worth fixing. It is cached for a DAY rather than a month, because lyrics get
 * contributed later and a month-long negative cache would hide them.
 */
const LYRICS_TTL_HIT = 2_592_000; // 30 days — lyrics for a track do not change
const LYRICS_TTL_MISS = 86_400;   // 1 day — a miss might become a hit

// Identifies Auvy to lyrics providers. lrclib and friends ask for a contact
// URL so they can reach whoever is generating the traffic, which means it has
// to be a page they can actually open: this pointed at the PRIVATE repo, so a
// maintainer following it got a 404. The public mirror is the right address.
const LYRICS_UA_SELF =
  "Auvy/1.0 (https://github.com/AKDontMiss/Auvy)";
const LYRICS_UA_BROWSER =
  "Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36";

/**
 * Resolve `source` + query params to ONE upstream request, or null if the source
 * is unknown or its required params are missing/malformed.
 *
 * Returns { url, headers, key } where `key` is the canonical cache key — built
 * from the NORMALISED params so two phones asking the same question land on the
 * same cached answer regardless of parameter order or padding.
 */
function lyricsUpstream(source, p) {
  const str = (k, max = 300) => (p.get(k) || "").trim().slice(0, max);
  const digits = (k) => (/^\d{1,20}$/.test(p.get(k) || "") ? p.get(k) : null);
  const hex = (k) => (/^[A-Za-z0-9]{1,64}$/.test(p.get(k) || "") ? p.get(k) : null);
  const self = { "User-Agent": LYRICS_UA_SELF, Accept: "application/json" };
  const browser = { "User-Agent": LYRICS_UA_BROWSER, Accept: "application/json" };

  switch (source) {
    case "lrclib": {
      const track = str("track_name");
      if (!track) return null;
      const q = new URLSearchParams({ track_name: track });
      for (const k of ["artist_name", "album_name", "duration"]) {
        const v = str(k, 100);
        if (v) q.set(k, v);
      }
      return { url: `https://lrclib.net/api/get?${q}`, headers: self, key: `lrclib?${q}` };
    }
    case "lrclib-search": {
      const q = str("q");
      if (!q) return null;
      const qs = new URLSearchParams({ q });
      return {
        url: `https://lrclib.net/api/search?${qs}`,
        headers: self,
        key: `lrclib-search?${qs}`,
        // Measured at 201 KB per track, of which the client reads about a
        // FIFTH. lrclib's /search returns every match WITH ITS FULL LYRICS — ~20
        // candidates at ~10 KB each, and it is queried for EVERY track played.
        // The client scores only `results.take(8)` (and `take(10)` on the relaxed
        // refetch pass), so everything past the tenth entry is downloaded to the
        // phone and then ignored. Trimming here is lossless for the client and
        // cuts the largest single item in the lyrics path by roughly half.
        trimList: 10,
      };
    }
    case "netease-search": {
      const s = str("s");
      if (!s) return null;
      const qs = new URLSearchParams({ s, type: "1", offset: "0", limit: "5" });
      // NOT `/api/search/get/web` — THAT ENDPOINT ANSWERS WITH CIPHERTEXT.
      // Called from outside China it returns `{"abroad":true,"result":"<hex>"}`,
      // an AES blob instead of the song list. The client read `result.songs` off
      // that string, got nothing, and swallowed it, so NetEase silently
      // contributed zero candidates to every lyrics scan. The plain
      // `/api/search/get` (no `/web`) returns real JSON regardless of region.
      return {
        url: `https://music.163.com/api/search/get?${qs}`,
        // NetEase rejects calls without a matching Referer.
        headers: { ...browser, Referer: "https://music.163.com" },
        key: `netease-search?${qs}`,
      };
    }
    case "netease-lyric": {
      const id = digits("id");
      if (!id) return null;
      return {
        url: `https://music.163.com/api/song/lyric?id=${id}&lv=1&kv=1&tv=-1`,
        headers: { ...browser, Referer: "https://music.163.com" },
        key: `netease-lyric?id=${id}`,
      };
    }
    case "kugou-search": {
      const keyword = str("keyword");
      if (!keyword) return null;
      const qs = new URLSearchParams({ ver: "1", man: "yes", client: "pc", keyword });
      return { url: `https://lyrics.kugou.com/search?${qs}`, headers: browser, key: `kugou-search?${qs}` };
    }
    case "kugou-download": {
      const id = digits("id");
      const accesskey = hex("accesskey") || hex("accessKey");
      if (!id || !accesskey) return null;
      //`accesskey`, ALL LOWERCASE, ON BOTH ENDS. KuGou returns the field as
      // `accesskey` in /search and only accepts it as `accesskey` in /download —
      // camel-case `accessKey` is answered with HTTP 200 and a body of
      // `{"status":400,"info":"Bad Request"}`. The client used camelCase in both
      // places, so it read `undefined` from the candidate and then sent that
      // undefined to an endpoint that would have rejected the right key anyway.
      // Two mistakes that cancelled into one silent, permanent miss.
      const qs = new URLSearchParams({ ver: "1", client: "pc", id, accesskey, fmt: "lrc", charset: "utf8" });
      return { url: `https://lyrics.kugou.com/download?${qs}`, headers: browser, key: `kugou-download?${qs}` };
    }
    case "ovh": {
      const artist = str("artist", 200);
      const title = str("title", 200);
      if (!artist || !title) return null;
      return {
        url: `https://api.lyrics.ovh/v1/${encodeURIComponent(artist)}/${encodeURIComponent(title)}`,
        headers: self,
        key: `ovh?a=${encodeURIComponent(artist)}&t=${encodeURIComponent(title)}`,
      };
    }
  }
  return null;
}

async function handleLyrics(request, env, url) {
  if (request.method !== "GET") return cors(json({ error: "GET only" }, 405));

  // No `source` = the original lrclib /get shape, so older builds keep working.
  const source = (url.searchParams.get("source") || "lrclib").trim();
  const up = lyricsUpstream(source, url.searchParams);
  if (!up) return cors(json({ error: "unknown lyrics source or missing params" }, 400));

  const cache = caches.default;
  const cacheKey = new Request(`${url.origin}/lyrics?${up.key}`, { method: "GET" });
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  let res;
  try {
    res = await fetch(up.url, { headers: up.headers });
  } catch {
    return cors(json({ error: "lyrics upstream unreachable" }, 502));
  }

  let body = await res.text();
  // Drop candidates the client would never look at. Guarded so a shape change
  // upstream degrades to "send it all" rather than to an error.
  if (up.trimList && res.status === 200) {
    try {
      const parsed = JSON.parse(body);
      if (Array.isArray(parsed) && parsed.length > up.trimList) {
        body = JSON.stringify(parsed.slice(0, up.trimList));
      }
    } catch {}
  }
  // 404 is "not found" from lrclib and lyrics.ovh — a legitimate, cacheable
  // answer, not an error to retry. Anything else non-2xx is passed through
  // UNCACHED so a transient upstream problem cannot be frozen at the edge for a
  // month.
  const cacheable = res.status === 200 || res.status === 404;
  // A 200 can still be a miss: NetEase and KuGou answer "nothing found" with a
  // tiny 200 body rather than a 404, and freezing that for 30 days would hide
  // lyrics that get contributed next week.
  const isHit = res.status === 200 && body.length >= 160;
  const resp = cors(new Response(body, {
    status: res.status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  }));
  if (cacheable) {
    resp.headers.set(
      "Cache-Control",
      `public, max-age=${isHit ? LYRICS_TTL_HIT : LYRICS_TTL_MISS}`
    );
    try { await cache.put(cacheKey, resp.clone()); } catch {}
  }
  return resp;
}

/**
 * ── PODCAST FEED → SLIM JSON ─────────────────────────────────────────────────
 *
 * The app used to do `final xmlString = response.body` on the raw feed and parse
 * the XML on the phone. Measured live: 18.5 MB for one show, 2.1 MB for another,
 * re-fetched on a 6-12 hour refresh. That is a lot of mobile data, and the XML
 * parse costs CPU, memory and battery on the device that can least afford it.
 *
 * IT STREAMS AND STOPS EARLY, AND THAT IS NOT AN OPTIMISATION - IT IS THE
 * ONLY WAY THIS FITS. The free Workers tier allows ~10ms CPU per request, which
 * is nowhere near enough to parse 18 MB of XML. Feeds list newest first, so the
 * reader is cancelled once `limit` items have been seen: the Worker typically
 * touches a few hundred KB instead of the whole file, and the phone receives
 * tens of KB instead of megabytes.
 *
 * Hand-rolled scanning rather than an XML library because this Worker has no
 * bundler and no package.json - and a focused indexOf/slice pass is far cheaper
 * per byte than a general parser, which matters against that CPU ceiling.
 *
 * Cached in the EDGE CACHE, never KV: the free KV tier is ~1,000 writes/day and
 * this must not consume it (see the warning in wrangler.toml).
 */
const PODCAST_MAX_ITEMS = 300;
/// Deepest `offset` accepted. Measured on a 2950-episode feed: skipping is a
/// boundary scan with no field extraction, so offset=300 costs ~8ms and fits the
/// free tier's ~10ms CPU budget, while offset=1500 costs ~15ms and offset=2800
/// ~20ms — both over. 600 keeps every accepted request inside the budget.
/// Reaching further needs the paid plan (30s CPU), not a code change.
const PODCAST_MAX_OFFSET = 600;
/// Generous because READING is network time, not CPU — the Worker can pull the
/// whole feed cheaply; it is parsing that costs. Still bounded so a malformed
/// feed that never closes an <item> cannot stream forever.
const PODCAST_MAX_BYTES = 20_000_000;

/**
 * Undo XML entity escaping.
 *
 * ATTRIBUTES NEED THIS TOO, NOT JUST TEXT. XML escapes `&` inside attribute
 * values, so an enclosure url arrives as `…?aid=rss_feed&amp;awCollectionId=…`.
 * Returned raw, `&amp;aid` makes the next query parameter literally named
 * "amp;aid" and the request no longer carries the values the CDN expects. Caught
 * by running the parser over a real feed rather than trusting it.
 */
function unescapeXml(s) {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&apos;/g, "'")
    // LAST: doing this first would turn `&amp;lt;` into `<` instead of `&lt;`.
    .replace(/&amp;/g, "&");
}

function stripTag(s) {
  if (!s) return "";
  // CDATA first, then entities, then any stray markup (some feeds put <p> in
  // titles). Order matters: unescaping before stripping would let an escaped
  // tag become a real one.
  let t = s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
  t = t.replace(/<[^>]*>/g, " ");
  t = unescapeXml(t);
  return t.replace(/\s+/g, " ").trim();
}

/**
 * True when [target] is a public http(s) address this Worker may fetch.
 *
 * THE ONE CHECK THAT KEEPS A FEED PARAMETER FROM BEING AN OPEN FETCHER. Both
 * `/podcast` and `/podcast/notes` take a URL from the caller, and without this
 * either could be pointed at the metadata service, a loopback address, or anything
 * else reachable from inside Cloudflare's network — with the request wearing
 * Cloudflare's reputation rather than the caller's. Shared rather than duplicated
 * so a second feed endpoint cannot be added with the guard accidentally left out.
 */
/**
 * Refuse a URL that does not point at a public host.
 *
 * TESTED AGAINST THE DEPLOYED WORKER, NOT REASONED ABOUT. Results:
 *
 *   http://127.0.0.1/          blocked here
 *   http://2130706433/         blocked here  (URL parser normalises the integer
 *   http://0x7f000001/         blocked here   and hex forms back to 127.0.0.1,
 *                                             so the literal checks below catch
 *                                             them — worth knowing, because it
 *                                             looks like they would not)
 *   http://[::ffff:127.0.0.1]/ PASSED  → only Cloudflare's fetch refused it
 *   http://[::]/               PASSED  → only Cloudflare's fetch refused it
 *   http://localtest.me/       PASSED  → only Cloudflare's fetch refused it
 *
 * The last three got through and were stopped by the platform. That is luck
 * dressed as safety: the two that CAN be caught by inspecting the host are now
 * caught here.
 *
 * AND ONE THAT CANNOT BE. A public hostname whose DNS resolves to a private
 * address (localtest.me → 127.0.0.1, and any attacker-controlled domain) cannot
 * be screened by looking at the string, and a Worker cannot resolve DNS before
 * fetch() to check. That case genuinely depends on Cloudflare refusing the
 * connection, which it currently does. It is written down rather than glossed
 * over: if this route ever moves off Workers, that protection does not come with
 * it and this guard is NOT sufficient on its own.
 *
 * Practical exposure while it is on Workers: a Worker's fetch runs at the edge
 * with no private network and no cloud-metadata endpoint behind it, so the prize
 * for reaching "internal" addresses is close to nothing. The real cost of a lax
 * guard here is quota abuse — this route fetches a caller-named URL — and that is
 * bounded by the parsing (output is transformed into episode JSON, so it is a
 * poor general-purpose proxy) rather than by this function.
 */
function guardPublicHost(target) {
  if (target.protocol !== "http:" && target.protocol !== "https:") return false;
  const h = target.hostname.toLowerCase();
  if (/^(localhost|\[?::1\]?|0\.0\.0\.0)$/.test(h)) return false;
  // The unspecified address, in the forms the URL parser produces.
  if (/^\[?::\]?$/.test(h)) return false;
  // Matched on the normalised host, which is NOT what you type.
  //
  // The URL parser rewrites `[::ffff:127.0.0.1]` as `[::ffff:7f00:1]` — the
  // dotted quad becomes hex, so the first version of this check, which expected
  // a dotted quad, matched nothing. Confirmed against the deployed Worker: it
  // still let that address through and only Cloudflare's fetch refused it.
  //
  // Any `::ffff:` address is an IPv4 address wearing an IPv6 hat, and no
  // legitimate podcast feed lives at one, so the prefix alone is the whole test —
  // no re-parsing, nothing to get subtly wrong a second time.
  if (/^\[?::ffff:/i.test(h)) return false;
  // The IPv4-compatible form (`::127.0.0.1`) normalises to hex the same way, and
  // the deprecated ::x.x.x.x spelling is refused for the same reason.
  if (/^\[?::\d{1,3}(\.\d{1,3}){3}\]?$/.test(h)) return false;
  // RFC1918 + link-local + loopback + CGNAT, matched on the literal host so an
  // IP written into the URL cannot slip past.
  if (/^127\./.test(h)) return false;
  if (/^10\./.test(h)) return false;
  if (/^192\.168\./.test(h)) return false;
  if (/^169\.254\./.test(h)) return false;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(h)) return false;
  if (/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(h)) return false;
  // [? IS LOAD-BEARING: AKDesktop KEEPS THE BRACKETS.
  //
  // new URL('http://[fc00::1]/').hostname is '[fc00::1]', so an anchored
  // /^(fc|fd)/ never matched and IPv6 private-range blocking did NOTHING —
  // fc00::/7 and fe80::/10 both sailed through. Caught by exercising this
  // function directly rather than by reading it; the code looked right.
  if (/^\[?(fc|fd)[0-9a-f]{2}:/i.test(h)) return false; // unique-local IPv6
  if (/^\[?fe80:/i.test(h)) return false;               // link-local IPv6
  // And the named internal endpoints, because every rule above is an ip rule.
  //
  // Verified against the live Worker: `metadata.google.internal` passed this
  // function and the fetch was actually ATTEMPTED — it failed only because
  // Cloudflare's edge could not resolve the name (530). Nothing was reachable,
  // so nothing leaked; the point is that DNS was the only thing standing there,
  // and DNS is not a security control. A hostname needs no IP to name an
  // internal service.
  //
  // It also stops this route working as a blind probe: the error a caller gets
  // back distinguishes "did not resolve" from "resolved and answered", which is a
  // free reachability scanner pointed at whatever Cloudflare's network can see.
  if (/(^|\.)(internal|local|localdomain|home|lan|intranet|corp)$/.test(h)) {
    return false;
  }
  if (/(^|\.)metadata\.(google|goog)/.test(h)) return false;
  if (h === "metadata" || h === "instance-data") return false;
  return true;
}

function tagText(block, tag) {
  const open = block.indexOf(`<${tag}`);
  if (open === -1) return "";
  const gt = block.indexOf(">", open);
  if (gt === -1) return "";
  const close = block.indexOf(`</${tag}>`, gt);
  if (close === -1) return "";
  return stripTag(block.slice(gt + 1, close));
}

function attr(block, tag, name) {
  const open = block.indexOf(`<${tag}`);
  if (open === -1) return "";
  const end = block.indexOf(">", open);
  if (end === -1) return "";
  const seg = block.slice(open, end);
  const m = seg.match(new RegExp(`${name}\\s*=\\s*["']([^"']+)["']`, "i"));
  return m ? unescapeXml(m[1]) : "";
}

/// Show notes are capped, not dropped.
///
/// THE APP MINES TIMESTAMPS OUT OF THESE. Ad segments and chapters are read
/// from the "00:00 Intro / 02:15 Sponsor" lists publishers put in their notes, so
/// returning only a 400-character teaser would have silently broken ad skipping
/// on every show. Notes are also frequently kilobytes of HTML per episode, and
/// 150 of those is most of the payload, so they are capped rather than sent
/// whole: timestamp lists sit near the top of the notes in practice.
///
/// A show whose timestamps appear below the cap loses them. That is a real limit
/// and the reason the client keeps its direct-parse fallback.
const PODCAST_NOTES_CHARS = 3000;

function parseItem(block) {
  const audio = attr(block, "enclosure", "url");
  if (!audio) return null; // no audio = not a playable episode
  // content:encoded usually carries the full notes; description is the fallback.
  const notes = tagText(block, "content:encoded") || tagText(block, "description");
  return {
    title: tagText(block, "title"),
    audio,
    date: tagText(block, "pubDate"),
    duration: tagText(block, "itunes:duration") || tagText(block, "duration"),
    image: attr(block, "itunes:image", "href"),
    guid: tagText(block, "guid"),
    summary: (tagText(block, "itunes:summary") || notes).slice(0, 400),
    notes: notes.slice(0, PODCAST_NOTES_CHARS),
    notesTruncated: notes.length > PODCAST_NOTES_CHARS,
    // Podcasting 2.0 companions. Short strings, and the only route to real
    // timestamped transcripts. See the transcript notes below.
    transcript: attr(block, "podcast:transcript", "url"),
    chapters: attr(block, "podcast:chapters", "url"),
  };
}

async function handlePodcast(request, env, url) {
  if (request.method !== "GET") return cors(json({ error: "GET only" }, 405));

  const feed = url.searchParams.get("url") || "";
  let target;
  try {
    target = new URL(feed);
  } catch {
    return cors(json({ error: "bad url" }, 400));
  }
  if (!guardPublicHost(target)) {
    return cors(json({ error: "blocked host" }, 400));
  }

  const limit = Math.min(
    parseInt(url.searchParams.get("limit") || "150", 10) || 150,
    PODCAST_MAX_ITEMS
  );
  // How many episodes to step over before collecting. This is what makes an
  // episode past the display limit reachable at all: the app can ask for
  // offset=300 and get the next page rather than being capped at the newest 150.
  const offset = Math.min(
    Math.max(parseInt(url.searchParams.get("offset") || "0", 10) || 0, 0),
    PODCAST_MAX_OFFSET
  );

  const cache = caches.default;
  const cacheKey = new Request(
    `${url.origin}/podcast?url=${encodeURIComponent(target.toString())}&limit=${limit}&offset=${offset}`,
    { method: "GET" }
  );
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  let res;
  try {
    res = await fetch(target.toString(), {
      headers: { "User-Agent": "Auvy/1.0 (+podcast client)", Accept: "application/rss+xml, application/xml, text/xml, */*" },
      redirect: "follow",
    });
  } catch {
    return cors(json({ error: "feed unreachable" }, 502));
  }
  if (!res.ok || !res.body) {
    return cors(json({ error: `feed ${res.status}` }, res.status === 404 ? 404 : 502));
  }

  const reader = res.body.getReader();
  const dec = new TextDecoder("utf-8");
  let buf = "";
  let bytes = 0;
  let skipped = 0; // episodes stepped over to honour `offset`
  const items = [];
  let head = null; // channel metadata, taken from the text before the first <item>

  try {
    while (items.length < limit && bytes < PODCAST_MAX_BYTES) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      buf += dec.decode(value, { stream: true });

      if (head === null) {
        const first = buf.indexOf("<item");
        if (first !== -1) {
          const chan = buf.slice(0, first);
          head = {
            title: tagText(chan, "title"),
            // itunes:image is an attribute; <image><url> is an element. Feeds use
            // either, so both are tried before giving up on artwork.
            image: attr(chan, "itunes:image", "href") || tagText(chan, "url"),
            description: (tagText(chan, "description") || "").slice(0, 600),
          };
        }
      }

      // Drain every COMPLETE <item>…</item> currently in the buffer, then keep
      // the remainder for the next chunk.
      //
      // SKIPPING MUST NOT PARSE. While stepping over the first `offset`
      // episodes this only locates boundaries — no tagText, no attr, no entity
      // work. That is the whole reason paging is affordable: measured on a
      // 2950-item feed, skipping 300 then parsing 150 costs ~8ms, where parsing
      // all 2950 costs ~119ms and would blow the CPU limit twelvefold.
      let idx;
      while (items.length < limit && (idx = buf.indexOf("</item>")) !== -1) {
        const start = buf.indexOf("<item");
        if (start === -1 || start > idx) { buf = buf.slice(idx + 7); continue; }
        if (skipped < offset) {
          skipped++;
        } else {
          const parsed = parseItem(buf.slice(start, idx));
          if (parsed) items.push(parsed);
        }
        buf = buf.slice(idx + 7);
      }
    }
  } catch {
    // Whatever was parsed before the failure is still useful; fall through.
  }
  // Stop the transfer. This is the saving: the rest of the feed is never read.
  try { await reader.cancel(); } catch {}

  const out = cors(json({
    feed: head || { title: "", image: "", description: "" },
    episodes: items,
    offset,
    // Honest about truncation so the client can decide whether to ask for more
    // rather than assuming it has the whole show. With `offset` this is also how
    // it knows another page exists.
    truncated: items.length >= limit,
    // Set when the caller asked to start deeper than there are episodes, so the
    // client can stop paging instead of requesting empty pages forever.
    endOfFeed: items.length === 0 && skipped < offset,
    bytesRead: bytes,
  }));
  // Feeds change on a publishing schedule, not by the minute.
  out.headers.set("Cache-Control", "public, max-age=1800");
  try { await cache.put(cacheKey, out.clone()); } catch {}
  return out;
}

/**
 * ── ONE EPISODE'S SHOW NOTES ─────────────────────────────────────────────────
 *
 * THE MEGABYTE FEED DOWNLOAD THAT SURVIVED THE FIRST ROUND. `/podcast` above
 * fixed the episode LIST, but the lyrics view's "show notes" panel had its own,
 * separate copy of the same mistake: iTunes search for the show, then
 * `http.get(feedUrl)` on the phone and a regex sweep over the entire XML to find
 * ONE episode's description. Same 17.7 MB feeds, and worse — it appended a
 * `?_t=<timestamp>` cache-buster, so every single open re-downloaded the lot with
 * every HTTP cache deliberately defeated.
 *
 * This does the show lookup and the feed walk at the edge, returns a few KB of
 * notes, and — because the buster is gone — the second listener to open the same
 * episode is answered by Cloudflare.
 *
 * Matching is done HERE rather than returning a page of episodes, because the
 * episode wanted is frequently not in the newest 150: matching while streaming
 * means the reader can stop the moment it is found, wherever in the feed it sits.
 */
const NOTES_TTL = 21_600; // 6 hours — notes are edited occasionally, not often

/** Loose title match: feeds prefix episode numbers, apps strip them. */
function titlesMatch(a, b) {
  const norm = (s) =>
    s.toLowerCase().replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
  const x = norm(a), y = norm(b);
  if (!x || !y) return false;
  if (x === y) return true;
  if (x.includes(y) || y.includes(x)) return true;
  const wx = new Set(x.split(" ").filter((w) => w.length > 2));
  const wy = new Set(y.split(" ").filter((w) => w.length > 2));
  if (!wx.size || !wy.size) return false;
  let hit = 0;
  for (const w of wx) if (wy.has(w)) hit++;
  return hit / Math.max(wx.size, wy.size) >= 0.6;
}

async function handlePodcastNotes(request, env, url) {
  if (request.method !== "GET") return cors(json({ error: "GET only" }, 405));

  const episode = (url.searchParams.get("episode") || "").trim().slice(0, 300);
  const feedUrl = (url.searchParams.get("url") || "").trim();
  // The feed URL comes from the client, NOT from an itunes lookup here.
  //
  // This first resolved a show NAME by calling itunes.apple.com/search at the
  // edge. Measured against the deployed Worker, that gets 429'd after a handful of
  // requests: Apple throttles by source IP and every user shares one Cloudflare
  // egress address (see the note on the missing /itunes route). The phone's own
  // search always succeeds, so the CLIENT resolves the show and passes the feed
  // here. That keeps the part that actually matters — 18,011 KB downloaded to the
  // device versus ~15 KB read at the edge — without a dependency that fails under
  // exactly the load this exists to serve.
  if (!episode || !feedUrl) {
    return cors(json({ error: "episode and url required" }, 400));
  }

  const cache = caches.default;
  const cacheKey = new Request(
    `${url.origin}/podcast/notes?episode=${encodeURIComponent(episode)}` +
      `&url=${encodeURIComponent(feedUrl)}`,
    { method: "GET" }
  );
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  let target;
  try {
    target = new URL(feedUrl);
  } catch {
    return cors(json({ error: "bad feed url" }, 400));
  }
  if (!guardPublicHost(target)) return cors(json({ error: "blocked host" }, 400));

  let res;
  try {
    res = await fetch(target.toString(), {
      headers: {
        "User-Agent": "Auvy/1.0 (+podcast client)",
        Accept: "application/rss+xml, application/xml, text/xml, */*",
      },
      redirect: "follow",
    });
  } catch {
    return cors(json({ error: "feed unreachable" }, 502));
  }
  if (!res.ok || !res.body) return cors(json({ error: `feed ${res.status}` }, 502));

  const reader = res.body.getReader();
  const dec = new TextDecoder("utf-8");
  let buf = "";
  let bytes = 0;
  let scanned = 0;
  let found = null;

  try {
    while (!found && bytes < PODCAST_MAX_BYTES) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      buf += dec.decode(value, { stream: true });

      let idx;
      while (!found && (idx = buf.indexOf("</item>")) !== -1) {
        const start = buf.indexOf("<item");
        if (start === -1 || start > idx) { buf = buf.slice(idx + 7); continue; }
        const block = buf.slice(start, idx);
        buf = buf.slice(idx + 7);
        scanned++;
        // TITLE FIRST, NOTES ONLY ON A MATCH. Extracting the notes of every
        // episode to compare one title would spend the whole CPU budget on text
        // that gets thrown away — a title is a few bytes, notes are kilobytes.
        const t = tagText(block, "title");
        if (!t || !titlesMatch(t, episode)) continue;
        const notes =
          tagText(block, "content:encoded") || tagText(block, "description");
        found = {
          title: t,
          notes: notes.slice(0, PODCAST_NOTES_CHARS),
          notesTruncated: notes.length > PODCAST_NOTES_CHARS,
          date: tagText(block, "pubDate"),
          transcript: attr(block, "podcast:transcript", "url"),
          chapters: attr(block, "podcast:chapters", "url"),
        };
      }
    }
  } catch {
    // Partial read — report what we have (probably nothing) rather than 500.
  }
  try { await reader.cancel(); } catch {}

  const out = cors(json({
    feedUrl: target.toString(),
    episodesScanned: scanned,
    bytesRead: bytes,
    ...(found ? { episode: found } : { episode: null }),
  }, found ? 200 : 404));
  // A miss is cached too, briefly: an episode title that does not match is the
  // normal answer for a mis-tagged track, and re-walking a big feed for it on
  // every open is the expensive case worth avoiding.
  out.headers.set("Cache-Control", `public, max-age=${found ? NOTES_TTL : 900}`);
  try { await cache.put(cacheKey, out.clone()); } catch {}
  return out;
}


/**
 * ── SONG RECOGNITION (licensed provider) ─────────────────────────────────────
 *
 * WHY THIS EXISTS AT ALL: IT REPLACED A LICENCE VIOLATION.
 *
 * Recognition used to happen entirely on the device: a Shazam signature built by
 * a pure-Dart fingerprinter that was ported line-for-line from Metrolist's
 * `ShazamSignatureGenerator.kt`, POSTed to the undocumented amp.shazam.com
 * discovery endpoint behind a rotation of spoofed Android User-Agents and a
 * randomised geolocation.
 *
 * Three separate problems, all fixed by moving to a real provider:
 *  1. Metrolist is GPL-3.0 and so is the SongRec code it ports, with no
 *     permissive ancestor. A port is a derivative work, so shipping it obliged
 *     the whole app to be GPL-3.0 with source offered to every recipient.
 *  2. Calling an undocumented endpoint while disguising the client is
 *     rate-limit evasion against a service with which there is no agreement.
 *  3. The Shazam trademark was used to brand it.
 *
 * ACRCloud is the provider because its identify API is a plain signed POST — no
 * SDK, no bundled binary, and the credentials stay here rather than in an APK
 * anyone can unzip.
 *
 * NOTHING IS STORED. The clip is forwarded and dropped: no KV write, no cache
 * entry, no log of the audio. It is a user's microphone recording, and the only
 * defensible thing to do with it is use it once and forget it. Do not add caching
 * here "for the free tier" — a cache of recordings is exactly the liability this
 * endpoint should not create.
 */
const RECOGNIZE_MIN_MS = 3000;      // below this a provider call is wasted
const RECOGNIZE_MAX_BYTES = 2_000_000; // ~60s of 16kHz mono 16-bit + header

async function handleRecognize(request, env, url) {
  if (request.method !== "POST") return cors(json({ error: "POST only" }, 405));

  const key = env.ACRCLOUD_ACCESS_KEY;
  const secret = env.ACRCLOUD_ACCESS_SECRET;
  const host = env.ACRCLOUD_HOST; // e.g. identify-eu-west-1.acrcloud.com
  // 503, not 500: the app distinguishes "not configured yet" from "it broke", so
  // the user is told to finish setup rather than told to retry forever.
  if (!key || !secret || !host) {
    return cors(json({ error: "recognition not configured" }, 503));
  }

  const ms = parseInt(url.searchParams.get("ms") || "0", 10) || 0;
  if (ms && ms < RECOGNIZE_MIN_MS) {
    return cors(json({ error: "clip too short" }, 400));
  }

  const clip = new Uint8Array(await request.arrayBuffer());
  if (clip.length === 0) return cors(json({ error: "empty body" }, 400));
  if (clip.length > RECOGNIZE_MAX_BYTES) {
    return cors(json({ error: "clip too large" }, 413));
  }

  // ACRCloud's HMAC-SHA1 request signature
  // The string-to-sign layout is fixed by their API: method, endpoint, key,
  // data type, version, timestamp — newline separated, in that order.
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const stringToSign = [
    "POST", "/v1/identify", key, "audio", "1", timestamp,
  ].join("\n");

  let signature;
  try {
    const hmacKey = await crypto.subtle.importKey(
      "raw", new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-1" }, false, ["sign"]
    );
    const sig = await crypto.subtle.sign(
      "HMAC", hmacKey, new TextEncoder().encode(stringToSign)
    );
    signature = btoa(String.fromCharCode(...new Uint8Array(sig)));
  } catch (e) {
    return cors(json({ error: "signing failed" }, 500));
  }

  const form = new FormData();
  form.append("access_key", key);
  form.append("data_type", "audio");
  form.append("signature_version", "1");
  form.append("signature", signature);
  form.append("timestamp", timestamp);
  form.append("sample_bytes", String(clip.length));
  form.append("sample", new Blob([clip], { type: "audio/wav" }), "sample.wav");

  let res, body;
  try {
    res = await fetch(`https://${host}/v1/identify`, { method: "POST", body: form });
    body = await res.json();
  } catch {
    return cors(json({ error: "recognition upstream unreachable" }, 502));
  }

  // ACRCloud reports outcome in status.code, not in the HTTP status: 0 = match,
  // 1001 = no result. Treating 1001 as an error would surface "recognition
  // failed" for the ordinary case of unrecognised audio.
  const code = body?.status?.code;
  if (code === 1001) return cors(json({ error: "no match" }, 404));
  if (code !== 0) {
    return cors(json({ error: body?.status?.msg || "recognition failed" }, 502));
  }

  const music = body?.metadata?.music?.[0];
  if (!music) return cors(json({ error: "no match" }, 404));

  // Flattened to the shape the client parses
  // Normalising here rather than in the app means swapping providers later is a
  // Worker deploy with no client release.
  const artist = (music.artists || []).map((a) => a.name).filter(Boolean).join(", ");
  const ext = music.external_metadata || {};
  const out = {
    id: music.acrid || null,
    title: music.title || null,
    artist: artist || null,
    album: music.album?.name || null,
    genre: (music.genres || [])[0]?.name || null,
    releaseDate: music.release_date || null,
    label: music.label || null,
    isrc: music.external_ids?.isrc || null,
    spotifyUrl: ext.spotify?.track?.id
      ? `https://open.spotify.com/track/${ext.spotify.track.id}`
      : null,
    appleMusicUrl: ext.apple_music?.url || null,
    youtubeVideoId: ext.youtube?.vid || null,
    cover: null,
    coverHq: null,
  };
  if (!out.title || !out.artist) return cors(json({ error: "no match" }, 404));

  const resp = cors(json(out));
  // Never cached: see the note above. A recognition response is tied to one
  // recording from one person at one moment.
  resp.headers.set("Cache-Control", "no-store");
  return resp;
}


async function handleCovers(request, env, url) {
  if (request.method !== "GET") return cors(json({ error: "GET only" }, 405));

  const gh = (path, accept) =>
    fetch(`https://api.github.com${path}`, {
      headers: {
        "User-Agent": "Auvy-Covers",
        Accept: accept || "application/vnd.github+json",
        ...(env.GITHUB_TOKEN
          ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` }
          : {}),
      },
    });

  // one image
  const img = url.pathname.match(/^\/covers\/img\/([A-Za-z0-9._-]+)$/);
  if (img) {
    const cache = caches.default;
    const key = new Request(url.toString(), { method: "GET" });
    const hit = await cache.match(key);
    if (hit) return hit;

    // Accept: raw streams the file itself rather than a base64 JSON envelope.
    const res = await gh(
      `/repos/${RELEASE_OWNER}/${COVERS_REPO}/contents/${COVERS_DIR}/${img[1]}`,
      "application/vnd.github.raw"
    );
    if (!res.ok) return cors(json({ error: `github ${res.status}` }, 404));
    const out = cors(
      new Response(res.body, {
        status: 200,
        headers: {
          "Content-Type": contentTypeFor(img[1]),
          // The app caches the picked image locally anyway; this just stops
          // the picker grid re-fetching on every open.
          "Cache-Control": "public, max-age=604800, immutable",
        },
      })
    );
    try { await cache.put(key, out.clone()); } catch (_) {}
    return out;
  }

  // the list
  if (url.pathname === "/covers" || url.pathname === "/covers/") {
    const cache = caches.default;
    const key = coversListKey(url);
    const hit = await cache.match(key);
    if (hit) return hit;

    // THE TREES API, NOT /contents — /contents SILENTLY CAPS AT 1000 ENTRIES.
    //
    // This used `/contents/${COVERS_DIR}`, which returns at most 1000 files for
    // a directory and gives no indication that it truncated. The library grew
    // past that (1691 covers), so roughly 700 of them would simply not exist as
    // far as the app was concerned — present in the repo, invisible in the
    // picker, with nothing anywhere reporting a problem.
    //
    // `git/trees/{ref}:{path}` returns the same information for up to 100,000
    // entries in one call and DOES flag truncation, which is checked below. Its
    // entries use `path`/`blob` where /contents used `name`/`file`.
    const res = await gh(
      `/repos/${RELEASE_OWNER}/${COVERS_REPO}/git/trees/HEAD:${COVERS_DIR}`
    );
    // 404 = the folder does not exist yet. An empty list is the honest answer;
    // the app then just hides the picker rather than showing an error for a
    // feature that is simply not set up.
    if (res.status === 404) return cors(json({ covers: [] }));
    if (!res.ok) {
      console.log(`covers — github ${res.status}`);
      return cors(json({ error: `github ${res.status}` }, 502));
    }
    const listed = await res.json();
    // Loud rather than silent: if this ever trips, covers are missing from the
    // picker and the only symptom would be a user saying "I can't find it".
    if (listed && listed.truncated) {
      console.log("covers — WARNING: git tree truncated, some covers hidden");
    }
    const entries = Array.isArray(listed && listed.tree) ? listed.tree : [];
    const covers = entries
      .filter((e) => e.type === "blob" && /\.(webp|jpg|jpeg|png)$/i.test(e.path))
      // ONLY WHAT THE CLIENT READS. It parses `name` and `url` and nothing
      // else (see coverLibraryProvider), so `file` and `size` were pure payload
      //, and `file` duplicated the filename that `url` already contains. At
      // 1691 covers that is ~90 KB of JSON nobody looked at.
      //
      // `name` and `url` are kept verbatim rather than compressed into a base +
      // suffix scheme: builds already in the wild parse exactly these two keys,
      // and breaking them to save bytes on a list that gzips well would trade a
      // real regression for a small win. Cloudflare compresses this response, so
      // the repetitive names and shared origin cost far less on the wire than
      // the uncompressed size suggests.
      .map((e) => ({
        name: e.path.replace(/\.[^.]+$/, ""),
        // ?v=<blob sha>. The image route below answers `immutable` for a
        // week, keyed on the URL. Keyed on the NAME alone that is a lie the
        // moment a file is replaced or a variant is renamed onto an existing
        // name — every edge would keep serving the old artwork. The sha comes
        // from the content itself, so changed bytes mean a new URL and the
        // promise becomes true. The image handler matches on pathname and
        // ignores the query, so nothing downstream has to know about it.
        url: `${url.origin}/covers/img/${encodeURIComponent(e.path)}?v=${String(e.sha || "").slice(0, 10)}`,
      }))
      // SORT ON `name`, NOT `file`. This read `a.file` after `file` was
      // dropped from the payload above, so every entry compared `undefined` and
      // the whole route threw — Cloudflare 1101, a 500 on /covers, and an empty
      // picker in the app. `name` is the same string minus the extension, so the
      // order is unchanged.
      .sort((a, b) => a.name.localeCompare(b.name));

    const out = cors(json({ covers }));
    // 15 minutes, not 6 hours. The images are versioned and cached hard, so
    // this listing is a few KB of names — the only cost of a short TTL is one
    // GitHub call per 15 min per colo, and the benefit is that adding or
    // removing a cover shows up the same day rather than the next one.
    out.headers.set("Cache-Control", "public, max-age=900");
    try { await cache.put(key, out.clone()); } catch (_) {}
    return out;
  }

  return cors(json({ error: "unknown covers route" }, 404));
}

function contentTypeFor(name) {
  const n = name.toLowerCase();
  if (n.endsWith(".webp")) return "image/webp";
  if (n.endsWith(".png")) return "image/png";
  return "image/jpeg";
}
// Update channel
//
// WHY THIS EXISTS: the releases repo had to be PUBLIC, because GitHub's API
// answers 404 to an unauthenticated client for a private repo and the in-app
// update check would break for everyone. Public releases repo means the APK is
// one click away for anyone who lands on the owner's GitHub profile — which
// makes controlling who gets the app impossible, however careful the in-app
// approval gate is.
//
// Shipping a PAT inside the APK was never an option: anyone can unzip it and
// read the string out.
//
// So the Worker holds the token instead and proxies the two calls the updater
// needs. The releases repo can now be private:
//
//   GET /release/latest      trimmed release JSON, same shape the app already
//                            parses, with each APK asset's download URL
//                            rewritten to point back here.
//   GET /release/asset/:id   302 to GitHub's short-lived signed asset URL, so
//                            the 80MB download goes straight from GitHub to the
//                            device and never through the Worker.
//
// The token is a fine-grained PAT with read-only Contents on the releases repo
// ALONE — it cannot reach the source repo even if the Worker were compromised.
// Without GITHUB_TOKEN set, these still work against a public repo, so nothing
// breaks in the window before the secret is added.
//
// This closes "discoverable from my GitHub profile". It does NOT gate the
// endpoints: the Worker URL is a plain string inside the APK, so anyone already
// holding the app can pull an update from it. That is the same set of people who
// already have the app, which is why it is left open rather than complicated.
const RELEASE_OWNER = "AKDontMiss";

// Releases AND covers now live in different repos
//
// These were ONE constant, and splitting them was not tidying — pointing the
// single value at the public repo would have silently broken every cover in the
// app, because /covers and /covers/img read `RELEASE_REPO` too and the artwork
// exists only in the private repo.
//
// Releases moved out when Auvy adopted GPL-3.0: the licence obliges the source to
// be available to anyone who receives the APK, so the source and the APK are now
// published together in the PUBLIC `Auvy`.
//
// That also removes a compromise recorded here previously. Reading a release
// needs `Contents: Read` (GitHub has no releases-only scope), which on a private
// source repo means the token could read the code as well. Against a public repo
// that is moot — there is nothing there to protect.
//
// RENAMED 2026-09-02. The public repo was `Auvy-releases` and is now `Auvy`;
// the private one was `Auvy` and is now `Auvy-private`. The two names swapped
// meaning, so BOTH constants here had to move at once — leaving either behind
// pointed it at the wrong repository rather than at nothing, which is the
// failure the note on COVERS_REPO below warns about.
const RELEASE_REPO = "Auvy";

// The cover library stays in the PRIVATE repo, deliberately.
//
// The artwork is licensed for non-commercial use by its author, and it was left
// out of the public source export rather than redistributed more widely than that
// permission clearly covers. So it still needs the token to be read, and the
// token still needs `Contents: Read` on this repo — keep it read-only, scoped to
// this repo alone, and rotate it if the Cloudflare account is ever compromised.
//
// Anything served from the private repo must use THIS constant, not
// RELEASE_REPO. A future endpoint that reads repo content and reaches for the
// wrong one will 404 in a way that looks like a missing file rather than a
// misconfiguration.
const COVERS_REPO = "Auvy-private";
// 60s, NOT 15 MINUTES. A publish must become visible quickly.
//
// This was 900s to spare GitHub's rate limit, and it caused the exact bug it
// was meant to prevent: v1.2.4 was published, the app kept reading a cached
// v1.2.3, and "Check for Updates" re-read that same cache, so there was no
// way to force a real check. An updater that can be a quarter of an hour out
// of date, with no override, is not an updater.
//
// 60s costs at most 60 GitHub calls an hour against a 5,000/hr authenticated
// limit. The cache exists to collapse a launch stampede, and one minute does
// that as well as fifteen.
const RELEASE_CACHE_SECONDS = 60;

// Minimum spacing between fresh=1 bypasses (see /release/latest). Bounds what
// a manual "Check for Updates" — or a loop pretending to be one — can cost.
const RELEASE_FRESH_FLOOR_SECONDS = 30;

/**
 * Cache key for a release route, with the QUERY STRING DELIBERATELY DROPPED.
 *
 * THIS IS A QUOTA CONTROL, NOT A TIDY-UP. The key used to be the full URL,
 * so every distinct query string was a separate cache entry and therefore a
 * separate GitHub API call: `?x=1`, `?x=2`, `?x=3`… walked straight past the
 * cache. These routes are intentionally unauthenticated — the hostname is a
 * plain string inside the APK — so anyone holding the app could drain the
 * PAT's 5,000/hr limit in minutes and leave every user unable to check for
 * updates. Normalising the key means unknown parameters change nothing.
 *
 * [marker] names an internal companion entry (the fresh floor). It is never
 * caller-controlled.
 */
function releaseCacheKey(url, marker) {
  return new Request(`${url.origin}${url.pathname}${marker || ""}`, {
    method: "GET",
  });
}

/**
 * Is the caller an approved Auvy user?
 *
 * Reuses resolveIdentity, the same uid hash and the same KV record as the access
 * check, so this Worker has ONE definition of "approved". The cookie arrives in
 * a header rather than the URL: this is a GET that redirects, and a credential
 * in a query string ends up in logs.
 */
async function requireApprovedDownloader(request, env) {
  const cookie = request.headers.get("X-Auvy-Cookie") || "";
  if (!cookie) {
    return {
      ok: false,
      response: cors(json({ error: "download requires an approved Auvy account" }, 401)),
    };
  }
  if (!env.USERS) {
    return { ok: false, response: cors(json({ error: "no USERS KV" }, 500)) };
  }
  try {
    const { identity } = await resolveIdentity(cookie);
    if (!identity) {
      return { ok: false, response: cors(json({ error: "could not verify account" }, 401)) };
    }
    // Owners are always allowed, exactly as in the access gate — otherwise the
    // one person who must never be locked out could be.
    if (ownerSet(env).has(identity.trim().toLowerCase())) return { ok: true };

    const uid = await sha256Hex(BACKUP_SALT + identity.toLowerCase());
    const rec = await getRec(env, uid);
    if (!rec || rec.status !== "approved") {
      return {
        ok: false,
        response: cors(json({ error: "this account is not approved for downloads" }, 403)),
      };
    }
    return { ok: true };
  } catch (e) {
    // A verification FAILURE must never become a free download.
    console.log("release gate error: " + (e && e.message));
    return { ok: false, response: cors(json({ error: "could not verify account" }, 401)) };
  }
}

async function handleRelease(request, env, url) {
  if (request.method !== "GET") return cors(json({ error: "GET only" }, 405));

  const gh = (path, accept) =>
    fetch(`https://api.github.com${path}`, {
      headers: {
        "User-Agent": "Auvy-Updater",
        Accept: accept || "application/vnd.github+json",
        ...(env.GITHUB_TOKEN
          ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` }
          : {}),
      },
      // Manual, so the asset route can read the signed Location instead of
      // following it and streaming 80MB through the Worker.
      redirect: "manual",
    });

  if (url.pathname === "/release/latest") {
    const cache = caches.default;
    const cacheKey = releaseCacheKey(url);

    // `?fresh=1` — sent ONLY when the user taps "Check for Updates".
    //
    // A manual check should mean check, not "re-read an answer up to a minute
    // old". Automatic launch checks keep using the cache, so the common path
    // still costs nothing.
    //
    // The bypass is throttled by a companion cache entry that expires on its
    // own: while the floor exists, a fresh request falls back to the cached
    // copy. So a hammered endpoint costs at most one extra GitHub call every
    // RELEASE_FRESH_FLOOR_SECONDS, however many callers ask.
    //
    //`wantsFresh`, not `bypass`, decides cacheability further down. A
    // throttled manual check still returns the cached copy, and if that copy
    // carried max-age it would be stored at the edge under the ?fresh=1 URL,
    // so the NEXT manual check would be answered by the edge and never reach
    // this Worker. The bypass would quietly stop bypassing.
    const wantsFresh = url.searchParams.get("fresh") === "1";
    let bypass = false;
    if (wantsFresh) {
      const floorKey = releaseCacheKey(url, "?__freshfloor=1");
      if (!(await cache.match(floorKey))) {
        bypass = true;
        try {
          await cache.put(
            floorKey,
            new Response("1", {
              headers: {
                "Cache-Control": `public, max-age=${RELEASE_FRESH_FLOOR_SECONDS}`,
              },
            })
          );
        } catch (_) {}
      }
    }

    /// Strip cacheability from anything answering a manual check.
    const uncacheable = (res) => {
      const live = new Response(res.clone().body, res);
      live.headers.set("Cache-Control", "no-store");
      return live;
    };

    if (!bypass) {
      const hit = await cache.match(cacheKey);
      if (hit) return wantsFresh ? uncacheable(hit) : hit;
    }

    const res = await gh(
      `/repos/${RELEASE_OWNER}/${RELEASE_REPO}/releases/latest`
    );
    if (!res.ok) {
      console.log(`release/latest — github ${res.status}`);
      return cors(json({ error: `github ${res.status}` }, res.status === 404 ? 404 : 502));
    }
    const data = await res.json();
    // Only what the updater actually reads. Trimming is not cosmetic: the raw
    // response carries uploader logins, node ids and API URLs for a repo that is
    // supposed to be private.
    const assets = (data.assets || [])
      .filter((a) => (a.name || "").toLowerCase().endsWith(".apk"))
      .map((a) => ({
        name: a.name,
        size: a.size,
        // Filename kept on the path so the CLIENT can insist the target is an
        // .apk. Without it the app cannot tell this route apart from a release
        // PAGE url, and with a private repo that page is an HTML login screen —
        // which the installer would be handed as if it were a package.
        browser_download_url: `${url.origin}/release/asset/${a.id}/${encodeURIComponent(a.name)}`,
      }));
    const out = cors(
      json({
        tag_name: data.tag_name,
        body: data.body,
        html_url: data.html_url,
        published_at: data.published_at,
        assets,
      })
    );
    out.headers.set("Cache-Control", `public, max-age=${RELEASE_CACHE_SECONDS}`);
    try {
      await cache.put(cacheKey, out.clone());
    } catch (_) {}

    // A bypass must NOT be cacheable, OR it stops being a bypass.
    //
    // Cloudflare caches in FRONT of the Worker, keyed on the full request URL
    // and driven by the Cache-Control we set here, so a cacheable response
    // means later identical requests are answered at the edge and this code
    // never runs. That is precisely how the original bug worked: a 900s header
    // on /release/latest built an edge entry the Worker could not see past
    // (observed live as `cf-cache-status: HIT, age: 721`), so the app was told
    // v1.2.3 long after v1.2.4 was published.
    //
    // `?fresh=1` would inherit the same trap one minute at a time: tap "Check
    // for Updates" twice and the second tap reads an edge copy. no-store keeps
    // every manual check arriving here. It is not a load risk — the floor entry
    // above still bounds how often a bypass reaches GitHub, and between floors
    // this returns the cached copy.
    return wantsFresh ? uncacheable(out) : out;
  }

  // The in-app changelog page. Same trimming, same cache.
  if (url.pathname === "/release/list") {
    const cache = caches.default;
    // Normalised for the same quota reason as /release/latest.
    const cacheKey = releaseCacheKey(url);
    const hit = await cache.match(cacheKey);
    if (hit) return hit;

    const res = await gh(
      `/repos/${RELEASE_OWNER}/${RELEASE_REPO}/releases?per_page=20`
    );
    if (!res.ok) {
      console.log(`release/list — github ${res.status}`);
      return cors(json({ error: `github ${res.status}` }, res.status === 404 ? 404 : 502));
    }
    const list = (await res.json())
      .filter((r) => r.draft !== true)
      .map((r) => ({
        tag_name: r.tag_name,
        name: r.name,
        body: r.body,
        published_at: r.published_at,
        prerelease: r.prerelease === true,
      }));
    const out = cors(json(list));
    out.headers.set("Cache-Control", `public, max-age=${RELEASE_CACHE_SECONDS}`);
    try {
      await cache.put(cacheKey, out.clone());
    } catch (_) {}
    return out;
  }

  // Trailing filename is optional and ignored — it exists purely so the client
  // can require the download target to end in `.apk`.
  const asset = url.pathname.match(/^\/release\/asset\/(\d+)(?:\/[^/]+)?$/);
  if (asset) {
    // The only gated release route, AND the only one that matters.
    //
    // Making the repo private stopped anyone browsing to the owner's GitHub
    // and downloading Auvy. This proxy then handed the same APK to anyone who
    // knew the Worker hostname, which is not a secret: it is compiled into
    // the app, so anyone holding a copy can read it out. That was obscurity
    // standing in for access control.
    //
    // The bytes now require an APPROVED account, checked with exactly the
    // machinery the launch-time access check already uses: resolve the
    // identity from the caller's own YouTube cookie, hash it to the same uid,
    // read the same KV record. No new credential, and no token shipped inside
    // the APK — the thing this whole design set out to avoid.
    //
    // /release/latest stays OPEN deliberately: it returns a version string and
    // a changelog, nothing worth protecting, and leaving it open means an
    // unapproved or older build still learns an update exists rather than
    // silently believing it is current.
    const gate = await requireApprovedDownloader(request, env);
    if (!gate.ok) return gate.response;
    const res = await gh(
      `/repos/${RELEASE_OWNER}/${RELEASE_REPO}/releases/assets/${asset[1]}`,
      "application/octet-stream"
    );
    const location = res.headers.get("Location");
    if (res.status >= 300 && res.status < 400 && location) {
      // The signed URL expires in minutes and needs no auth, so handing it to
      // the device is safe and keeps the bytes off the Worker.
      return cors(new Response(null, { status: 302, headers: { Location: location } }));
    }
    // Public repo (no token): GitHub answers 200 with the bytes rather than a
    // redirect. Stream it through rather than failing.
    if (res.ok) {
      return cors(
        new Response(res.body, {
          status: 200,
          headers: {
            "Content-Type":
              res.headers.get("Content-Type") || "application/vnd.android.package-archive",
          },
        })
      );
    }
    console.log(`release/asset — github ${res.status}`);
    return cors(json({ error: `github ${res.status}` }, 502));
  }

  return cors(json({ error: "unknown release route" }, 404));
}

// Admin
async function handleAdmin(request, env, url) {
  // Sign in with a username AND password
  //
  // Typing a 64-character hex token into a phone is not something anyone does
  // twice, so the dashboard signs in with credentials and receives the real
  // ADMIN_TOKEN back, which it then keeps and sends on every later call. The
  // token remains the ONLY thing the API trusts — this route just hands it to
  // someone who proved they know the password.
  //
  // A password is guessable in a way a 256-bit token is not, so this route —
  // and only this route — is rate limited. Ten failures per hour per IP. The
  // limiter is the Cache API, which is per-colocation and therefore approximate;
  // it blunts a script, it is not a hard boundary. Keep the password long.
  if (url.pathname === "/admin/login" && request.method === "POST") {
    if (!env.ADMIN_USER || !env.ADMIN_PASSWORD) {
      return cors(json({ error: "password sign-in not configured" }, 501));
    }
    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    if (!(await allowLogin(ip))) {
      return cors(json({ error: "too many attempts — try again later" }, 429));
    }
    let creds;
    try { creds = await request.json(); } catch { return cors(json({ error: "bad json" }, 400)); }
    const userOk = timingSafeEqual(String(creds.username || ""), env.ADMIN_USER);
    const passOk = timingSafeEqual(String(creds.password || ""), env.ADMIN_PASSWORD);
    // Both compared before answering, so the reply time does not reveal which
    // half was wrong, and the message never says either.
    if (!userOk || !passOk) {
      return cors(json({ error: "wrong username or password" }, 401));
    }
    return cors(json({ token: env.ADMIN_TOKEN }));
  }

  const supplied = request.headers.get("X-Admin-Token") || "";
  // Constant-time-ish compare: bail on length first, then accumulate.
  if (!env.ADMIN_TOKEN || !timingSafeEqual(supplied, env.ADMIN_TOKEN)) {
    return cors(json({ error: "unauthorized" }, 401));
  }
  if (!env.USERS) return cors(json({ error: "no USERS KV" }, 500));

  // Purge the cover cache
  //
  // The cover listing is edge-cached, so adding or removing an image in the repo
  // takes up to its TTL to appear. A deploy does NOT clear caches.default — the
  // cache outlives the code that wrote it, so after editing the folder there was
  // no way to see the change except to wait. This is that way.
  //
  // Only the LISTING is dropped. Individual images are versioned by blob sha, so
  // a changed image already has a different URL and its stale entry is simply
  // never requested again.
  if (url.pathname === "/admin/purge-covers") {
    let dropped = false;
    try {
      dropped = await caches.default.delete(coversListKey(url));
    } catch (e) {
      return cors(json({ error: "purge failed: " + (e && e.message) }, 500));
    }
    // Per-colocation. This clears the cache of the edge that served THIS
    // request; other regions expire on their own TTL. Honest about it rather
    // than reporting a global purge it cannot perform.
    return cors(json({ ok: true, dropped, scope: "this edge only" }));
  }

  if (url.pathname === "/admin/users" && request.method === "GET") {
    const out = [];
    let cursor;
    // KV list is paginated; walk it so the roster is complete rather than the
    // first page silently looking like "all users".
    do {
      const page = await env.USERS.list({ prefix: "u:", cursor });
      for (const k of page.keys) {
        const rec = await getRecByKey(env, k.name);
        if (rec) out.push(rec);
      }
      cursor = page.list_complete ? null : page.cursor;
    } while (cursor);
    // Mark the owner so the dashboard can badge them — it is the one row you
    // must never lock out, and knowing which it is at a glance matters.
    const owners = ownerSet(env);
    for (const r of out) r.isOwner = owners.has((r.identity || "").trim().toLowerCase());
    out.sort((a, b) => (b.lastSeenMs || 0) - (a.lastSeenMs || 0));
    return cors(json({
      count: out.length,
      pending: out.filter((r) => r.status === "pending").length,
      approved: out.filter((r) => r.status === "approved").length,
      blocked: out.filter((r) => r.status === "blocked").length,
      users: out,
    }));
  }

  if (url.pathname === "/admin/stats" && request.method === "GET") {
    const g = (await env.USERS.get(globalKey(), { type: "json" })) || { count: 0 };
    const n = (await env.USERS.get(newAcctKey(), { type: "json" })) || { count: 0 };
    const cfg = (await env.USERS.get(enrolKey(), { type: "json" })) || { open: true };
    const refused = (await env.USERS.get(refusedKey(), { type: "json" })) || { count: 0 };
    const counts = await countByStatus(env);
    return cors(json({
      day: dayKey(),
      // Sign-ins the gate turned away today. Non-zero with enrolment closed means
      // real people are being refused, which is the state that otherwise looks
      // identical to nobody trying.
      refusedToday: refused.count || 0,
      refusedClosed: refused.closed || 0,
      refusedFull: refused.full || 0,
      // count + pending, NOT count alone, and the sum is EXACT, not an
      // estimate. allowGlobalMint writes on EVERY mint; it only splits the
      // total between a flushed `count` and a running `pending` so each write
      // stays small against the ~1k/day KV budget. Reading `count` alone
      // reported 0 after a real sign-in, which reads as "nothing is happening"
      // while the service is in fact working.
      mints: (g.count || 0) + (g.pending || 0),
      mintCap: MAX_MINTS_PER_DAY,
      newAccountsToday: n.count || 0,
      newAccountCap: MAX_NEW_ACCOUNTS_PER_DAY,
      enrolmentOpen: cfg.open !== false,
      approved: counts.approved,
      approvedCap: MAX_APPROVED_ACCOUNTS,
      pending: counts.pending,
      blocked: counts.blocked,
      // What matters when deciding whether to let anyone else in.
      approvedHeadroom: Math.max(0, MAX_APPROVED_ACCOUNTS - counts.approved),
    }));
  }

  // Open or close enrolment at runtime. Closing turns unknown accounts away
  // WITHOUT recording them, so the pending list stops growing and costs nothing —
  // the refusals are tallied in one counter per day so the state is still visible.
  if (url.pathname === "/admin/enrolment") {
    if (request.method === "GET") {
      const cfg = (await env.USERS.get(enrolKey(), { type: "json" })) || { open: true };
      return cors(json({ open: cfg.open !== false }));
    }
    if (request.method === "POST") {
      let b;
      try { b = await request.json(); } catch { return cors(json({ error: "bad json" }, 400)); }
      const open = b.open !== false;
      await env.USERS.put(enrolKey(), JSON.stringify({ open }));
      return cors(json({ ok: true, open }));
    }
  }

  if (request.method !== "POST") return cors(json({ error: "POST only" }, 405));

  let body;
  try { body = await request.json(); } catch { return cors(json({ error: "bad json" }, 400)); }
  const id = (body.id || "").trim();
  if (!id) return cors(json({ error: "missing id (uid or identity)" }, 400));

  // Accept either the uid or the human identity, because the roster shows both and
  // typing an email is far less error-prone than a 64-char hash.
  const uid = /^[0-9a-f]{64}$/i.test(id)
    ? id.toLowerCase()
    : await sha256Hex(BACKUP_SALT + id.toLowerCase());

  const rec = (await getRec(env, uid)) || {
    uid, identity: id, firstSeenMs: Date.now(), signIns: 0,
  };

  // `unblock` is the same operation as `approve` — both mean "this account may
  // use Auvy again", both re-enable the Firebase user. It was a second copy of
  // the same six lines; now it is an alias, so the two can never drift apart.
  if (url.pathname === "/admin/approve" || url.pathname === "/admin/unblock") {
    // Don't let a generous afternoon out-approve the quota. It is APPROVED users
    // who consume Firestore reads/writes, so this is the number that decides
    // whether sync keeps working for the people already relying on it.
    if (rec.status !== "approved") {
      const counts = await countByStatus(env);
      if (counts.approved >= MAX_APPROVED_ACCOUNTS) {
        return cors(json({
          error: "approved-account cap reached",
          approved: counts.approved,
          cap: MAX_APPROVED_ACCOUNTS,
          hint: "block someone, or raise MAX_APPROVED_ACCOUNTS and redeploy",
        }, 409));
      }
    }
    rec.status = "approved";
    await putRec(env, rec);
    // Undo any earlier disable, or approval would look applied but not work.
    const fb = await setFirebaseUserDisabled(uid, false, env);
    return cors(json({ ok: true, uid, status: rec.status, firebase: fb }));
  }

  if (url.pathname === "/admin/block") {
    // An owner cannot be blocked, AND saying so beats pretending.
    //
    // The sign-in path force-approves any identity in OWNER_IDENTITIES, on
    // purpose, so that tightening the rules can never lock the owner out of
    // their own app. But this endpoint happily wrote "blocked" anyway, so the
    // dashboard showed BLOCKED while the very next sign-in silently re-approved
    // them. Observed as a row reading OWNER, BLOCKED and 7 sign-ins at once.
    //
    // A control that reports success and changes nothing is worse than one that
    // refuses: refusing tells the owner what to do instead, which is to take the
    // identity out of OWNER_IDENTITIES first.
    if (ownerSet(env).has((rec.identity || "").trim().toLowerCase())) {
      return cors(json({
        error: "owner identities cannot be blocked or disapproved — remove the " +
          "identity from the OWNER_IDENTITIES secret first, then redeploy",
        uid,
        status: rec.status,
        owner: true,
      }, 409));
    }
    rec.status = "blocked";
    await putRec(env, rec);
    // THIS is what actually ends an existing session. See the refresh-token
    // note at the top. Reported back so a failure here is visible rather than
    // leaving the owner believing someone was kicked out when they weren't.
    const fb = await setFirebaseUserDisabled(uid, true, env);
    return cors(json({ ok: true, uid, status: rec.status, firebase: fb }));
  }

  // DISAPPROVE: back to the queue, not the blocklist
  //
  // The missing third verb. `block` says "you are barred" and the app tells the
  // person their access was removed; there was no way to simply UNDO an approval
  // and put someone back to waiting. That is the softer, commoner decision — and
  // without it the only way to reverse an approval was to brand them blocked.
  //
  // It disables the Firebase user for the same reason `block` does: a refresh
  // token already in their hands would otherwise keep working regardless of what
  // the record says. Approving them again re-enables it.
  if (url.pathname === "/admin/disapprove") {
    // An owner cannot be blocked, AND saying so beats pretending.
    //
    // The sign-in path force-approves any identity in OWNER_IDENTITIES, on
    // purpose, so that tightening the rules can never lock the owner out of
    // their own app. But this endpoint happily wrote "blocked" anyway, so the
    // dashboard showed BLOCKED while the very next sign-in silently re-approved
    // them. Observed as a row reading OWNER, BLOCKED and 7 sign-ins at once.
    //
    // A control that reports success and changes nothing is worse than one that
    // refuses: refusing tells the owner what to do instead, which is to take the
    // identity out of OWNER_IDENTITIES first.
    if (ownerSet(env).has((rec.identity || "").trim().toLowerCase())) {
      return cors(json({
        error: "owner identities cannot be blocked or disapproved — remove the " +
          "identity from the OWNER_IDENTITIES secret first, then redeploy",
        uid,
        status: rec.status,
        owner: true,
      }, 409));
    }
    rec.status = "pending";
    await putRec(env, rec);
    const fb = await setFirebaseUserDisabled(uid, true, env);
    return cors(json({ ok: true, uid, status: rec.status, firebase: fb }));
  }

  // FORGET: erase the record entirely
  //
  // Not the same as blocking. Blocking is a decision you keep; forgetting throws
  // the row away, so the account is a stranger again and re-enrols as `pending`
  // the next time it signs in. For clearing out dead entries — an account that
  // no longer exists, a test sign-in, someone who asked to be removed.
  //
  // The Firebase user is disabled on the way out, because the record is what
  // would otherwise have justified keeping their session alive. The identity
  // ANCHOR is deliberately left in place: it is keyed by a hash of the SAPISID
  // and its only job is to keep the uid stable, so dropping it would risk
  // orphaning a backup if the same person ever came back.
  if (url.pathname === "/admin/forget") {
    const fb = await setFirebaseUserDisabled(uid, true, env);
    // Read BEFORE the delete: whether this record counted against today's intake
    // is only knowable while it still exists.
    const gone = await getRec(env, uid);
    try {
      await env.USERS.delete(`u:${uid}`);
    } catch (e) {
      return cors(json({ error: "delete failed: " + (e && e.message) }, 500));
    }
    // Only a record CREATED today holds one of today's slots; an older one was
    // counted against a day whose key has already expired.
    //
    // NOT rec.dayKey — that field is the per-account sign-in day and is rolled
    // forward on every sign-in, so an account first seen weeks ago but used today
    // carries today's key and would refund a slot it never took.
    if (gone && firstSeenDay(gone) === dayKey()) await decNewAccounts(env);
    return cors(json({ ok: true, uid, status: "forgotten", firebase: fb }));
  }

  return cors(json({ error: "unknown admin route" }, 404));
}

// Firebase Admin: disable / re-enable a user
//
// Identity Toolkit needs a real OAuth access token (not the custom-token JWT), so
// the service-account key is exchanged for one. Returns a STRING describing the
// outcome instead of throwing: a block must still be recorded even if this leg
// fails, and the caller needs to see that it did.
async function setFirebaseUserDisabled(uid, disabled, env) {
  try {
    const token = await getAccessToken(env);
    const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:update", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ localId: uid, disableUser: disabled }),
    });
    const txt = await res.text();
    if (!res.ok) {
      // USER_NOT_FOUND is expected and harmless: the account has never actually
      // signed in, so there is no Firebase user to disable yet. It will be created
      // on first sign-in, which the approval gate will refuse anyway.
      if (txt.includes("USER_NOT_FOUND")) return "no firebase user yet (nothing to disable)";
      return `failed: http ${res.status} ${txt.slice(0, 180)}`;
    }
    return disabled ? "firebase user disabled" : "firebase user enabled";
  } catch (e) {
    return "failed: " + (e && e.message);
  }
}

async function getAccessToken(env) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: env.FIREBASE_SA_EMAIL,
    scope: "https://www.googleapis.com/auth/identitytoolkit",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64url(JSON.stringify(claims))}`;
  const key = await importPrivateKey(env.FIREBASE_SA_PRIVATE_KEY);
  const sig = await crypto.subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, key, enc(unsigned));
  const assertion = `${unsigned}.${b64urlBytes(new Uint8Array(sig))}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${encodeURIComponent(assertion)}`,
  });
  if (!res.ok) throw new Error("token exchange http " + res.status);
  const j = await res.json();
  if (!j.access_token) throw new Error("no access_token");
  return j.access_token;
}

// Enrolment gate
//
// Whether a NEW account may be recorded at all. Deliberately stored in KV rather
// than as a secret, so it can be flipped with one admin call instead of a
// redeploy — "stop letting people in, I'm near my quota" has to be instant.
async function enrolmentAllows(env) {
  let cfg;
  try { cfg = await env.USERS.get(enrolKey(), { type: "json" }); } catch { cfg = null; }
  if (cfg && cfg.open === false) {
    return { ok: false, cause: "closed", reason: "not accepting new accounts right now" };
  }
  let day;
  try { day = await env.USERS.get(newAcctKey(), { type: "json" }); } catch { day = null; }
  const n = (day && day.count) || 0;
  if (n >= MAX_NEW_ACCOUNTS_PER_DAY) {
    return { ok: false, cause: "full", reason: "new accounts are full for today" };
  }
  return { ok: true };
}

// Turned-away sign-ins, counted in ONE key per day rather than a record each.
//
// A closed gate refuses a stranger without writing a record — that is the whole
// point of it, because the record is the cost a flood would exploit. The side
// effect was that the refusal left NO trace anywhere: someone signs in, gets
// told no, and the roster looks exactly as it did before, so the owner cannot
// tell an unwanted stranger from a person waiting to be let in. Observed as
// "the approval UI didn't show it as queued".
//
// A single counter keyed by day costs one write per refusal regardless of how
// many accounts are behind it, and expires on its own. It answers "did anyone
// try today?" without storing who, which is also the privacy-preserving
// answer, since a turned-away identity is someone with no relationship to this
// service and no record of them should be kept.
// The CAUSE is recorded alongside the count, because the two are fixed by
// opposite actions and the tile could not tell them apart: "closed" means open
// enrolment, "full" means today's intake of MAX_NEW_ACCOUNTS_PER_DAY is used up
// and opening enrolment will change nothing. Guessing between them cost a round
// of testing.
async function bumpRefused(env, cause) {
  const key = refusedKey();
  let day;
  try { day = await env.USERS.get(key, { type: "json" }); } catch { day = null; }
  const d = day || {};
  await env.USERS.put(key, JSON.stringify({
    count: (d.count || 0) + 1,
    closed: (d.closed || 0) + (cause === "closed" ? 1 : 0),
    full: (d.full || 0) + (cause === "full" ? 1 : 0),
  }), { expirationTtl: 172800 });
}

async function bumpNewAccounts(env) {
  const key = newAcctKey();
  let day;
  try { day = await env.USERS.get(key, { type: "json" }); } catch { day = null; }
  await env.USERS.put(key, JSON.stringify({ count: ((day && day.count) || 0) + 1 }), {
    expirationTtl: 172800,
  });
}

// Give an intake slot BACK when its record is deleted.
//
// The counter bounds how many new accounts may be RECORDED in a day, so a record
// that no longer exists must not keep occupying a slot. Without this, erasing an
// account and signing in again burned a second slot every time, so testing the
// approval pipeline (delete, re-sign-in, repeat) silently walked the day's intake
// to zero, after which every genuinely new account was refused with "full for
// today" and never queued for approval.
//
// Floored at zero, and only ever called from the owner-authenticated forget
// path, so it cannot be used to mine extra intake.
async function decNewAccounts(env) {
  const key = newAcctKey();
  let day;
  try { day = await env.USERS.get(key, { type: "json" }); } catch { day = null; }
  const next = Math.max(0, ((day && day.count) || 0) - 1);
  await env.USERS.put(key, JSON.stringify({ count: next }), { expirationTtl: 172800 });
}

// KV records
const recKey = (uid) => `u:${uid}`;
const globalKey = () => `g:${dayKey()}`;
const newAcctKey = () => `n:${dayKey()}`;
const refusedKey = () => `r:${dayKey()}`;
/// SAPISID-hash → the identity this account was FIRST seen as. Pins the uid so a
/// change in what YouTube reports cannot orphan a backup. See the identity anchor.
const aliasKey = (sapHash) => `a:${sapHash}`;
const enrolKey = () => `cfg:enrolment`;
function dayKey() { return new Date().toISOString().slice(0, 10); }
/// The day a record was CREATED, in the same shape as [dayKey]. Derived from
/// firstSeenMs, which is written once and never touched again.
function firstSeenDay(rec) {
  const ms = rec && rec.firstSeenMs;
  if (!ms) return null;
  try { return new Date(ms).toISOString().slice(0, 10); } catch { return null; }
}

/// Tally statuses across the whole roster.
///
/// Walks KV, so it is for ADMIN paths only — never the auth hot path. Pagination
/// is followed so a second page can't make a full roster look small.
async function countByStatus(env) {
  const out = { approved: 0, pending: 0, blocked: 0 };
  let cursor;
  do {
    const page = await env.USERS.list({ prefix: "u:", cursor });
    for (const k of page.keys) {
      const rec = await getRecByKey(env, k.name);
      if (rec && out[rec.status] !== undefined) out[rec.status]++;
    }
    cursor = page.list_complete ? null : page.cursor;
  } while (cursor);
  return out;
}

async function getRec(env, uid) { return getRecByKey(env, recKey(uid)); }
async function getRecByKey(env, key) {
  try { return await env.USERS.get(key, { type: "json" }); } catch { return null; }
}
async function putRec(env, rec) {
  await env.USERS.put(recKey(rec.uid), JSON.stringify(rec));
}

// Global daily mint counter.
//
// Persisted only every GLOBAL_WRITE_EVERY mints because the KV free tier allows
// ~1,000 writes/day in TOTAL and per-user records already consume some of that.
// The consequence is honest: the counter lags by up to GLOBAL_WRITE_EVERY-1, so
// the effective cap is approximate. It is a budget guard, not an accountant.
async function allowGlobalMint(env) {
  const key = globalKey();
  let g;
  try { g = await env.USERS.get(key, { type: "json" }); } catch { g = null; }
  const count = (g && g.count) || 0;
  if (count >= MAX_MINTS_PER_DAY) return false;
  const pending = ((g && g.pending) || 0) + 1;
  if (pending >= GLOBAL_WRITE_EVERY) {
    await env.USERS.put(key, JSON.stringify({ count: count + pending, pending: 0 }), {
      expirationTtl: 172800, // two days — yesterday's counter is not worth keeping
    });
  } else {
    await env.USERS.put(key, JSON.stringify({ count, pending }), { expirationTtl: 172800 });
  }
  return true;
}

// Pre-verify limiter (Cache API, no KV writes)
// Approximate by design. See MAX_VERIFY_PER_COOKIE_PER_DAY.
async function allowVerify(cookieKey) {
  try {
    const cache = caches.default;
    const url = `https://auvy-ratelimit.invalid/${dayKey()}/${cookieKey}`;
    const hit = await cache.match(url);
    let n = 0;
    if (hit) n = parseInt(await hit.text(), 10) || 0;
    if (n >= MAX_VERIFY_PER_COOKIE_PER_DAY) return false;
    await cache.put(
      url,
      new Response(String(n + 1), { headers: { "Cache-Control": "max-age=86400" } })
    );
    return true;
  } catch {
    return true; // limiter unavailable → fail OPEN; the approval gate still holds
  }
}

function ownerSet(env) {
  return new Set(
    (env.OWNER_IDENTITIES || "")
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean)
  );
}

/// Failed-login limiter for /admin/login. Hourly bucket, per IP.
const MAX_LOGINS_PER_HOUR = 10;
async function allowLogin(ip) {
  try {
    const cache = caches.default;
    const hour = Math.floor(Date.now() / 3600000);
    const url = `https://auvy-login.invalid/${hour}/${encodeURIComponent(ip)}`;
    const hit = await cache.match(url);
    let n = 0;
    if (hit) n = parseInt(await hit.text(), 10) || 0;
    if (n >= MAX_LOGINS_PER_HOUR) return false;
    await cache.put(
      url,
      new Response(String(n + 1), { headers: { "Cache-Control": "max-age=3600" } })
    );
    return true;
  } catch {
    return true; // limiter unavailable → fail open; the password still gates
  }
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/// One authenticated InnerTube POST. Shared so `account_menu` and its
/// `accounts_list` fallback cannot drift apart in headers or client context.
async function innertube(
  cookie,
  endpoint,
  clientName = "WEB_REMIX",
  clientVersion = "1.20240101.01.00"
) {
  const auth = await authorizationHeader(cookie, ORIGIN);
  if (!auth) throw new Error("no SAPISID in cookie");
  const res = await fetch(
    `${ORIGIN}/youtubei/v1/${endpoint}?key=${INNERTUBE_KEY}&prettyPrint=false`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Cookie: cookie,
        Authorization: auth,
        Origin: ORIGIN,
        "X-Origin": ORIGIN,
        "X-Goog-AuthUser": "0",
        "User-Agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36",
      },
      body: JSON.stringify({
        context: {
          client: { clientName, clientVersion },
        },
      }),
    }
  );
  if (!res.ok) throw new Error(`${endpoint} http ${res.status}`);
  return res.json();
}

/// The signed-in account id embedded in youtube.com's own page config.
///
/// `DATASYNC_ID` (and `DELEGATED_SESSION_ID`) are rendered into ytcfg for a
/// logged-in visitor even when the InnerTube endpoints refuse to name the account.
async function ytcfgIdentity(cookie) {
  const auth = await authorizationHeader(cookie, ORIGIN);
  const res = await fetch(`${ORIGIN}/`, {
    headers: {
      Cookie: cookie,
      ...(auth ? { Authorization: auth } : {}),
      "User-Agent":
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36",
    },
  });
  if (!res.ok) throw new Error("ytcfg http " + res.status);
  const html = await res.text();
  for (const key of ["DATASYNC_ID", "DELEGATED_SESSION_ID"]) {
    const m = html.match(new RegExp(`"${key}"\\s*:\\s*"([^"]+)"`));
    if (m && m[1]) {
      const v = m[1].replace(/\|+$/, "").trim();
      if (v) return v;
    }
  }
  return null;
}

/// The account SWITCHER list — a plain authenticated GET on youtube.com, not an
/// InnerTube POST. Its payload is prefixed with `)]}'` anti-JSON-hijacking junk
/// that must be stripped before parsing.
async function accountSwitcher(cookie) {
  const auth = await authorizationHeader(cookie, ORIGIN);
  if (!auth) throw new Error("no SAPISID in cookie");
  const res = await fetch(`${ORIGIN}/getAccountSwitcherEndpoint`, {
    headers: {
      Cookie: cookie,
      Authorization: auth,
      Origin: ORIGIN,
      "X-Origin": ORIGIN,
      "X-Goog-AuthUser": "0",
      "User-Agent":
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36",
    },
  });
  if (!res.ok) throw new Error("switcher http " + res.status);
  const text = await res.text();
  const start = text.indexOf("{");
  if (start < 0) throw new Error("switcher: no json");
  return JSON.parse(text.slice(start));
}

/// `accounts_list` → the signed-in account, using the same precedence as
/// [extractIdentity] (email || handle || name) so the uid, and therefore every
/// existing backup key — is unchanged whichever endpoint answered.
function extractFromAccountsList(data) {
  let best = null;
  const visit = (node) => {
    if (best || node == null) return;
    if (Array.isArray(node)) {
      for (const e of node) visit(e);
      return;
    }
    if (typeof node !== "object") return;
    const item = node.accountItem;
    if (item && typeof item === "object") {
      const txt = (o) => {
        if (!o) return "";
        if (Array.isArray(o.runs)) return o.runs.map((r) => (r && r.text) || "").join("");
        if (typeof o.simpleText === "string") return o.simpleText;
        return "";
      };
      // Only the account actually in use — a multi-account jar lists several, and
      // picking the wrong one would silently hand this device someone else's uid.
      if (item.isSelected === false) return;
      const v = (
        txt(item.email) ||
        txt(item.channelHandle) ||
        txt(item.accountName)
      ).trim();
      if (v) {
        best = v;
        return;
      }
    }
    for (const k of Object.keys(node)) visit(node[k]);
  };
  visit(data);
  return best;
}

// YouTube identity verification
async function resolveIdentity(cookie) {
  const auth = await authorizationHeader(cookie, ORIGIN);
  if (!auth) throw new Error("no SAPISID in cookie");
  const res = await fetch(
    `${ORIGIN}/youtubei/v1/account/account_menu?key=${INNERTUBE_KEY}&prettyPrint=false`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Cookie": cookie,
        "Authorization": auth,
        "Origin": ORIGIN,
        "X-Origin": ORIGIN,
        "X-Goog-AuthUser": "0",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36",
      },
      body: JSON.stringify({
        context: { client: { clientName: "WEB_REMIX", clientVersion: "1.20240101.01.00" } },
      }),
    }
  );
  // A failing primary call must NOT abort the whole resolution.
  //
  // This used to `throw` on any non-200, which meant a single 403 from WEB_REMIX
  // skipped every fallback below — the WEB client, accounts_list, the switcher,
  // datasyncId, ytcfg and the hashed-SAPISID last resort, and the caller got a
  // bare "verify failed: account_menu http 403". That is precisely the failure
  // that kept accounts out: the routes that would have identified them were
  // never tried. YouTube 403s this endpoint intermittently per client, so the
  // error is recorded and resolution continues.
  let primaryError = null;
  let data = null;
  if (res.ok) {
    try {
      data = await res.json();
    } catch (e) {
      primaryError = "account_menu body unreadable";
    }
  } else {
    // Cookie NAMES only — never values, which are live credentials.
    const names = cookie
      .split(";")
      .map((c) => c.split("=")[0].trim())
      .filter(Boolean);
    const interesting = names.filter((n) => /SID|SSID|LOGIN_INFO|SECURE/i.test(n));
    console.log(
      `account_menu ${res.status} — ${interesting.length} auth cookies of ` +
        `${names.length}, falling through to the other routes`
    );
    primaryError = `account_menu http ${res.status}`;
  }
  const identity = data ? extractIdentity(data) : null;
  if (!identity && data) {
    // Reached YouTube fine but found no account header. This is NOT an auth
    // signature problem (that would be a 403) — a 200 with no account block is
    // what YouTube returns for a request it treats as ANONYMOUS, i.e. the session
    // cookies never arrived. So log which cookies we actually sent, plus the top
    // level keys of the response, which is what distinguishes "anonymous answer"
    // from "renderer moved/renamed".
    //
    // Names only — the values are live credentials.
    const names = cookie
      .split(";")
      .map((c) => c.split("=")[0].trim())
      .filter(Boolean);
    const interesting = names.filter((n) => /SID|SSID|LOGIN_INFO|SECURE/i.test(n));
    // Deliberately terse now. The verbose version (cookie names, response keys,
    // renderer inventory, signInEndpoint presence) is what identified this as
    // "signed in, but this account has no channel" — keep the shape of it, drop
    // the volume. `logged_in` is the one field worth keeping: it separates a
    // genuine auth failure from an account that simply has nothing to report.
    const loggedIn = JSON.stringify(data.responseContext || {}).includes(
      '"logged_in","value":"1"'
    );
    console.log(
      `account_menu 200, no account header (logged_in=${loggedIn}, ` +
        `${interesting.length} auth cookies) — trying fallbacks`
    );
  }
  // FALLBACK: accounts_list
  //
  // `account_menu` on WEB_REMIX no longer returns an `activeAccountHeaderRenderer`
  // at all. Proven, not assumed: the response is 200 with `signInEndpoint: false`
  // (so the session IS signed in) and contains only multiPageMenu /
  // multiPageMenuSection / compactLink renderers. No cookie or SAPISIDHASH change
  // could ever have fixed that, which is why two rounds of both failed.
  //
  // `accounts_list` still carries the account itself, so ask it when the menu
  // yields nothing.
  if (!identity) {
    try {
      // The plain WEB client first: youtube.com's own account menu still carries
      // the header that WEB_REMIX has stopped returning. accounts_list second,
      // which answered 400 on WEB_REMIX and may want the WEB context too.
      const alt = await innertube(
          cookie, "account/account_menu", "WEB", "2.20240101.00.00");
      let found = extractIdentity(alt) || extractFromAccountsList(alt);
      if (!found) {
        try {
          const list = await innertube(
              cookie, "account/accounts_list", "WEB", "2.20240101.00.00");
          found = extractIdentity(list) || extractFromAccountsList(list);
        } catch (e) {
          console.log("accounts_list(WEB) failed: " + (e && e.message));
        }
      }
      // Last resort: the account SWITCHER. This is the endpoint youtube.com itself
      // uses to render the "switch account" list, so it returns accountItem entries
      // (name / email / isSelected) even when the menu header does not.
      //
      // NOTE: on the account that exposed this bug, switcher and accounts_list both
      // answer 400 and every menu comes back with messageRenderer/
      // messageSubtextRenderer instead of an account block — the signature of a
      // Google account with NO YOUTUBE CHANNEL. See the datasyncId fallback below,
      // which is what actually rescues those accounts.
      if (!found) {
        try {
          const sw = await accountSwitcher(cookie);
          found = extractFromAccountsList(sw) || extractIdentity(sw);
        } catch (e) {
          console.log("account switcher failed: " + (e && e.message));
        }
      }
      if (found) {
        console.log("identity recovered via accounts_list");
        return { identity: found };
      }
      console.log("accounts_list had no identity either — trying datasyncId");
    } catch (e) {
      console.log("accounts_list failed: " + (e && e.message));
    }
  }

  // FINAL FALLBACK: datasyncId
  //
  // A Google account with no YouTube channel has no name, no @handle and no
  // account header ANYWHERE — every menu answers with messageRenderer instead.
  // Proven on this device: account_menu (WEB_REMIX and WEB) return 200 with
  // `signInEndpoint: false` and no account block, while accounts_list and the
  // account switcher both answer 400.
  //
  // `datasyncId` is carried in the responseContext of every AUTHENTICATED
  // InnerTube response and is stable per Google account, so it identifies exactly
  // the thing we need to identify. It sits LAST in the precedence, so any account
  // that can still produce an email or @handle keeps the identity, and therefore
  // the uid, and therefore its existing backup — completely unchanged.
  if (!identity) {
    const ds = data ? datasyncIdOf(data) : null;
    if (ds) {
      console.log("identity recovered via datasyncId (account has no channel)");
      return { identity: `ds:${ds}` };
    }
    // The homepage's ytcfg carries DATASYNC_ID / DELEGATED_SESSION_ID even when
    // the InnerTube responseContext does not.
    try {
      const fromCfg = await ytcfgIdentity(cookie);
      if (fromCfg) {
        console.log("identity recovered via ytcfg DATASYNC_ID");
        return { identity: `ds:${fromCfg}` };
      }
    } catch (e) {
      console.log("ytcfg lookup failed: " + (e && e.message));
    }

    // Guaranteed last resort
    //
    // A logged-in Google account with no YouTube channel exposes NO name, handle,
    // email, account header or datasyncId anywhere we can reach (all proven on
    // this device: account_menu 200 with `logged_in: 1` but only messageRenderer;
    // accounts_list and the account switcher both 400). Refusing such accounts
    // would mean Auvy simply does not work for anyone without a YouTube channel.
    //
    // SAPISID is stable per Google account, so a keyed hash of it is a usable
    // identity. It never leaves this Worker — only the derived uid does.
    //
    // TRADE-OFF, ACCEPTED: SAPISID changes if the user changes their Google
    // password, which would orphan that account's backup. It is LAST in the
    // precedence, so it only ever applies to accounts that have no stabler
    // identifier and therefore no existing backup to orphan.
    const sap = getSapisid(cookie);
    if (sap) {
      console.log("identity via hashed SAPISID (no channel, no datasyncId)");
      return { identity: `sap:${await sha256Hex(sap)}` };
    }

    console.log("no identity by ANY route — account cannot be verified");
    // Surface WHY when the primary call is the reason nothing else had anything
    // to work with, rather than the generic "could not resolve identity".
    if (primaryError) throw new Error(primaryError);
  }

  return { identity };
}

/// `responseContext.mainAppWebResponseContext.datasyncId`, trimmed of the trailing
/// `||` padding YouTube appends. Searched recursively because the context is nested
/// differently across clients.
function datasyncIdOf(data) {
  let found = null;
  const visit = (node) => {
    if (found || node == null) return;
    if (Array.isArray(node)) {
      for (const e of node) visit(e);
      return;
    }
    if (typeof node !== "object") return;
    if (typeof node.datasyncId === "string" && node.datasyncId.trim()) {
      found = node.datasyncId.replace(/\|+$/, "").trim();
      return;
    }
    for (const k of Object.keys(node)) visit(node[k]);
  };
  visit(data);
  return found;
}

// account_menu → account identity, MIRRORING the app's
// InnerTubeParser.parseAccountMenu so the Worker's uid == the app's existing
// backup key. Find activeAccountHeaderRenderer (recursively, same as the app),
// read accountName / email / channelHandle via .runs, then identity =
// email || handle || name (the exact precedence the app feeds into
// _backupKeyFor). Many accounts expose only channelHandle (no email), so this
// must not require an email.
function extractIdentity(data) {
  let header = null;
  const find = (node) => {
    if (header || node == null) return;
    if (Array.isArray(node)) { for (const e of node) find(e); return; }
    if (typeof node !== "object") return;
    const h = node.activeAccountHeaderRenderer;
    if (h && typeof h === "object") { header = h; return; }
    for (const k of Object.keys(node)) find(node[k]);
  };
  find(data);
  if (!header) return null;
  const txt = (o) => {
    if (!o) return "";
    if (Array.isArray(o.runs)) return o.runs.map((r) => (r && r.text) || "").join("");
    if (typeof o.simpleText === "string") return o.simpleText;
    return "";
  };
  const name = txt(header.accountName);
  const email = txt(header.email);
  const handle = txt(header.channelHandle);
  const identity = (email || handle || name || "").trim();
  return identity || null;
}

function cookieValue(cookie, name) {
  const m = cookie.match(
    new RegExp(`(?:^|;\\s*)${name.replace(/[-]/g, "\\-")}=([^;]+)`)
  );
  return m ? m[1] : null;
}

// Used for the rate-limit key only — any stable per-session value will do there.
function getSapisid(cookie) {
  return (
    cookieValue(cookie, "SAPISID") ||
    cookieValue(cookie, "__Secure-3PAPISID") ||
    cookieValue(cookie, "__Secure-1PAPISID")
  );
}

/// Authorization header for an authenticated InnerTube call:
/// `SAPISIDHASH <ts>_<sha1(ts + " " + value + " " + origin)>`.
///
/// REVERTED 2026-08-05 — DO NOT "CORRECT" THIS AGAIN.
///
/// I replaced this with per-cookie labels (`SAPISID` → SAPISIDHASH,
/// `__Secure-1PAPISID` → SAPISID1PHASH, `__Secure-3PAPISID` → SAPISID3PHASH) on the
/// theory that hashing a 3P cookie under the plain label was a wrong signature.
/// The KV roster disproved it: the owner had **14 successful verifications** under
/// this original scheme, and sign-in broke for EVERY account — owner included —
/// immediately after the labelled version was deployed.
///
/// `account_menu` with `Origin: https://www.youtube.com` accepts `SAPISIDHASH`
/// computed from whichever *APISID value is available; that is the standard recipe
/// every YouTube client uses. The labelled variants belong to other Google
/// endpoints and are rejected here.
async function authorizationHeader(cookie, origin) {
  const value = getSapisid(cookie);
  if (!value) return null;
  const ts = Math.floor(Date.now() / 1000);
  return `SAPISIDHASH ${ts}_${await sha1Hex(`${ts} ${value} ${origin}`)}`;
}

// Firebase custom token (RS256 JWT signed with the service-account key)
async function mintCustomToken(uid, env) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: env.FIREBASE_SA_EMAIL,
    sub: env.FIREBASE_SA_EMAIL,
    aud: "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
    iat: now,
    exp: now + 3600,
    uid, // <= the custom-token uid the Firebase session gets
  };
  const header = { alg: "RS256", typ: "JWT" };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const key = await importPrivateKey(env.FIREBASE_SA_PRIVATE_KEY);
  const sig = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    new TextEncoder().encode(unsigned)
  );
  return `${unsigned}.${b64urlBytes(new Uint8Array(sig))}`;
}

async function importPrivateKey(pem) {
  const clean = pem.replace(/\\n/g, "\n")
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(clean), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
}

// crypto helpers
async function sha256Hex(s) { return hex(await crypto.subtle.digest("SHA-256", enc(s))); }
async function sha1Hex(s) { return hex(await crypto.subtle.digest("SHA-1", enc(s))); }
async function hmacBase64(secret, msg) {
  const k = await crypto.subtle.importKey("raw", enc(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, enc(msg));
  return b64urlBytes(new Uint8Array(sig));
}
function enc(s) { return new TextEncoder().encode(s); }
function hex(buf) { return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join(""); }
function b64url(str) { return b64urlBytes(new TextEncoder().encode(str)); }
function b64urlBytes(bytes) {
  let bin = ""; for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// http helpers
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
}
function cors(res) {
  res.headers.set("Access-Control-Allow-Origin", "*");
  res.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.headers.set("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token");

  // Baseline security headers, set at the ONE choke point
  //
  // Every response in this Worker goes through cors(), so this is the only place
  // they need to exist. Cheap, and two of them are not theoretical: /admin serves
  // real HTML to a browser.
  //
  //  nosniff        — stop a browser re-interpreting a JSON body as HTML/JS.
  //  no-referrer    — never send this URL onward. The admin dashboard's path
  //                   should not appear in any third party's referrer log.
  //  DENY (frames)  — the admin page fires token-checked actions from buttons;
  //                   framing it elsewhere is the setup for a clickjack.
  //  HSTS           — workers.dev is HTTPS-only already, so this is belt and
  //                   braces rather than the thing that protects the transport.
  //                   Deliberately NO `preload`: that is a one-way submission to
  //                   a browser-shipped list and is not reversible on a whim.
  res.headers.set("X-Content-Type-Options", "nosniff");
  res.headers.set("Referrer-Policy", "no-referrer");
  res.headers.set("X-Frame-Options", "DENY");
  res.headers.set("Strict-Transport-Security", "max-age=31536000");

  // ACAO STAYS `*` ON PURPOSE, AND IS NOT A CSRF HOLE HERE.
  //
  // Admin auth is a CUSTOM HEADER (X-Admin-Token), which a browser never
  // attaches on its own — there is no cookie or Basic credential for a hostile
  // page to ride. A cross-origin request from such a page therefore arrives with
  // no token and is rejected like any other anonymous caller. Narrowing this
  // would break the app's own requests, which come from a WebView/native client
  // with a null or opaque origin, and buy nothing.
  return res;
}

/**
 * ── AUDIOBOOKS (Internet Archive, LibriVox collection) ───────────────────────
 *
 * Public-domain audiobooks. The catalogue is IDENTICAL for every user — nobody
 * gets a personalised "most-downloaded audiobooks" — so every device fetching it
 * directly sends the same bytes many times. Cached here, thousands of listeners
 * cost archive.org a handful of requests.
 *
 * THIS PROXIED LIBRIVOX'S OWN API FIRST, AND THAT WAS THE WRONG SOURCE.
 * LibriVox can only sort by catalogue date (so browse showed whatever a
 * volunteer finished last week, not Pride and Prejudice) and can only match
 * title PREFIXES (so "monte cristo" found nothing). The Archive hosts the same
 * recordings, ranks by download count, and does real phrase matching. Measured:
 * a 40-book LibriVox page was 77,118 bytes; the equivalent 20 rows here are
 * 2,824.
 *
 * WHY THIS IS NOT THE /itunes MISTAKE (see the note where that route is
 * absent). Apple throttled by SOURCE IP, so pooling every user behind one
 * Cloudflare egress IP made it worse — 429 after about five requests. Two things
 * differ: these responses are long-lived and shared, so the origin sees a trickle
 * rather than a flood; and the client keeps a direct path, so if archive.org ever
 * refuses this IP the app degrades instead of breaking.
 */

/**
 * THE PARAMETER ALLOWLIST IS THE WHOLE SECURITY MODEL.
 *
 * The client sends a full query string that this Worker appends to a URL it then
 * fetches. Without a check that is an open proxy on archive.org — so only the
 * parameters the app actually sends are forwarded, and everything else is
 * dropped rather than passed through.
 */
const AUDIOBOOK_PARAMS = new Set([
  "q", "fl[]", "sort[]", "rows", "page", "output",
]);

async function handleAudiobooks(request, env, url) {
  if (request.method !== "GET") return cors(json({ error: "GET only" }, 405));

  const raw = url.searchParams.get("q") || "";
  if (!raw || raw.length > 600) return cors(json({ error: "bad query" }, 400));

  // The client sends the whole advancedsearch query string in `q`. Re-parse it
  // and rebuild from the allowlist, so nothing unexpected reaches the origin.
  const incoming = new URLSearchParams(raw);
  const out = new URLSearchParams();
  for (const [k, v] of incoming) {
    if (!AUDIOBOOK_PARAMS.has(k)) continue;
    if (v.length > 400) continue;
    out.append(k, v);
  }
  if (!out.has("q")) return cors(json({ error: "missing q" }, 400));
  // Only ever JSON, whatever the caller asked for.
  out.set("output", "json");

  const canonical = out.toString();
  const cache = caches.default;
  // KEYED ON THE REBUILT QUERY, not the caller's raw string. A raw-URL key on
  // a route taking free-form input is how a public endpoint becomes a drainable
  // origin quota: each distinct spelling would be its own entry and its own
  // upstream call. The client lower-cases search terms for the same reason.
  const cacheKey = new Request(
    `${url.origin}/audiobooks?${canonical}`,
    { method: "GET" },
  );
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  try {
    const res = await fetch(
      `https://archive.org/advancedsearch.php?${canonical}`,
      { headers: { "User-Agent": "Auvy/1.0", Accept: "application/json" } },
    );
    if (!res.ok) {
      // Not cached: an upstream failure is an outage, not an answer, and the app
      // falls back to archive.org directly.
      return cors(json({ error: `archive ${res.status}` }, 502));
    }
    const body = await res.text();
    const outRes = cors(new Response(body, {
      status: 200,
      headers: { "Content-Type": "application/json; charset=utf-8" },
    }));
    // The public domain does not change quickly, and a download ranking moves
    // even more slowly. Six hours is what keeps origin load near zero.
    outRes.headers.set("Cache-Control", "public, max-age=21600");
    try { await cache.put(cacheKey, outRes.clone()); } catch {}
    return outRes;
  } catch (e) {
    return cors(json({ error: "archive unreachable" }, 502));
  }
}

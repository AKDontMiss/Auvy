package com.auvy.app

import android.accounts.AccountManager
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast

/**
 * Native YouTube sign-in screen (plain android.webkit.WebView — no plugin
 * layers between Google's login JS and the page).
 *
 * Google rejects sign-ins from browser profiles it doesn't like, navigating
 * to accounts.google.com/v3/signin/rejected right after the email step (the
 * logcat trace made this visible). What it accepts shifts over time — the
 * the older Chrome/103 desktop UA now gets rejected as an
 * OUTDATED browser. Strategy here:
 *
 *  1. First attempt uses the device's REAL WebView UA with only the WebView
 *     markers ("; wv" and "Version/4.0") stripped — i.e. genuine, current
 *     mobile Chrome whose claimed version matches the actual engine exactly.
 *     Nothing outdated, nothing inconsistent to detect.
 *  2. If Google still navigates to /signin/rejected, the screen AUTOMATICALLY
 *     clears the jar, switches to the next profile (current Firefox mobile,
 *     then desktop Chrome 103) and reloads — three shots per attempt, no
 *     manual retry loop for the user.
 *
 * Finishes with RESULT_OK the moment music.youtube.com is reached carrying a
 * real session cookie (SID / __Secure-*PSID); Dart then imports the cookies
 * from the process-wide CookieManager (HttpOnly included).
 */
class LoginActivity : Activity() {
    companion object {
        private const val TAG = "AuvyLogin"
        // Email of the device account the user picked in the NATIVE Google
        // account chooser (see SessionAuthService) — pre-fills the identifier
        // step so the web flow starts directly at the password/passkey prompt.
        const val EXTRA_EMAIL_HINT = "email_hint"
        // Returned to Dart on success. See the setResult below.
        const val EXTRA_PICKED_EMAIL = "picked_email"
        private const val CONTINUE_PARAM =
            "continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F"
        private const val LOGIN_URL =
            "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&$CONTINUE_PARAM"
        // When the WebView jar ALREADY holds a Google session (an earlier Auvy
        // sign-in), start at the account chooser: the user just taps their
        // account — no email, no password.
        private const val CHOOSER_URL =
            "https://accounts.google.com/AccountChooser?service=youtube&$CONTINUE_PARAM"
    }

    private lateinit var webView: WebView
    private lateinit var userAgents: List<String>
    private var uaIndex = 0
    private var finished = false
    private var emailHint: String? = null
    private var resumeSession = false
    // The identifier step is auto-completed at most ONCE per attempt, so a
    // bounce back to it (typo'd account, "use another account") stays manual.
    private var identifierAutoAdvanced = false

    private val accountPickRequest = 4712

    /// The identifier-prefilled sign-in URL. The modern Google sign-in IGNORES
    /// `Email=` on ServiceLogin (verified on-device: it still lands on the
    /// empty identifier textbox), but AccountChooser honors it: with a
    /// session for that account it signs straight in, without one it forwards
    /// to the "Welcome <email>" page, i.e. directly to the password/passkey
    /// step with the identifier already set.
    private fun signInUrl(): String {
        val hint = emailHint
        if (hint.isNullOrBlank()) return LOGIN_URL
        val enc = android.net.Uri.encode(hint)
        return "$CHOOSER_URL&Email=$enc"
    }

    /// True when the process-wide cookie jar already carries a Google session
    /// (same names Google uses on youtube.com after the handoff).
    private fun hasGoogleSession(): Boolean {
        val cookie = CookieManager.getInstance()
            .getCookie("https://accounts.google.com") ?: return false
        val names = cookie.split("; ").map { it.substringBefore('=').trim() }
        return names.any { it == "SID" || it == "__Secure-1PSID" || it == "__Secure-3PSID" }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Profile #1: the engine-true UA — the device's real WebView UA minus
        // the WebView markers. Reads as current mobile Chrome at the engine's
        // exact version. Profiles #2/#3 are fallbacks with known history.
        val engineTrue = try {
            WebSettings.getDefaultUserAgent(this)
                .replace("; wv", "")
                .replace("Version/4.0 ", "")
        } catch (_: Exception) {
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
        }
        userAgents = listOf(
            engineTrue,
            "Mozilla/5.0 (Android 14; Mobile; rv:128.0) Gecko/128.0 Firefox/128.0",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36",
        )

        emailHint = intent.getStringExtra(EXTRA_EMAIL_HINT)

        // A surviving Google session in the jar means the chooser can complete
        // the sign-in with a single tap — DON'T wipe it. Only a truly fresh
        // flow starts from a clean jar (Google's rejection verdicts persist in
        // cookies, so fresh attempts must not inherit a flagged state).
        resumeSession = hasGoogleSession()
        if (!resumeSession) clearJar()

        webView = WebView(this)
        setContentView(webView)

        webView.webViewClient = object : WebViewClient() {
            override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
                // SECURITY: log path only — the query string carries `Email=<user
                // email>` on the sign-in URLs (PII). Native Log.* is NOT stripped
                // in release (minify off), so a full-URL log would leak the email
                // into release logcat.
                Log.i(TAG, "nav[$uaIndex]: ${url.substringBefore("?")}")
                if (finished) return

                // Google rejected this browser profile → advance to the next
                // one automatically instead of dead-ending the user.
                if (url.contains("accounts.google.com/v3/signin/rejected") &&
                    uaIndex < userAgents.size - 1
                ) {
                    uaIndex++
                    Log.i(TAG, "rejected — switching to UA profile #$uaIndex")
                    Toast.makeText(
                        this@LoginActivity,
                        "Google refused that browser profile — retrying with another…",
                        Toast.LENGTH_SHORT
                    ).show()
                    clearJar()
                    identifierAutoAdvanced = false // fresh attempt → advance again
                    webView.settings.userAgentString = userAgents[uaIndex]
                    webView.loadUrl(signInUrl())
                    return
                }

                maybeFinish(url)
            }

            // Some flows park on www.youtube.com and never navigate again —
            // re-check when the page finishes loading so a cookie that landed
            // a beat after the navigation event still completes the sign-in.
            override fun onPageFinished(view: WebView, url: String) {
                maybeAutoAdvanceIdentifier(url)
                if (!finished) maybeFinish(url)
            }
        }

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = userAgents[uaIndex]
            // SECURITY: this WebView holds the user's live Google session, and
            // it never needs the local filesystem.
            //
            // allowFileAccess defaults to TRUE below API 30, and minSdk here
            // is 26, so on Android 8 to 10 this was on. The Discord WebView was
            // hardened for exactly this reason (see PresenceLoginActivity); this
            // one is the higher-value target of the two and had been missed.
            allowFileAccess = false
            allowContentAccess = false
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = false
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = false
        }
        // The accounts.google.com ↔ youtube.com handoff sets SameSite=None
        // cookies; make sure cross-site writes are never silently dropped.
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        // Fresh sign-in with no account picked yet → show the SYSTEM device
        // account chooser first (AccountManager — lists the phone's Google
        // accounts; no Play-Services sign-in involved, which resolved
        // instantly-empty on this device and left the hint blank). The web
        // flow loads from onActivityResult with whatever the user picked.
        if (emailHint.isNullOrBlank() && !resumeSession) {
            try {
                @Suppress("DEPRECATION")
                val pick = AccountManager.newChooseAccountIntent(
                    null, null, arrayOf("com.google"), null, null, null, null)
                startActivityForResult(pick, accountPickRequest)
                return
            } catch (e: Exception) {
                Log.e(TAG, "account chooser unavailable: ${e.message}")
            }
        }
        loadStart()
    }

    private fun loadStart() {
        Log.i(TAG, "ua[$uaIndex]: ${userAgents[uaIndex]} resumeSession=$resumeSession hint=${!emailHint.isNullOrBlank()}")
        webView.loadUrl(when {
            !emailHint.isNullOrBlank() -> signInUrl() // identifier step auto-completed for the picked account
            resumeSession -> CHOOSER_URL              // pick among jar-known accounts
            else -> LOGIN_URL
        })
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == accountPickRequest) {
            // CANCEL MEANS CANCEL. This used to fall through to loadStart(),
            // which opened Google's web sign-in anyway, so backing out of the
            // account chooser landed you on a login page you had just declined,
            // with no way out but the back button. Cancelling the chooser is the
            // user saying "not now"; the only correct response is to close and
            // hand them back to Auvy's sign-in screen, where the button is still
            // there if they change their mind.
            if (resultCode != RESULT_OK) {
                Log.i(TAG, "account chooser cancelled — closing sign-in")
                setResult(RESULT_CANCELED)
                finish()
                return
            }
            emailHint = data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
            Log.i(TAG, "device account picked: ${!emailHint.isNullOrBlank()}")
            loadStart()
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    /// Skip the identifier ("Enter your email") step for the account the user
    /// already picked in the NATIVE device chooser. Google carries `Email=`
    /// into v3/signin/identifier but still renders the page waiting for a Next
    /// tap (and doesn't always prefill the field), so fill it ourselves and
    /// click Next, landing directly on the password/passkey step. The retry
    /// loop covers the JS app rendering the input a beat after page-finished.
    private fun maybeAutoAdvanceIdentifier(url: String) {
        val hint = emailHint ?: return
        if (identifierAutoAdvanced || finished) return
        if (!url.startsWith("https://accounts.google.com")) return
        if (!(url.contains("/signin/identifier") || url.contains("/signin/v2/identifier") ||
              url.contains("/ServiceLogin"))) return
        if (hint.contains('\'') || hint.contains('\\')) return // never break the JS string
        identifierAutoAdvanced = true
        Log.i(TAG, "auto-advancing identifier step for hinted account")
        val js = """
            (function() {
              var tries = 0;
              function go() {
                tries++;
                var input = document.querySelector('input[type="email"], input#identifierId, input[name="identifier"]');
                if (!input) { if (tries < 20) setTimeout(go, 250); return; }
                if (!input.value) {
                  input.focus();
                  input.value = '$hint';
                  input.dispatchEvent(new Event('input', {bubbles: true}));
                  input.dispatchEvent(new Event('change', {bubbles: true}));
                }
                var next = document.querySelector('#identifierNext button') || document.getElementById('identifierNext');
                if (next) setTimeout(function() { next.click(); }, 400);
              }
              go();
            })();
        """.trimIndent()
        webView.evaluateJavascript(js, null)
    }

    /// Success check. The signin handoff sets the session cookies on
    /// .youtube.com (shared by every subdomain) and then sometimes parks the
    /// user on WWW.youtube.com instead of continuing to music.youtube.com —
    /// so waiting for a music.youtube.com URL stranded users on the YouTube
    /// home page while ALREADY signed in. Treat ANY youtube.com page as a
    /// checkpoint: the moment the shared session cookie exists, we're done.
    private fun maybeFinish(url: String) {
        val onMusicHost = url.startsWith("https://music.youtube.com") ||
            url.startsWith("https://www.youtube.com") ||
            url.startsWith("https://m.youtube.com")
        if (!onMusicHost) return
        // Query against music.youtube.com — domain cookies (.youtube.com)
        // are returned for it, and it's exactly what the Dart side reads.
        val cookie = CookieManager.getInstance()
            .getCookie("https://music.youtube.com") ?: return
        // Exact-name check: a substring test for "SID=" would also match
        // SAPISID/SSID, which exist BEFORE the real session does.
        val names = cookie.split("; ").map { it.substringBefore('=').trim() }
        if (names.any { it == "SID" || it == "__Secure-1PSID" || it == "__Secure-3PSID" }) {
            finished = true
            Log.i(TAG, "session cookies present — sign-in complete")
            CookieManager.getInstance().flush()
            // Hand back WHICH account was picked in the native chooser.
            // Display-only: the Worker still derives identity from the cookies
            // it verifies itself. This exists because accounts with no YouTube
            // channel resolve to a numeric datasyncId, and a queue full of
            // digits is unreviewable — the owner cannot tell who is asking.
            setResult(RESULT_OK, Intent().putExtra(EXTRA_PICKED_EMAIL, emailHint))
            finish()
        }
    }

    /// Clean slate per profile attempt: Google's rejection verdict persists in
    /// its own cookies, so each new profile must not inherit the last one's
    /// flagged state. Nothing valuable lives here — the durable session is in
    /// Auvy's encrypted store, and a successful login rewrites the jar.
    private fun clearJar() {
        try {
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
        } catch (_: Exception) {}
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (webView.canGoBack()) {
            webView.goBack()
        } else {
            setResult(RESULT_CANCELED)
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }
}

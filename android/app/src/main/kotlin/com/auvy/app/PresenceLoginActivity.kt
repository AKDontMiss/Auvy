package com.auvy.app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast

/**
 * Discord sign-in screen for Rich Presence.
 *
 * The Gateway (which is what actually publishes a "Listening to…" activity on
 * the user's profile) only accepts the account's own client token — the OAuth
 * bearer from the normal Discord login can't authenticate there. So, exactly
 * like the YouTube cookie flow, the user signs in inside a real WebView and
 * the token is read from the page's localStorage once the login completes.
 *
 * Discord's app shell hides `localStorage` from the top frame, but a child
 * iframe still exposes the parent origin's storage — the standard retrieval
 * every Android RPC client (e.g. Kizzy) uses. We poll after each navigation
 * until the token exists (i.e. the user finished logging in).
 */
class PresenceLoginActivity : Activity() {
    companion object {
        private const val TAG = "AuvyPresence"
        const val EXTRA_TOKEN = "discord_token"
        private const val LOGIN_URL = "https://discord.com/login"

        /**
         * SECURITY: the ONLY hosts this WebView is allowed to load, and the only
         * hosts the `AuvyPresence` JS bridge answers to.
         *
         * A `@JavascriptInterface` is reachable by whatever page happens to be
         * loaded. Discord's login page links out (Terms, Privacy, password
         * reset, third-party SSO), so without this gate a navigation off
         * discord.com would leave an attacker-reachable `AuvyPresence.onToken()`
         * able to hand the app a token of its choosing — which the app then
         * stores and authenticates the user's Gateway session with.
         */
        private val ALLOWED_HOSTS = setOf(
            "discord.com",
            "discordapp.com",
            "discord.gg",
            "cdn.discordapp.com",
            "discordapp.net",
        )

        /** True for `discord.com` and any `*.discord.com`-style subdomain. */
        fun isAllowedHost(url: String?): Boolean {
            val host = try {
                Uri.parse(url ?: return false).host?.lowercase() ?: return false
            } catch (_: Exception) {
                return false
            }
            return ALLOWED_HOSTS.any { host == it || host.endsWith(".$it") }
        }
    }

    private lateinit var webView: WebView
    private val main = Handler(Looper.getMainLooper())
    private var finished = false
    private var polls = 0

    private val probeJs = """
        (function() {
          try {
            var i = document.createElement('iframe');
            i.style.display = 'none';
            document.body.appendChild(i);
            var t = i.contentWindow.localStorage.getItem('token');
            document.body.removeChild(i);
            if (t) { AuvyPresence.onToken(t); }
          } catch (e) {}
        })();
    """.trimIndent()

    private val poll = object : Runnable {
        override fun run() {
            if (finished) return
            // Only probe a real Discord page — never inject into a third-party
            // origin the user navigated to.
            if (isAllowedHost(webView.url)) webView.evaluateJavascript(probeJs, null)
            // Poll for up to ~10 minutes (plenty for a login with 2FA).
            if (polls++ < 600) main.postDelayed(this, 1000)
        }
    }

    inner class TokenBridge {
        @JavascriptInterface
        fun onToken(raw: String) {
            if (finished) return
            // localStorage stores the token as a JSON string — strip the quotes.
            val token = raw.trim().removeSurrounding("\"")
            if (token.isEmpty() || token == "null") return
            // SECURITY: a JS bridge is callable by ANY loaded page. Accept a
            // token only while a Discord origin is on screen — this hop back to
            // the main thread is also where the URL can be read safely.
            main.post {
                if (finished) return@post
                if (!isAllowedHost(webView.url)) {
                    Log.w(TAG, "ignored a token offered by a non-Discord origin")
                    return@post
                }
                finished = true
                Log.i(TAG, "token captured (${token.length} chars)")
                setResult(RESULT_OK, Intent().putExtra(EXTRA_TOKEN, token))
                finish()
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled", "AddJavascriptInterface")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        webView = WebView(this)
        setContentView(webView)

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // SECURITY: this WebView never needs the local filesystem. Leaving
            // file access on lets a hostile page reach file:// content (and, on
            // older WebViews, read app-private files) while a JS bridge is
            // attached.
            allowFileAccess = false
            allowContentAccess = false
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = false
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = false
        }
        webView.addJavascriptInterface(TokenBridge(), "AuvyPresence")
        webView.webViewClient = object : WebViewClient() {
            // SECURITY: keep the session pinned to Discord. Anything else the
            // page links to (Terms, help centre, third-party SSO) leaves the
            // WebView entirely, so no foreign origin ever runs alongside the
            // AuvyPresence bridge.
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest
            ): Boolean {
                val url = request.url?.toString()
                if (isAllowedHost(url)) return false
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, request.url))
                } catch (_: Exception) {
                    Toast.makeText(this@PresenceLoginActivity,
                        "Opening that link needs a browser.", Toast.LENGTH_SHORT).show()
                }
                return true
            }

            override fun onPageFinished(view: WebView, url: String) {
                // (Re)start polling — an already signed-in session resolves on
                // the very first probe without showing the login form at all.
                main.removeCallbacks(poll)
                main.post(poll)
            }
        }
        webView.loadUrl(LOGIN_URL)
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
        main.removeCallbacks(poll)
        webView.destroy()
        super.onDestroy()
    }
}

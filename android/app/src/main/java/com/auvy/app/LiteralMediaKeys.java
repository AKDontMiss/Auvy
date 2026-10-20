package com.auvy.app;

import android.content.Intent;
import android.support.v4.media.session.MediaSessionCompat;
import android.util.Log;
import android.view.KeyEvent;

import com.ryanheise.audioservice.AudioService;

import java.lang.ref.WeakReference;
import java.lang.reflect.Field;

/**
 * Makes a hardware PAUSE pause and a hardware PLAY play.
 *
 * audio_service turns PLAY, PAUSE, PLAY_PAUSE and the headset hook all into one
 * "click", which toggles, so a PAUSE from a Bluetooth headset started Auvy
 * whenever it was paused. Some headphones send PAUSE every so often with nothing
 * playing anywhere, and each one played Auvy for a moment. Android's own session
 * behaviour, and other players', is that only PLAY_PAUSE and the hook toggle.
 *
 * This is audio_service's own session callback with that one key path changed:
 * PLAY and PAUSE are answered literally, and every other key and every other
 * command go to audio_service as before. audio_service keeps its session
 * private, so the callback is swapped in by reflection (proguard-rules.pro keeps
 * audio_service's names), after AudioService.init, when the service exists.
 * Written in Java because subclassing an inner class needs `service.super()`.
 */
final class LiteralMediaKeys extends AudioService.MediaSessionCallback {
    private static final String TAG = "LiteralMediaKeys";

    /** The session the callback was last installed on, so it goes in once. */
    private static WeakReference<MediaSessionCompat> installedOn = new WeakReference<>(null);

    private LiteralMediaKeys(AudioService service) {
        service.super();
    }

    @Override
    @SuppressWarnings("deprecation") // getParcelableExtra(String, Class) needs API 33
    public boolean onMediaButtonEvent(Intent mediaButtonEvent) {
        KeyEvent event = mediaButtonEvent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
        if (event != null) {
            int code = event.getKeyCode();
            if (code == KeyEvent.KEYCODE_MEDIA_PAUSE || code == KeyEvent.KEYCODE_MEDIA_PLAY) {
                if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
                    Log.i(TAG, (code == KeyEvent.KEYCODE_MEDIA_PAUSE ? "PAUSE" : "PLAY")
                            + " key: answered as itself, not as a toggle");
                    if (code == KeyEvent.KEYCODE_MEDIA_PAUSE) {
                        onPause();
                    } else {
                        onPlay();
                    }
                }
                return true;
            }
        }
        return super.onMediaButtonEvent(mediaButtonEvent);
    }

    /**
     * Puts this callback on the running service's session. False when there is
     * no service yet, or audio_service's internals changed (then keys stay as
     * audio_service maps them).
     */
    static synchronized boolean install() {
        try {
            Field instanceField = AudioService.class.getDeclaredField("instance");
            instanceField.setAccessible(true);
            AudioService service = (AudioService) instanceField.get(null);
            if (service == null) return false;
            Field sessionField = AudioService.class.getDeclaredField("mediaSession");
            sessionField.setAccessible(true);
            MediaSessionCompat session = (MediaSessionCompat) sessionField.get(service);
            if (session == null) return false;
            if (installedOn.get() == session) return true;
            session.setCallback(new LiteralMediaKeys(service));
            installedOn = new WeakReference<>(session);
            return true;
        } catch (ReflectiveOperationException | RuntimeException e) {
            Log.w(TAG, "media keys left to audio_service: " + e);
            return false;
        }
    }
}

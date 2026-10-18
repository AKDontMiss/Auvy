# Installing Auvy on iPhone

Auvy isn't on the App Store. On iPhone it's installed with **SideStore**, which
signs the app with your own Apple ID.

> Auvy plays from your own YouTube account. It isn't affiliated with, endorsed
> by, or connected to YouTube or Google.

On Android none of this is needed: the app installs and updates itself.

---

## What this involves

SideStore uses the same mechanism Apple provides for developers testing their
own apps. Nothing is jailbroken, no security setting is turned off, and Auvy
runs in the same sandbox as any App Store app.

Two limits of a free Apple ID to know up front:

* **The signature lasts 7 days.** SideStore renews it, by hand or with a
  shortcut that runs by itself (see [Refreshing automatically](#refreshing-automatically)),
  which is why SideStore has to stay installed.
* **Only 3 sideloaded apps at a time**, and SideStore itself is one of them.
  Auvy's home-screen widget counts as one too, so SideStore, Auvy and its widget
  fill all three. If you sideload other apps, SideStore offers to leave app
  extensions out when installing Auvy: say yes and everything works except the
  widget (Siri, the icon's shortcuts and opening links are part of the app).

---

## One-time setup

You need a computer once, for the first step: a Mac, a 64-bit Windows PC,
Linux, or a Chromebook with Linux turned on. A borrowed one is fine. After that
the phone looks after itself.

1. **Install SideStore with iloader.** Follow SideStore's guide at
   <https://docs.sidestore.io>. It has you install **iloader** from
   <https://iloader.app> on the computer, connect the phone with a cable, sign
   in with an Apple ID and choose the stable SideStore; iloader installs
   SideStore and sets it up. That guide is the authority, and the steps change
   between versions. Only get SideStore and iloader from those two sites: they
   ask for your Apple ID, so a lookalike copy is the one way this can really go
   wrong.
2. **Install LocalDevVPN** from the App Store and turn it on whenever SideStore
   installs or refreshes something. It only connects the phone to itself; no
   traffic leaves the phone through it.
3. **Finish on the phone** as SideStore's guide describes: trust your Apple ID
   in **Settings → General → VPN & Device Management**, then open SideStore and
   sign in with the same Apple ID you used in iloader. A free one works.

> **Consider a secondary Apple ID.** Giving any app your Apple account is worth
> limiting, and a separate free account costs nothing. That's general good
> practice, not a comment on SideStore.

---

## Adding Auvy

Scan this with the iPhone's **Camera** and tap the banner that appears:
SideStore opens and adds Auvy's source.

<p><img src="images/sidestore-add-source.png" alt="QR code that opens SideStore and adds Auvy's source" width="200"></p>

Reading this on the iPhone itself? In SideStore, go to **Sources → +** and add
this URL instead:

```
https://github.com/AKDontMiss/Auvy/releases/latest/download/source.json
```

Then install Auvy from that source.

---

## Refreshing automatically

SideStore has to renew Auvy's signature at least once every 7 days, with
LocalDevVPN on and the phone on Wi-Fi. A Shortcuts automation can do it for
you, for example each time you plug the phone in at home. Set it up once.

Auvy walks you through this too: **Settings → Updates → SideStore refresh →
Refresh automatically**, with buttons into the Shortcuts app and a check that
the first run reached Auvy.

**1. Make the shortcut.** In the **Shortcuts** app, tap **+** and add these
actions in this order:

1. **Set VPN**: **Connect**, **LocalDevVPN**.
2. **Wait**: 3 seconds, so the VPN is up.
3. **Refresh All Apps**: SideStore's action. It refreshes SideStore itself too,
   which matters: a SideStore that runs out needs the computer again.
4. **Set VPN**: **Disconnect**, **LocalDevVPN**.
5. **Mark Auvy as Refreshed**: Auvy's action, on iOS 16 and later. It tells
   Auvy the renewal happened, so its reminders count from now, and says how
   long Auvy is now signed for. It runs only if the refresh worked, because a
   failed step stops the shortcut. To keep it quiet, tap the arrow on it and
   turn off **Show When Run**.

Name it, for example, "Refresh SideStore", and run it once by hand to check
that it finishes.

There's no ready-made shortcut to download, because SideStore installs each
app under your own Apple ID. A shortcut made on another phone points at that
phone's SideStore and Auvy, and its two app steps wouldn't find yours.

**2. Let it run by itself.** iOS doesn't let automations be shared, so this
part is always done on your own phone. In the **Automation** tab, tap **+**
(on iOS 15 and 16, **Create Personal Automation**), choose **Charger → Is
Connected**, and pick the shortcut (on iOS 15 and 16, add **Run Shortcut** and
choose it). Let it run without asking: **Run Immediately** on iOS 17 and
later; on iOS 15 and 16, turn off **Ask Before Running** if it's offered. A
second automation at a fixed **Time of Day** is a good backup.

Good to know:

* SideStore refreshes over **Wi-Fi**; its guide calls mobile data unsuitable.
  Plugging in at home usually means Wi-Fi.
* If a refresh takes long, SideStore may ask to be opened to finish. Open it
  once; the next run carries on.
* If SideStore or Auvy is ever reinstalled with a different Apple ID, the
  shortcut shows their steps as unknown actions. Delete those steps and add
  them again.
* Keep Auvy's reminders on as a safety net (**Settings → Updates → SideStore
  refresh**). While the shortcut works, they never come. On iOS 15, which has
  no **Mark Auvy as Refreshed**, tap **I've refreshed** on the reminder, or
  **I refreshed by hand** on that page, after a refresh.

---

## First launch

Sign in with your YouTube (Google) account. New accounts have to be approved
before the app unlocks, so you may see a "needs to be approved" screen. Once
you've been approved, switch back to Auvy and it lets you in without signing in
again. If sign-ups are invite-only, the screen asks for the invite code you were
given instead.

---

## Updating

Open Auvy → **Settings → Updates → Check for updates**.

If there's a new version, the button reads **Open in SideStore**. Tap it, then
confirm the update in SideStore. (SideStore also shows available updates by
itself under **My Apps**.)

**Auvy can't install its own updates on iPhone.** No iOS app can. It's one tap
in Auvy and one in SideStore.

---

## If Auvy stops opening

The 7-day signature expired without being renewed. Open SideStore and refresh
Auvy.

To keep it from happening:

* leave SideStore installed
* let a shortcut refresh it (see [Refreshing automatically](#refreshing-automatically)),
  or open SideStore with LocalDevVPN on and tap **Refresh All** at least once a
  week
* let Auvy remind you: it offers on Home, or turn it on in **Settings →
  Updates → SideStore refresh**. It sends a quiet notification a day before
  the signature runs out and another 3 hours before, even when Auvy is
  closed.

---

## Troubleshooting

**"Unable to verify app" / "Untrusted Developer"**
The signature expired or never finished. Refresh Auvy in SideStore.

**SideStore can't reach the device**
LocalDevVPN is off. Turn it on and try again. If it is on and this started
after an iOS update or a reset, SideStore's pairing file may need replacing;
SideStore's guide explains how (it takes the computer again).

**"Maximum number of apps" when installing**
A free Apple ID can only have 3 sideloaded apps at once. Remove one in SideStore
and try again.

**"Already on the latest version" when you expect an update**
The published version isn't newer than the one you have yet.

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

* **The signature lasts 7 days.** SideStore renews it in the background, which
  is why SideStore has to stay installed.
* **Only 3 sideloaded apps at a time**, and SideStore itself is one of them. If
  you already sideload two other apps, remove one first.

---

## One-time setup

You need a computer for the first step only. After that the phone looks after
itself.

1. **Install SideStore.** Follow the current instructions at
   <https://sidestore.io>. That site is the authority, and the steps change
   between versions. Only get SideStore from there: it asks for your Apple ID,
   so a lookalike copy is the one way this can really go wrong. Use the latest
   version.
2. **Create a pairing file** on the computer and give it to SideStore (the
   SideStore guide walks you through this). It lets SideStore install apps from
   the phone itself, without the computer.
3. **Install LocalDevVPN** from the App Store and turn it on whenever SideStore
   installs or refreshes something. It only connects the phone to itself; no
   traffic leaves the phone through it.
4. **Sign in to SideStore with an Apple ID.** A free one works.

> **Consider a secondary Apple ID.** Giving any app your Apple account is worth
> limiting, and a separate free account costs nothing. That's general good
> practice, not a comment on SideStore.

---

## Adding Auvy

In SideStore, go to **Sources → +** and add this URL:

```
https://github.com/AKDontMiss/Auvy/releases/latest/download/source.json
```

Then install Auvy from that source.

---

## First launch

Sign in with your YouTube (Google) account. New accounts have to be approved
before the app unlocks, so you may see a "needs to be approved" screen. Once
you've been approved, switch back to Auvy and it lets you in without signing in
again. If sign-ups are invite-only, the screen asks for the invite code you were
given instead.

---

## Updating

Open Auvy → **Settings → Check for updates**.

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
* open it now and then
* keep LocalDevVPN available so refreshes can run
* let Auvy remind you: it offers on Home, or turn on **Settings → Updates →
  Refresh reminders**. It notifies you 2 days, 1 day and 3 hours before the
  signature runs out, even when Auvy is closed.

---

## Troubleshooting

**"Unable to verify app" / "Untrusted Developer"**
The signature expired or never finished. Refresh Auvy in SideStore.

**SideStore can't reach the device**
LocalDevVPN is off. Turn it on and try again.

**"Maximum number of apps" when installing**
A free Apple ID can only have 3 sideloaded apps at once. Remove one in SideStore
and try again.

**"Already on the latest version" when you expect an update**
The published version isn't newer than the one you have yet.

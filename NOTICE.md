# Notices and attribution

Auvy is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

## Copyright

Copyright © 2026 Akram Ahmed.

Auvy is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See [LICENSE](LICENSE) for the full terms.

Portions are copyright their respective authors — see [Derived code](#derived-code)
below, and the per-file headers those files carry.

## Additional terms under GPL-3.0 §7

The following supplement the GPL, using the two categories §7 permits. They are
**not** further restrictions: they add nothing to what you may do with this code,
only to what you must keep while doing it. Everything the GPL grants — using,
studying, modifying, redistributing, running your own build against your own
infrastructure — is granted here without exception.

**Under §7(b) — preservation of author attributions.** If you convey this work, or
a work containing part of it, you must preserve:

* the copyright notice above, in the source you distribute; and
* an attribution to *Auvy — © 2026 Akram Ahmed, GPL-3.0* in the Appropriate Legal
  Notices your work displays. In this program those notices are the About screen
  and the licence page it opens; in yours, wherever you show equivalent notices.

Preserving is all that is asked. You are free to add your own notices beside it,
and nothing here obliges you to advertise, endorse, or credit in a README, a store
listing, or any marketing material.

**Under §7(c) — no misrepresentation of origin.** A modified version must be marked
in a reasonable way as different from the original, and must not present itself as
Auvy or imply that it comes from, or is endorsed by, this project or its author. In
practice: change the application name, the package identifier and the launcher
icon. GPL-3.0 grants copyright permissions and says nothing about trademarks (see
[Trademarks](#trademarks)), so the name and marks are not licensed with the code.

**Why these two and no others.** §7 lists exactly which additional terms may
accompany the GPL, and any term outside that list is a further restriction a
recipient is entitled to strip out — which would make it worse than useless,
because it would misrepresent what this licence actually requires. Attribution
preservation and origin non-misrepresentation are on the list. A term such as "you
may not remove the account-approval gate" is not, and is deliberately absent: the
gate is enforced by a server this licence does not cover, which is architecture
rather than a licence condition.

If you received this work with any term not permitted by §7, you may remove it.

## Why GPL-3.0

Auvy contains code derived from GPL-3.0 projects, so it is GPL-3.0 too. That is not
a formality: GPL-3.0 is a copyleft licence, and a work containing derived code must
be released under the same terms, with its complete corresponding source offered to
everyone who receives the binary.

This was chosen deliberately over the alternatives (removing the affected feature,
or replacing it with a paid commercial service), because it keeps the feature, costs
nothing, and is honest about where the code came from.

## Derived code

### Song recognition — `lib/logic/recognition/audio_fingerprint.dart`

A Dart port of the Shazam audio-fingerprinting implementation, with this lineage:

| Project | Author | Licence |
| --- | --- | --- |
| [SongRec](https://github.com/marin-m/SongRec) | marin-m | GPL-3.0 |
| [Metrolist](https://github.com/MetrolistGroup/Metrolist) (`ShazamSignatureGenerator.kt`) | Metrolist Group | GPL-3.0 |
| [MusicRecognizer](https://github.com/aleksey-saenko/MusicRecognizer) | aleksey-saenko | GPL-3.0 |

Auvy's file is a line-for-line port of Metrolist's Kotlin, which in turn ports
SongRec's C++/Rust. Translating code into another language does not escape
copyright — a port is a derivative work — so this is the reason Auvy is GPL-3.0,
and these authors are the reason the feature exists at all.

**If this file is ever removed, Auvy's licence obligation does not automatically
change.** Check whether anything else derived remains before relicensing.

### Approaches and mechanisms

Auvy's development involved reading other open-source YouTube Music clients —
**Metrolist**, and the [InnerTune](https://github.com/z-huang/InnerTune) /
[OuterTune](https://github.com/DD3Boh/OuterTune) lineage it credits as its own
upstream, all GPL-3.0. Some of Auvy's approaches were arrived at with those in
view: the play-cache promotion model, the "cache what you finished" rule,
YouTube-recommendation autoplay seeding, and using a plain WebView for sign-in.

Those are **ideas and protocol facts, not copied code.** Only expression is
copyrightable; a mechanism, an API sequence, or the knowledge that a particular
InnerTube client returns un-throttled URLs is not.

### What was actually measured

**THIS SECTION EXISTS BECAUSE THE CODE COMMENTS USED TO OVERSTATE IT.**

Comments across the codebase once said things were "ported from" or "a clone of"
Metrolist in eleven places. Those claims were checked file by file against the
upstream sources, comparing the things that survive a translation between
languages — algorithmic constants, identifier names and string literals:

| Auvy file | Shared algorithmic constants | Finding |
| --- | --- | --- |
| `audio_fingerprint.dart` | **47 of 48** | Genuine port |
| song recognition service | 1 (`44100`) | Independent |
| theme / privacy / stream-sources screens | 0–6 of 38 | Independent |
| WebView sign-in | 0 | Independent |
| in-app changelog | 2 (`200`, `0.5`) | Independent |
| screenshot blocking | 0 | Independent |

Zero shared string literals in every case but the fingerprinter. Ten of the
eleven claims were simply **wrong**, and the comments have been corrected to
describe what the code actually is.

The one real derivation is the fingerprinter, and its attribution stays — above,
in the file's own header, and in the app's About screen. Rewriting it would not
change that: those 48 constants *are* the Shazam signature format, so any working
implementation shares them.

Named here rather than scattered through the source, because an attribution
chain that stops at whichever project you happened to read is incomplete, and
the point of this document is to be accurate rather than minimally compliant.

They are credited here regardless, because the debt is real even where the law does
not require the notice.

## Bundled third-party libraries

Auvy depends on 36 open-source packages under MIT, BSD-2/3-Clause and Apache-2.0 —
all permissive, none copyleft. Their notices are reproduced in the app under
**About → Open-source licences**, generated from package metadata so the list cannot
go stale.

## Cover artwork

The optional playlist covers offered in the app are community artwork published on
Reddit by its author, who permitted free use for non-commercial and hobby
purposes. Auvy's use fits that: it is not sold, carries no advertising and has no
in-app purchases. The images are served at runtime rather than bundled, and are not
included in this source distribution — a fork should supply its own.

Auvy fetches no artwork from any third-party image service. A live image-search
integration was built and then deliberately removed, so the cover library is a
fixed, licensed set with no API key, no shared rate limit and no attribution
obligation to a provider.

**GPL-3.0 does not cover artwork.** It is a software licence; images carry their
own terms. An unlicensed image is no more usable in a GPL project than in a closed
one — which is why a batch of 1532 covers sourced from a public Pinterest board was
removed outright. Whoever assembles such a board does not own what they pinned and
cannot license it.

## Trademarks

Service names (YouTube, Spotify, Last.fm, ListenBrainz, Discord, Shazam) are
trademarks of their respective owners and are used **descriptively**, to say what
Auvy interoperates with. Auvy is not affiliated with, endorsed by, or sponsored by
any of them.

**Their logos are deliberately not bundled.** GPL-3.0 grants copyright
permissions and says nothing about trademarks — another project shipping a mark does
not license it for this one.

## What Auvy is

An independent, unofficial client. It reaches music services through interfaces
those services do not publish for third-party apps, which may stop working at any
time and may affect the account used to sign in. Provided as is, without warranty.
Not for sale.

# Comics: a webcomic reader for the iPhone Duo

Design, 2026-11-22. Approved by Jay the same day. The app is called
"Comics" (Jay's choice).

## Intent

Jay wants to read webcomics on his iPhone Duo in one consistent reader instead
of five different websites. He is starting a **long catch-up** (Questionable
Content alone is ~6,000 strips) and afterwards wants to **stay caught up**. The
app has to make reading hundreds of strips in a sitting comfortable and must
never lose his place.

Jay's stated requirements:

- durably manages his place in each comic
- consistent UI, not just an iframe of the comic's site
- easily goes through many issues of a comic
- lists common webcomics as addable

Comics he named: xkcd, Questionable Content, Dumbing of Age, Perry Bible
Fellowship (PBF), Saturday Morning Breakfast Cereal (SMBC).

## Goals

1. One native reader for every comic: the strip image, its title, its hover
   text, and any bonus panel, drawn by the app.
2. A per-comic bookmark that survives app kills, reinstalls and a new phone.
3. Fast forward reading through a long archive: no visible loading between
   strips on a normal connection, and a way to jump anywhere.
4. After catch-up: one glance shows which comics have new strips and how many.
5. A built-in catalog of comics that can be added with one tap, which can be
   fixed or extended without reinstalling the app.
6. Layouts for both Duo screens: closed (466×678 pt) and open (951×669 pt).

## Non-goals (first version)

- Adding an arbitrary comic by URL from inside the app.
- Full-page story comics and vertical-scroll comics (Gunnerkrigg Court, Girl
  Genius, webtoons). The catalog format should not rule them out later.
- Notifications or background refresh for new strips. The app checks when it
  is opened.
- Downloading a whole archive for offline use. Only a read-ahead window is kept.
- Comments, forums, news posts, sharing, accounts, a server.
- iPad or Mac polish beyond "it runs" (the layout follows window size, so it
  will work, but only the two Duo sizes are designed and tested).

## Anti-goals

- Losing or silently moving the bookmark. An accidental scrub or a mis-tap
  must be recoverable.
- Hammering the comic sites. The app fetches what Jay reads plus a small
  read-ahead, one request at a time per site. It is a reader, not a mirror.
- Hiding the source. Every strip has a way to open its original page.
- A catalog entry that half works. A comic whose recipe is flaky is left out.

## Constraints

- Sibling of Quire, Powerplot and the crosswords fork: SwiftUI, xcodegen,
  iOS 18 deployment target, team `7UE4RDLUSX`, bundle `com.jsvana.comics`,
  lives in `~/projects/comics`.
- Layout follows the live window size, never the device model or orientation
  (same rule as `WindowForm` in Powerplot).
- No Duo simulator runtime works on the Mac mini. Test with a `-canvas WxH`
  launch argument on the "iPad Wide Test" simulator, as the sibling apps do.
- Heavy work (index parsing, image decoding, disk writes) stays off the main
  thread. Quire's "locks up when I press add" bug is the cautionary tale.

## Approaches considered

**A. Everything on the phone.** Recipes compiled into the app, which talks to
the comic sites directly. Simple and self-contained, but a site redesign means
an app rebuild and reinstall to fix one comic.

**B. A service on blackpearl.** A Rust service indexes and mirrors comics; the
phone is a thin viewer and the bookmark lives on the server. Fixes are a
deploy, but it adds a role to run, needs a public port or Tailscale away from
home, and reading stops when blackpearl is down.

**C. On the phone, with a remotely updatable catalog. (Chosen by Jay.)** As A,
but the catalog is a data file the app refreshes from a URL, with a bundled
copy as the fallback. Fixing or adding a comic that fits an existing recipe
shape is a push to the repo. Self-contained for reading, and removes A's main
annoyance cheaply. Five comics do not justify B.

## What the sites offer (checked 2026-11-22)

Every comic exposes its full archive as a list, so each strip gets a stable
ordinal ("2,140 of 5,965") without walking previous/next links.

| Comic | Strips | Index source | Strip details |
|---|---|---|---|
| xkcd | 3,327 | `https://xkcd.com/info.0.json` gives the latest number; strips are 1…N (404 does not exist) | `https://xkcd.com/N/info.0.json`: `img`, `safe_title`, `alt` |
| Questionable Content | 5,965 | front page `<img id="strip" src=".../comics/5965.png">` gives the latest number; strips are 1…N | `view.php?comic=N`, image in `<img id="strip">` (extension varies, so read it from the page) |
| Dumbing of Age | 5,631 | WordPress REST: `/wp-json/wp/v2/comic` (paged, `X-WP-Total` header) | the comic image is the `<img>` in the post content; its `alt` is the hover text |
| SMBC | ~7,980 | `https://www.smbc-comics.com/comic/archive`: one `<option value="comic/slug">date - title` per strip | strip page: `<img id="cc-comic" title="hover text">`, bonus panel in `<div id="aftercomic"><img>` |
| PBF | ~275 | `https://pbfcomics.com/comics/` links every strip | strip page; images are lazy-loaded (`data-src`), exact selector to be confirmed by the builder |

## Design

### Catalog and recipes (Claude's call on the shape)

The catalog is one JSON file: a version number and a list of comics. Each
comic has an id, title, author, home URL, a short description, a reading
hint (`portrait`, `wide`, or `mixed`), and a **recipe** made of two parts:

- an **index source**, one of a small set of kinds implemented in the app:
  `numbered` (find the latest number, strips are 1…N, with a skip list),
  `wordpress` (paged REST listing), `linkList` (one page whose links or
  options, matched by a pattern, are the strips in order);
- a **strip extractor**: either `json` (field names) or `html` (patterns with
  named captures for image URL, title, hover text, bonus image).

Kinds are code; everything else (URLs, patterns, field names) is data. That is
the line between "fixable by pushing a new catalog" and "needs an app update".

The app ships with a bundled catalog and, on launch, fetches the remote copy
(conditional request, at most once a day, plus a manual "refresh catalog").
It adopts the remote copy only if it parses and its version is not lower.
A catalog it does not understand (higher schema version) is ignored.

Remote location: a raw file URL, stored as a setting with a default (see
"Catalog hosting").

Launch catalog: the five comics above. Candidates for later, once each is
checked: Dinosaur Comics, Order of the Stick, Wondermark, Poorly Drawn Lines,
Achewood, Dr. McNinja, Hark! A Vagrant, Bad Machinery.

### Index

Per added comic the app stores the ordered list of strips: ordinal, the
site's own key (number or slug), title and date where the index gives them.
Building it is one or a few requests (DoA's API is paged at 100 per page, so
~57 requests the first time, done in the background with progress shown).
Refreshing on app open only asks for what is new. Ordinals are assigned once
and never renumbered; new strips append.

Strip details (image URL, hover text, bonus) are fetched lazily when a strip
enters the read-ahead window, then stored, so a strip page is requested once.

### Place-keeping (the durable part)

Per comic there is **one number that matters: the bookmark**, the strip Jay
is on. (Claude's call: no separate "furthest read" or per-strip read state.
One number cannot disagree with itself, and it is what "my place" means.)

- The bookmark is written to the local database on every strip change, before
  the page-turn animation finishes.
- Everything on the library card derives from it: "2,140 of 5,965" while
  behind, "3 new" when the bookmark is within a few strips of the end and new
  ones have arrived, "caught up" when the bookmark is the latest strip. The
  count of strips to go is always latest minus bookmark.
- **Jump history**: when the bookmark moves by anything other than next or
  previous (scrubber, "go to", "latest"), the old position is pushed onto a
  short stack and a "Back to #2140" chip appears in the reader. The last few
  are also listed in the comic's menu. Peeking at the latest strip therefore
  moves the bookmark, and one tap puts it back.
- Deliberate backward moves stick. Nothing ever moves the bookmark forward on
  its own.

The bookmark is stored by the strip's site key as well as its ordinal, so it
still resolves if an index is ever rebuilt.

Durability beyond the device (Claude's call): the list of added comics, each
bookmark and its jump history are mirrored to iCloud key-value storage on
every change (small, automatic, no server). This is a **restore copy for one
phone, not sync between devices**. The app reads it only for a comic that has
no local record, which in practice means a fresh install or a new phone; once
a comic exists locally, local state always wins and iCloud is write-only. An
"Export / Import progress" file in Settings is the manual fallback. If the
iCloud entitlement turns out not to provision with the ASC key on the Mac
mini, export/import alone ships and iCloud is revisited.

### Reader

One strip view used everywhere: image scaled to fit the width, vertical scroll
when the strip is taller than the screen, pinch and double-tap to zoom. Under
the image: title, number and date on one line, then the hover text as a
caption, then the bonus panel (SMBC) as a second image. Hover text is shown
by default with a setting to make it tap-to-reveal.

Moving: tap the right or left third, or swipe, for next and previous. On a
strip taller than the screen, a tap on the right first scrolls down a screen
and only advances at the bottom, so one thumb reads everything. Chrome (top
bar, scrubber) is hidden while reading and toggled by tapping the middle.

Closed Duo (and any narrow window):

```
┌──────────────────────────┐
│                          │
│   ┌──────────────────┐   │
│   │                  │   │
│   │      strip       │   │
│   │                  │   │
│   └──────────────────┘   │
│  Number 2140 · 3 May 2012│
│  hover text caption…     │
│                          │
│ ‹ prev   (tap mid)  next ›│
└──────────────────────────┘
tap middle →  top: ‹ Library   QC   ⋯
              bottom: |——●————————| 2140 / 5965
```

Open Duo (wide window): a **spread** of up to two consecutive strips, chosen
by what fits at a readable size. Portrait strips (QC) sit side by side; wide
strips (DoA, many xkcd) stack two high; a strip too big to pair gets the whole
screen. Next and previous move by the spread. The bookmark is the first strip
of the spread; advancing moves it to the first strip of the next spread.

```
┌───────────────────────┬───────────────────────┐
│  ┌─────────────────┐  │  ┌─────────────────┐  │
│  │                 │  │  │                 │  │
│  │   strip 2140    │  │  │   strip 2141    │  │
│  │                 │  │  │                 │  │
│  └─────────────────┘  │  └─────────────────┘  │
│  Number 2140 · caption│  Number 2141 · caption│
└───────────────────────┴───────────────────────┘
```

Read-ahead: the next 10 strips' details and images are fetched while reading
(20 on Wi-Fi), the previous 5 are kept, one request at a time per site. Images
live in the caches directory with a size cap (default 500 MB, oldest first).
If the next strip is not ready it shows a placeholder with a spinner, not a
blocked UI. A failed strip shows "Couldn't load, retry / open original" and
does not stop Jay moving past it.

The ⋯ menu: go to number or date, first, latest, back (jump history), open
original page, reload this strip.

### Library and catalog

Library (home): one card per added comic with a thumbnail of the bookmarked
strip, title, a progress bar, and either "2,140 of 5,965" during catch-up or
"3 new" / "caught up" afterwards. Tapping resumes at the bookmark. Comics with
new strips sort first. Pull to refresh checks every comic for new strips;
this also happens on app open, at most every 30 minutes.

Catalog ("Add comics"): the catalog list with title, author, description and
strip count, an Add button, and a choice on adding: start from the first
strip or from the latest. Removing a comic from the library keeps its
bookmark for 30 days in case it was a mistake.

In the wide layout the library is a two-column grid; catalog and settings are
sheets.

### Storage (Claude's call)

SQLite through GRDB for catalog state, indexes, strip details, bookmarks and
jump history, in Application Support (backed up). Images in Caches (not backed
up, re-fetchable). iCloud key-value store for the mirror described above.

### Errors

- Offline: cached strips read normally; uncached ones show the placeholder;
  a quiet banner says "offline".
- Recipe broken (extractor finds no image on several strips in a row): the
  comic's card shows "This comic's recipe needs an update", the reader offers
  "open original", and the app re-checks the remote catalog.
- Index refresh fails: keep the old index, try again next open.

### Testing

- Unit tests for every index kind and extractor against saved copies of real
  pages and API responses (fixtures in the repo), including xkcd 404 and
  a QC strip with a non-PNG image.
- Unit tests for place-keeping: bookmark written on every move, jump history,
  restore from iCloud only when there is no local record, bookmark surviving
  an index rebuild.
- A manually run "recipe health" test that hits the live sites for the first,
  a middle and the latest strip of each catalog comic. Not part of the normal
  test run.
- UI tests on the "iPad Wide Test" simulator with `-canvas 466x678` and
  `-canvas 951x669`, using a bundled fixture comic so they need no network.
  Debug launch arguments in the style of the sibling apps: `-canvas`,
  `-openComic <id>`, `-goto <n>`, `-fixtureCatalog YES`, `-icloud NO`.

## Left to the builder

- View and type structure, GRDB schema details, the exact regex or selector
  for each recipe (PBF's lazy-loaded image especially).
- How "fits at a readable size" is computed for spreads; tune on the two
  canvas sizes with real QC, DoA and xkcd strips.
- App icon and visual styling. Follow Quire's quiet look: the strip is the
  page, chrome stays out of the way, light and dark both supported.
- Request pacing numbers, cache eviction details.

## Catalog hosting (decided by Jay)

The GitHub repo `jsvana/comics` is public and the app reads the catalog from
the raw file on `main` (`catalog/catalog.json`). The same file is the bundled
fallback. The repo holds no secrets; signing keys and team credentials stay
outside it as with the sibling apps.

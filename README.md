# Comics

A native SwiftUI reader for webcomics, designed for a foldable iPhone Duo (466x678 closed,
951x669 open) and usable on any iPhone or iPad. It reads each comic from its own site, shows the strip,
title, hover text and bonus panel in one consistent reader, and keeps your place in every comic.

- Archives of thousands of strips: jump to any strip, jump back to where you were, read ahead
  without waiting.
- Your place survives app kills; a copy goes to iCloud so a reinstall or new phone can pick it up,
  and Settings can export and import it as a file.
- The library shows which comics have new strips since you last read.
- Two layouts, chosen from the window size alone: wide (width at least 700 and wider than tall)
  and narrow.

Requires iOS 18 and Xcode. The only package dependency is GRDB (SQLite).

## The catalog

`catalog/catalog.json` lists the comics that can be added and how to read each one. It is bundled
in the app, and the app also checks the copy at
`https://raw.githubusercontent.com/jsvana/comics/main/catalog/catalog.json` once a day (Settings can
point it elsewhere; https only). A downloaded catalog replaces the bundled one only if its schema is
supported and its `version` is not lower. If you change a recipe, raise `version`.

Current comics: xkcd, Questionable Content, The Perry Bible Fellowship.

Each comic has an `index` recipe (find all strips, oldest first) and a `strip` recipe (find one
strip's image on its page). Patterns are regular expressions with named capture groups.

Index kinds:

| kind | fields | notes |
|---|---|---|
| `numbered` | `latestURL`, `latestPattern` (group `n`), `first`, `skip` | strips are numbers `first...n`, minus `skip` |
| `wordpress` | `api` | a WordPress REST post-type endpoint, read in pages of 100, oldest first |
| `linkList` | `url`, `itemPattern` (group `key`; optional `title`, `date`), `pageTemplate`, `newestFirst` | an archive page of links; `{key}` in `pageTemplate` |

Strip kinds:

| kind | fields | notes |
|---|---|---|
| `json` | `url`, `page`, `image`, optional `title`, `hover` | `url` and `page` take `{key}`; `image`, `title`, `hover` are JSON field names |
| `html` | `url`, `imagePattern`, optional `titlePattern`, `hoverPattern`, `bonusPattern` | `url` takes `{key}` or `{page}`; every pattern captures the group `v` |

### Adding a comic

1. Add an entry to `catalog/catalog.json` (`id`, `title`, `author`, `home`, `about`, `shape` of
   `portrait`, `wide` or `mixed`, plus `index` and `strip`). Strip numbers are assigned once and
   never renumbered, so choose the index recipe so that old strips stay put.
2. Save sample pages into `ComicsTests/Fixtures` (see `scripts/fetch-fixtures.sh`) and add offline
   tests next to the existing ones in `IndexFetcherTests` and `StripExtractorTests`.
3. Run the live health check below. It builds the full index and downloads the first, middle and
   last strip of every comic.

The app identifies itself as `Comics/1.0`, makes one request at a time per site with a 250 ms gap,
and caches images (up to 500 MB). A site that refuses that client name cannot be added.

## Build and test

```
xcodegen        # Comics.xcodeproj is generated from project.yml
xcodebuild test -project Comics.xcodeproj -scheme Comics \
  -destination 'platform=iOS Simulator,name=<a simulator>' \
  -only-testing:ComicsTests
```

Use `-only-testing:ComicsUITests` for the UI tests. Unit tests never touch the network, except the
opt-in live check:

```
TEST_RUNNER_COMICS_LIVE=1 xcodebuild test ... -only-testing:ComicsTests/RecipeHealthTests
```

Without that variable `RecipeHealthTests` is skipped. Running it sends a few dozen requests to
the comics' sites, so do not run it in a loop.

## Launch arguments

For tests and debugging, pass these as `-name value`:

| argument | effect |
|---|---|
| `-canvas 951x669` | lay out as if the window had this size |
| `-openComic <id>` | open this comic in the reader at launch |
| `-goto <n>` | with `-openComic`, open at strip number `n` |
| `-fixtureCatalog YES` | use the bundled fixture comic and no network, with a separate database |
| `-resetFixture YES` | with `-fixtureCatalog`, start from an empty fixture database |
| `-icloud NO` | keep the place copy in memory instead of iCloud |

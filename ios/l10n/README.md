# App translations (PLAN A7)

The app's buttons, menus and messages in 10 languages besides English: es, zh-Hans,
zh-Hant, it, ru, ja, ko, de, fr, pt-BR. They are machine translations, reviewed per
language by a second AI pass, and the app shows a "Beta translation" tag until a native
speaker has checked them. Excerpt notes are translated separately
(`content/translations/`, shown from 12 Nov 2026).

## Files

- `_keys.json` — every string the app uses. It comes from CI: the iOS workflow's
  "Strings for translation" step prints them compressed into the log
  (`ios/scripts/collect_strings.py --dump`), because artifacts can't be downloaded
  from the cloud coding session.
- `<lang>.json` — `{English key: translation}`; for a key whose only argument is one
  integer, plural forms `{"one": …, "other": …}` (Russian also `few`, `many`).
- `_glossary-<lang>.md` — the terms each language uses, so new strings stay consistent.
- `topup/` — later additions; `build_catalogs.py` folds them into `<lang>.json`.

## Rebuilding the catalogues

    python3 ios/scripts/build_catalogs.py          # writes Localizable.xcstrings + InfoPlist.xcstrings
    python3 ios/scripts/build_catalogs.py --check  # exit 1 if anything is missing or rejected

Every translation goes through `merge_translations.py`: it must use exactly the same
format arguments as the English (`%@`, `%lld`; positional `%1$@` allowed for word
order) or it is left out, and the app shows English there instead of broken text.

## When the app gains new strings

CI's "Strings for translation" step lists how many keys are missing from the catalogue
and untranslated per language. Decode the dump into `_keys.json`, translate the new keys
into `topup/<lang>.json` (follow the glossaries), run `build_catalogs.py`, commit.

Two keys, `lists.phrase.allChairs` and `lists.phrase.chair`, are built in code from the
instrument and chair names; the translations use a complete phrase ("lists for your
chair") because gluing words works only in English.

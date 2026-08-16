# Superseded pose exports

Two single-pose exports — `sniffing_the_ground` and `hunched_over_defecat` — that
predate the full character kit next door in `dog-states/`. They sat loose in the repo
root, one top-level directory each, for two poses that ship from somewhere else.

`Tools/import_jumba.py` still lists them in `EXTRA_STATES`, but that map runs *before*
`KIT_STATES`, which writes the same `sniff_*` and `hunch_*` filenames from
`dog-states/`. The kit therefore overwrites whatever these produce, every run.

That is not a guess about the code path. Running the importer's own transform over both
sources and comparing against `Sources/Jumbini/Resources/jumba/` puts all sixteen
shipped sprites with the kit and none with these, and the two sources import to
different bytes in all sixteen cases — so the result distinguishes them rather than
being true either way.

They are kept because `EXTRA_STATES` is documented as a fallback for anyone still
holding the pre-kit exports, and deleting the art would make that fallback a lie. Delete
both this directory and the `EXTRA_STATES` rows together if that fallback is ever
dropped; nothing in the shipped app depends on either.

The art here is rights-reserved — see `LICENSE`.

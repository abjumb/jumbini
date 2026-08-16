# Bed art exports

The source exports behind `Sources/Jumbini/Resources/sprites/bedvar_1..12.png`, one
folder per bed. No importer reads this directory — the shipped sprites were brought
across by hand — so it exists as provenance: the 48×48 original each menu entry came
from, kept so a bed can be re-cut or redrawn without going back to the art tool.

The folders arrived as `Blue Fuzzy Dog Bed`, `Blue Fuzzy Dog Bed (1)` … `(11)` — a
download-order naming that said nothing about which bed was which, and matched no name
the app uses. They now carry the sprite index and the menu label from
`PetScene.bedVariants`:

| Folder | Sprite | Menu name |
|---|---|---|
| `01-classic-bolster` | `bedvar_1` | Classic Bolster |
| `02-round-cushion` | `bedvar_2` | Round Cushion |
| `03-cozy-tub` | `bedvar_3` | Cozy Tub |
| `04-navy-lounger` | `bedvar_4` | Navy Lounger |
| `05-fuzzy-donut` | `bedvar_5` | Fuzzy Donut |
| `06-speckled-cushion` | `bedvar_6` | Speckled Cushion |
| `07-sherpa-tub` | `bedvar_7` | Sherpa Tub |
| `08-flat-mat` | `bedvar_8` | Flat Mat |
| `09-shaggy-donut` | `bedvar_9` | Shaggy Donut |
| `10-car-seat` | `bedvar_10` | Car Seat |
| `11-corduroy-tub` | `bedvar_11` | Corduroy Tub |
| `12-wicker-basket` | `bedvar_12` | Wicker Basket |

The mapping was not assumed from the download order. Each export was cropped to its
alpha bounding box and compared against every one of the twelve shipped sprites: each
one matches exactly one sprite with zero pixel difference, and its nearest rival is a
long way off (worst case 0.098 normalised distance, most far worse). The order does turn
out to be the download order, but it is recorded here because it was measured.

The exports are 48×48 on a transparent background; the shipped sprites are the same art
cropped and rescaled, which is why they are not byte-identical.

The art here is rights-reserved — see `LICENSE`.

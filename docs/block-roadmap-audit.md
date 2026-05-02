# Block Roadmap Audit

Issue: #622  
Source roadmap: #138  
Replacement epic: #616

## Current Registry Baseline

The current block registry lives in `modules/world-core/src/block.zig` and `modules/world-core/src/block_registry.zig`.

- `BlockType` is `enum(u8)`.
- `MAX_BLOCK_TYPES` is 256 in `modules/world-core/src/chunk_constants.zig`.
- The registry currently defines 47 enum entries including `air`, leaving 209 ID slots before the current cap.
- `RenderShape` currently supports `.cube` and `.cross`.
- Cross-billboard vegetation is already implemented by `modules/world-meshing/src/meshing/cross_mesher.zig`.

## Implemented Blocks

These are present in the current `BlockType` enum and registered in `BLOCK_REGISTRY`.

| Family | Implemented blocks |
| --- | --- |
| System | `air` |
| Base terrain | `stone`, `dirt`, `grass`, `sand`, `cobblestone`, `bedrock`, `gravel` |
| Liquids | `water`, `lava` |
| Transparent/building | `glass` |
| Snow/desert | `snow_block`, `cactus`, `red_sand`, `terracotta` |
| Ores/resources | `coal_ore`, `iron_ore`, `gold_ore`, `clay`, `glowstone` |
| Wetlands/swamp | `mud`, `mangrove_log`, `mangrove_leaves`, `mangrove_roots` |
| Jungle/savanna | `jungle_log`, `jungle_leaves`, `melon`, `bamboo`, `acacia_log`, `acacia_leaves`, `acacia_sapling` |
| Mushroom biome | `mycelium`, `mushroom_stem`, `red_mushroom_block`, `brown_mushroom_block` |
| Cross vegetation | `tall_grass`, `flower_red`, `flower_yellow`, `dead_bush` |
| Temperate/cold trees | `birch_log`, `birch_leaves`, `spruce_log`, `spruce_leaves` |
| Attachments/lights | `vine`, `torch` |

## Stale Entries From #138

#138 is superseded and stale in these places:

| #138 entry | #138 status | Current status | Correction |
| --- | --- | --- | --- |
| Paths under `src/world/*` | Current in old comments | Moved | Use `modules/world-core/src/block.zig`, `modules/world-core/src/block_registry.zig`, and `modules/world-meshing/src/meshing/*`. |
| Cross-billboard rendering | Listed as Phase 1 prerequisite | Implemented | `.cross` exists and is meshed by `cross_mesher.zig`; future work is shape expansion, not initial cross support. |
| `birch_log` | Missing | Implemented | Present as ID 40. |
| `birch_leaves` | Missing | Implemented | Present as ID 41. |
| `spruce_log` | Missing | Implemented | Present as ID 42. |
| `spruce_leaves` | Missing | Implemented | Present as ID 43. |
| `vine` | Missing wall-attached block | Implemented with interim shape | Present as ID 44 and currently uses `.cube`; #627 should decide wall-attached geometry/state. |
| `torch` | Missing special placement | Implemented with interim shape | Present as ID 45, emits light, and currently uses `.cross`; #627 should decide custom/attachment geometry. |
| `lava` | Missing | Implemented | Present as ID 46, fluid pass, emits light. |
| 322-block roadmap total | Future target | Exceeds current cap if fully adopted | #621 should decide if/when to widen IDs or introduce palette storage. |
| #138 summary counts | 40 implemented / 282 planned | Out of date | Current baseline is 47 registry entries including `air`, or 46 non-air blocks. |

#138 also omits implemented ore blocks from its terrain/building catalogue: `coal_ore`, `iron_ore`, and `gold_ore`.

## Missing Blocks By Family

The unchecked #138 list is still valid as a catalogue only after removing the stale implemented entries above. The remaining missing blocks are best grouped by dependency rather than copied wholesale into one phase.

| Dependency | Priority | Candidate family | Representative missing blocks |
| --- | --- | --- | --- |
| #621 capacity policy | High | ID budget guardrail | Decide whether Phase 2 stays comfortably under 256 IDs or waits for wider IDs/palettes. |
| Existing `.cube` shape | High | Core natural cubes | `smooth_stone`, `mossy_cobblestone`, `coarse_dirt`, `rooted_dirt`, `podzol`, `ice`, `packed_ice`, `moss_block` |
| Existing `.cube` shape | High | Wood planks for existing trees | `oak_planks`, `birch_planks`, `spruce_planks`, `jungle_planks`, `acacia_planks`, `mangrove_planks` |
| Existing `.cube` shape | High | Stone and clay building basics | `stone_bricks`, `cracked_stone_bricks`, `mossy_stone_bricks`, `bricks`, `mud_bricks` |
| Existing `.cube` shape | Medium | Stone variety | `granite`, `diorite`, `andesite`, `deepslate`, `tuff`, `calcite`, `basalt`, `marble`, `slate` |
| Existing `.cube` shape | Medium | Colorable full cubes | Wool/concrete/terracotta color subsets before full 16-color parity. |
| Existing `.cross` shape | High | Small vegetation and saplings | `short_grass`, `fern`, `oak_sapling`, `birch_sapling`, `spruce_sapling`, `jungle_sapling`, `red_mushroom`, `brown_mushroom` |
| Existing `.cross` shape plus #624 decoration profiles | Medium | Flower variety | `blue_orchid`, `allium`, `azure_bluet`, tulips, `oxeye_daisy`, `cornflower`, `lily_of_the_valley` |
| #623 flat quad and tall cross | High | Thin/tall plants | `snow_layer`, `large_fern`, `sunflower`, `lilac`, `rose_bush`, `peony`, `moss_carpet`, `lily_pad` |
| #623 and #624 | Medium | Aquatic vegetation | `seagrass`, `tall_seagrass`, `kelp`, plus placement rules for underwater decoration. |
| #623 and #624 | Medium | Coral foundation | `coral_block_*`, `dead_coral_block`, `coral_fan`, `sponge`, `wet_sponge`, `prismarine`, `sea_lantern` |
| #627 attached/custom geometry | High | Attachments and lights | Proper wall-attached `vine`, proper `torch`, `lantern`, `soul_torch`, `glow_lichen`, cave/nether vines. |
| #627 attached/custom geometry | Medium | Functional shapes | `doors`, `trapdoors`, `fences`, `fence_gate`, `iron_bars`, `glass_pane`. |
| #627 attached/custom geometry | Medium | Slabs, stairs, walls | `oak_slab`, `stone_slab`, `cobblestone_slab`, `oak_stairs`, `stone_stairs`, `cobblestone_wall`, `stone_brick_wall`. |
| Future gameplay systems | Lower | Crops and interactives | `farmland`, `wheat_crop`, `beetroot_crop`, `carrot_crop`, `potato_crop`, `sweet_berry_bush`. |
| Future dimension scope | Lower | Nether/End blocks | `soul_sand`, `soul_soil`, `nether_bricks`, `crimson_*`, `warped_*`, `quartz_*`, `purpur_*`, `end_stone_bricks`. |
| Future visual parity | Lower | Decorative parity | Full stained glass, all wool/concrete colors, copper aging, bookshelves, slime/honey, bone, dried kelp, honeycomb. |

## Phase 2+ Recommendations

1. Keep #616's current ordering. This audit does not require changing the epic's dependency graph.
2. Let #625 focus on cube and cross blocks that unlock overworld biomes without new geometry: core natural cubes, planks for existing tree families, small vegetation, saplings, and basic stone/clay building cubes.
3. Let #626 own underwater plants/coral because those depend on decoration placement and aquatic generation rules, not just enum additions.
4. Let #627 own true attachment/custom geometry for `vine`, `torch`, panes, doors, fences, slabs, stairs, and walls. Existing `vine` and `torch` should be treated as interim implementations, not blockers for #625.
5. Defer Nether, End, full 16-color parity, and broad decorative/building parity until the block ID capacity decision in #621 is settled.

## #616 Impact

No scope, ordering, or block-family name changes are required for #616. The epic already accounts for the important corrections: #138 is superseded, current paths use `modules/*`, cross rendering exists, and the 322-block catalogue exceeds the current `u8`/256-ID architecture.

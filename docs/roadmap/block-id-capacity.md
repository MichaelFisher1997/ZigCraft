# Block ID Capacity Policy

Issue: [#621](https://github.com/OpenStaticFish/ZigCraft/issues/621), part of [#616](https://github.com/OpenStaticFish/ZigCraft/issues/616).

## Current Capacity

`BlockType` is currently stored as `enum(u8)` in `modules/world-core/src/block.zig`, and `MAX_BLOCK_TYPES` is `256` in `modules/world-core/src/chunk_constants.zig`.

The current block catalog defines 47 concrete block IDs, `0` through `46`, leaving 209 IDs before the `u8` ceiling. The enum also has a flexible `_` tag, so new block IDs can continue to be added without changing the representation while the catalog remains under 256 entries.

## Policy

Keep block IDs as `u8` in the near term. This keeps chunk storage compact and avoids adding palette/remapping complexity before the project needs it.

Revisit a `u16` block ID representation with a palette/remapping layer when the concrete block catalog approaches roughly 200 entries. At that point, open or update a follow-up issue to define the migration order, save compatibility requirements, chunk storage layout, serialization changes, and rendering/meshing impacts before adding large block families that would risk exhausting the `u8` space.

No block ID widening, palette storage, or remapping layer is needed for the current 47/256 catalog.

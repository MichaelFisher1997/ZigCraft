# Decision: compact GPU-rendered far-terrain tiles

**Issue:** [#917](https://github.com/OpenStaticFish/ZigCraft/issues/917)

**Status:** Proposed decision with implementation foundation; not a claim that a compact GPU terrain renderer is already shipped.

## Context and evidence

Issue #917 is Phase 4 of the LOD GPU roadmap. It follows the completed Phase 0–3 work rather than replacing it:

- Phase 0 added opt-in LOD CPU/upload/pressure telemetry in
  [`modules/world-lod/src/lod_stats.zig`](../../modules/world-lod/src/lod_stats.zig), bounded benchmark scenarios in
  [`docs/benchmarks/README.md`](../benchmarks/README.md), and the CPU-only generation probe in
  [`src/lod_bench_main.zig`](../../src/lod_bench_main.zig).
- Phase 1 moves mesh generation outside the manager lock, keeps CPU generation and policy authoritative, batches MDI where possible, and retains selectable heightfield, span, and QEM CPU mesh paths in
  [`lod_manager_generation_ops.zig`](../../modules/world-lod/src/lod_manager_generation_ops.zig) and
  [`lod_mesh.zig`](../../modules/world-lod/src/lod_mesh.zig).
- Phase 2 gives streaming a bounded upload path and deferred retirement. Upload bytes and staging-pressure events are recorded in
  [`lod_manager_upload_ops.zig`](../../modules/world-lod/src/lod_manager_upload_ops.zig); eviction defers deletion in
  [`lod_manager_eviction_ops.zig`](../../modules/world-lod/src/lod_manager_eviction_ops.zig). The current shared vertex pool remains a CPU-shadowed `Vertex` pool in
  [`lod_vertex_pool.zig`](../../modules/world-lod/src/lod_vertex_pool.zig).
- Phase 3 supplies CPU-approved candidates, GPU frustum compaction, and indirect terrain/water streams through
  [`lod_renderer.zig`](../../modules/world-lod/src/lod_renderer.zig) and
  [`modules/engine-rhi/src/culling.zig`](../../modules/engine-rhi/src/culling.zig). It intentionally falls back to CPU visibility when the workload, pooled-buffer state, or indirect-count support is unsuitable.

The present far path still worker-builds CPU-expanded `engine-rhi.Vertex` arrays and uploads them. `Vertex` is an `extern struct` carrying position, packed colour/normal/meta, UV, and block light
([`rhi_types.zig`](../../modules/engine-rhi/src/rhi_types.zig)); `LODMesh` holds pending vertices and separate opaque/water ranges. LOD3 and coarser currently select the heightfield path, which emits top quads, stepped side faces, optional water quads, and some vegetation geometry. Rich source columns already contain height, material layers, water, lighting, vegetation, provenance, and optional vertical spans in
[`modules/world-core/src/lod_data.zig`](../../modules/world-core/src/lod_data.zig).

This is enough evidence to define and prototype a compact representation, but not enough to assert that it wins on every GPU. Existing instrumentation measures worker mesh construction, uploads, CPU visibility, state work, staging pressure, deferred CPU vertex capacity, candidate counts, and CPU/GPU culling diagnostics. It does **not** yet separately account for compact-tile residency, tile-fetch bandwidth, tile-expansion time, or far-terrain GPU timestamps. Those measurements are rollout requirements below. No performance result is implied by this decision.

## Decision

Adopt **a reusable indexed grid plus compact, device-local storage-buffer tiles** as the first production GPU path for LOD3 and LOD4. The grid supplies only local sample coordinates and indices; the vertex shader (vertex pulling) obtains the selected tile's compact samples and derives final terrain vertices. The existing Phase 3 CPU-approved visibility and indirect submission remain the first submission path.

The path is intentionally a heightfield-oriented far representation. It does not promise arbitrary overhangs, per-block side topology, or detailed tree meshes at LOD3/4. Those stay on the existing near/mid CPU mesh paths until a separately validated representation is needed.

Compute expansion is retained as a measured follow-up option, not the initial default. Mesh shaders are an experimental, supported-device-only spike and are not a production dependency.

### Why this is the first path

| Option | Transfer bytes and VRAM | Shader bandwidth / work | Seams and normals | Edits | Support and maintenance | Decision |
| --- | --- | --- | --- | --- | --- | --- |
| **Reusable indexed grid + compact tile SSBO** | Uploads tile samples and metadata instead of repeated expanded vertices; one grid/index buffer is shared. Resident tile payload is proportional to samples, plus descriptors/indirection, rather than per-region vertex capacity. Actual reduction must be measured. | Each grid vertex fetches a small, regular sample neighbourhood. It trades vertex fetch/upload bandwidth for SSBO reads and derived attributes, but has no expansion pass or generated vertex pool. | A one-sample apron makes central-difference normals and edge positions deterministic; precomputed stitch/skirt variants handle topology. | Upload changed tile records or replace a tile version; no readback and no CPU vertex rebuild for the far path. | Uses conventional Vulkan graphics, storage buffers, and indirect drawing already represented by the RHI. One terrain shader variant and one tile allocator are required. | **Selected.** Lowest new synchronization and allocator surface while directly attacking repeated vertex data. |
| **Compute expansion into pooled vertex/index buffers** | Compact upload is still possible, but expanded GPU vertices/indices reintroduce substantial resident memory and pool fragmentation. | Moves expansion and side/skirt generation to compute, adds write bandwidth and compute-to-graphics barriers. It may win only when vertex pulling is demonstrated to be the bottleneck. | Can emit exact stitch/side geometry, but owns a second geometry generator whose boundary rules must stay equivalent to CPU and shader rules. | A tile edit requires re-expanding its allocation and safely retiring/reallocating its old range. | Needs a robust output-pool allocator, overflow handling, barriers, and retirement for generated ranges in addition to the input tile system. | Defer until grid-path GPU timing or feature limits demonstrate a need. |
| **Mesh shaders** | Can avoid persistent expanded geometry and can generate topology per workgroup. | Potentially efficient for culling/amplification and topology generation, but performance and limits are device-specific. | Flexible, but seam and normal code becomes mesh-shader-specific and must still match the fallback. | Tile replacement is straightforward; generated output is transient. | Requires mesh-shader capability detection, new RHI/pipeline work, and a conventional maintained renderer. It excludes too many target devices as a first path. | Research-only after the selected path is stable; never the sole renderer. |

The comparison explicitly does not assume that shader bandwidth is free or that compute is automatically superior. The grid path is accepted only if its tile reads, vertex work, and visual quality meet the gates below; the CPU mesh path remains the safe alternative.

## Compact semantic tile ABI

The compact tile is a **GPU transport/render ABI**, not a replacement for `LODSimplifiedData` or its persisted source semantics on day one. CPU data and persistence remain authoritative. The foundation provides a versioned, checksummed compact wire encoding for testing and future cache integration, but the canonical LOD cache does not consume it yet; that integration requires an explicit cache-version/migration decision.

The foundation tile is a versioned, fixed-endian 16-byte sample grid with a small serialized header (magic, ABI version, LOD, neighbor-apron mask, width/count, and payload CRC). The production renderer must add a std430-compatible GPU header/instance view that provides:

- ABI version, tile state/flags, LOD level, region key/origin, cell size, interior grid dimensions, and the tile's generation/edit version;
- a documented height decode and quantization error bound derived from the selected level's needs (the foundation ABI uses signed 1/8-block absolute heights; a future affine/base-relative format requires an ABI version bump);
- offsets/counts into separately aligned arrays for samples and optional far-detail records, not native Zig pointers or enums;
- conservative min/max terrain and water heights, world-space bounds, and an availability/ready flag used by CPU hierarchy policy; and
- explicit feature bits for water, lighting hint, vegetation aggregate, provenance availability, apron validity, and any future extension. Unknown required bits or ABI versions reject the compact path and use CPU mesh fallback.

The interior sample record must preserve the following semantics even if the final packing evolves:

| Semantic | Requirement |
| --- | --- |
| Terrain height | Quantized relative to the tile decode range; decoding must reproduce the shared edge sample exactly for adjacent same-level tiles. |
| Surface/material | Stable semantic block IDs plus representative tint information sufficient for far terrain. The foundation ABI stores known seven-bit `BlockType` wire values—not atlas IDs—and reduces unknown future values to stone; changing those wire values requires an ABI version bump. |
| Colour and lighting | Packed representative colour/tint and the far lighting/AO hints required by the selected terrain shading policy. Do not silently reinterpret channel order or colour space. |
| Water | Separate surface-present/coverage classification, quantized surface height or canonical sea-level indication, and depth/colour category sufficient for the far-water pass. Terrain-floor and water-surface semantics remain distinct. |
| Vegetation | The foundation ABI stores aggregate coverage and representative height. A production renderer must either declare a folded representative terrain-colour policy or add versioned type/colour fields; it must not imply a full tree mesh. |
| Provenance | Worldgen, chunk-derived, and edited authority must be retained in CPU source data. A compact provenance class is included when needed for diagnostics and invalidation, not as permission for the GPU to resolve edits. |

Vertical spans are deliberately outside the first LOD3/4 tile contract. A tile marked as requiring unsupported span/overhang representation is rendered through the CPU fallback (or a later explicitly versioned extension), never flattened without a visual-policy decision.

### Edge apron and seam contract

Every resident tile contains a **one-sample apron** around its interior height/material/water samples. Foundation generation starts with a duplicated-edge fallback and records no neighbor-valid bits. As same-level neighbors become available, the producer patches each apron from the neighbor's opposite interior edge and records the corresponding validity bit before enabling seamless compact rendering.

- Shared same-level edges must decode to identical positions and compatible material/water classification. Adjacent uploads may arrive in any order; a tile with an invalid apron is not eligible for the seamless compact draw path.
- Vertex normals use central differences from the apron in the interior and at boundaries. They are derived in the vertex shader for the initial path; no per-vertex normal storage is required. The normal calculation uses decoded world spacing and the same height quantization policy on both sides of an edge.
- Cross-LOD boundaries use an explicit edge mask selected by CPU hierarchy policy. The initial implementation may use prebuilt indexed-grid edge/stitch variants and conservative skirts; it must not rely on a fragment discard to hide geometry gaps. Geomorphing is optional only after its transition versioning and temporal behaviour are validated.
- Skirt depth, water handoff, and unavailable-neighbour behaviour are part of the tile draw constants, not shader guesses. Existing CPU helpers in
  [`lod_seam.zig`](../../modules/world-lod/src/lod_seam.zig) and
  [`lod_geometry.zig`](../../modules/world-lod/src/lod_geometry.zig) are the behavioural reference to test against, not a guarantee that their current CPU mutation algorithm can be copied unchanged.

## CPU and GPU responsibilities

| CPU-authoritative work | GPU work for the selected path |
| --- | --- |
| Procedural sampling, chunk-derived ingestion, edit merge/provenance precedence, source persistence, invalidation, LOD hierarchy/readiness, parent fallback, coverage policy, and choosing a tile/edge variant. | Vertex-pull compact terrain samples from the reusable grid, decode heights/material attributes, calculate local normals from the apron, rasterize terrain, and submit the already-established indirect draw stream. |
| Build/version compact records; enqueue bounded uploads and tile replacement; retain CPU source until the new GPU version is known safe. | Render far water as a separate compact grid/indirect stream and apply far-only shading. GPU culling may reject CPU-approved candidates, but does not decide hierarchy correctness. |
| Determine whether a source requires the CPU mesh fallback; respond to unsupported hardware and validation failures. | No procedural world generation, persistence, edit conflict resolution, source-of-truth mutation, or GPU-to-CPU readback in normal operation. |

### Far water

Far water uses the tile's separate water-surface semantics and a flat/reduced grid. It is a distinct terrain-adjacent pass so opaque terrain does not need water vertices. Its first production shader must use fog, a stable water colour/depth category, inexpensive animated normal/specular treatment, and the shared edge policy. It must avoid unnecessary screen-space reflections, reflection-buffer sampling, and scene-depth/depth-thickness work for the far tier. Near water retains the existing quality path in
[`assets/shaders/vulkan/water.frag`](../../assets/shaders/vulkan/water.frag); this decision does not remove it.

## Lifetime and synchronization

Compact input tiles, tile-instance/indirection records, and the reusable grid have separate lifetimes.

1. Workers produce immutable CPU tile versions from an immutable source snapshot. They do not call RHI or mutate a record visible to the render thread.
2. The render thread allocates a device-local tile range, stages the complete new version, writes it into a frame-safe instance/indirection slot, and records the required transfer-to-shader-read barrier before the draw/compute use.
3. CPU hierarchy readiness publishes the new version only after its upload has been submitted with an associated submission/timeline value. Until then it draws the old version or the parent/CPU fallback; it never points an indirect draw at partially uploaded storage.
4. Replaced or evicted ranges, descriptor/instance entries, and staging allocations are retired only after the last graphics or compute submission that can reference them has completed. Retirements are bounded, accounted for, and reclaimed by completed fence/timeline values—not `vkDeviceWaitIdle` during streaming.
5. Pool/atlas growth uses a new backing allocation and preserves old bindings until their retirement value completes. It must not require CPU shadow copies of expanded vertices. Shutdown remains the only permitted whole-device idle boundary.

This extends the Phase 2 deferred-deletion intent to compact resources. It must also work with the existing frames-in-flight policy and the Phase 3 compute-to-indirect/storage ordering. A device loss, upload failure, allocator exhaustion, ABI mismatch, or compact-path validation failure leaves the prior safe draw active where possible and otherwise returns the region to the CPU mesh/parent fallback state.

## Feature gates and fallback

The feature is opt-in during rollout and is selected per device and per region. The exact public setting name may be chosen with the implementation, but it must expose `off`, `auto`, and `force` semantics and report the selected path/reason in diagnostics. Existing controls such as `ZIGCRAFT_LOD_GPU_CULLING`, `ZIGCRAFT_DISABLE_LOD_MDI`, `ZIGCRAFT_LOD_MESH_PATH_SPANS`, and `ZIGCRAFT_LOD_MESH_PATH_QEM` continue to exercise their current paths; they are not redefined by this decision.

`auto` enables compact tiles only when the backend can create and bind the required storage buffers, supports the conventional graphics/indirect route used by the selected renderer, has sufficient descriptor/range limits for the configured tile pool, and passes startup ABI/shader self-checks. `force` is a diagnostic mode: it may fail visibly in logs and fall back, but must never disable the fallback or manufacture support. Mesh-shader availability is a separate capability and cannot enable the first production path.

The maintained fallback is the present CPU-generated `LODMesh` heightfield path, through direct draws or MDI/CPU visibility as supported. It remains covered by unit, integration, and visual tests. LOD0–2 stay on their current quality paths; unsupported compact features (notably span/overhang source data) also use this fallback. The fallback is a release requirement, not a temporary debug option.

## Phased rollout and validation gates

### A. Foundation: ABI and accounting

- Add pure CPU encode/decode tests for every semantic, alignment/offset assertion for the GPU view, version rejection, quantization error bounds, and identical shared-edge decoding.
- Add source-to-tile provenance/edit invalidation tests using `LODSimplifiedData`; do not alter persistence format yet.
- Add compact-specific counters: submitted/uploaded tile bytes, resident/allocated/free/retired tile bytes, tile count by LOD/state, tile replacement count, apron-missing/fallback count, and CPU fallback reason. Keep expanded CPU mesh and compact tile memory distinct.
- Add GPU timestamp scopes for compact terrain vertex/raster work and far water, plus optional vertex-pulling/expansion scope if a compute prototype exists. Report these separately from Phase 3 culling and the existing terrain pass.

**Gate:** ABI tests pass; accounting includes live plus retired compact allocations; the feature is off by default; normal operation makes no GPU readback and no streaming `waitIdle`.

### B. Reusable-grid terrain prototype

- Add a shared indexed grid and compact-tile storage/instance binding without changing CPU hierarchy or Phase 3 candidate approval.
- Render a single LOD3/4 tile beside the CPU reference using deterministic source data. Compare decoded heights, material/tint selection, water classification, and normal direction in a debug mode.
- Exercise direct and MDI submission, as well as CPU and GPU-culling selection, without requiring GPU culling to be active.

**Gate:** GPU and CPU reference images show no unacceptable height displacement, material mismatch, or normal discontinuity; fallback renders if any capability or tile validation check fails; shader validation and RHI contract tests pass.

### C. Edges, hierarchy, water, and edits

- Enable adjacent same-level tiles with aprons, then cross-LOD edge variants/skirting and parent-child transition coverage.
- Add the simplified far-water pass and test water-to-terrain as well as water-to-water edges.
- Test rapid edits, chunk-derived ingestion, replacement-before-use, eviction while in flight, teleport, save/reload, and stale job/token rejection. Record edit-to-visible-version latency; do not set a target before baseline data exists.

**Gate:** the visual matrix in [`docs/benchmarks/README.md`](../benchmarks/README.md) finds no unacceptable cracks, holes, normal seams, transition instability, stale edit, water artifact, or full-detail handoff regression. GPU validation reports no lifetime/barrier errors and retirement stays bounded.

### D. Measured production decision

Run comparable fixed-seed, fixed-preset, fixed-render-distance `stationary`, `traversal`, `rapid-turn`, and `teleport-eviction` scenarios, using the documented headless commands and recording build mode and hardware. Compare compact and CPU paths using:

- per-LOD and total upload bytes, pending upload bytes, worker mesh-construction time, compact encode time, and edit replacement latency;
- compact resident/allocated/retired VRAM, CPU source memory, CPU-expanded vertex memory, grid/index memory, and staging pressure;
- compact terrain/water GPU timestamp cost, frame p50/p95/p99 and worst-frame attribution, draw/indirect counts, candidate/visible/rejected counts, and shader bandwidth proxies available from the profiler; and
- visual captures from the documented seam, transition, water, fog, and full-detail-handoff matrix on supported and fallback devices.

**Gate:** demonstrate, with recorded artifacts rather than assumed ratios, materially lower LOD3/4 upload bytes and resident geometry memory than the comparable CPU-expanded baseline; eliminate or substantially reduce far-level worker mesh time; preserve visual quality; and keep the fallback functional. The existing benchmark regression/SLO policy remains a guardrail, but it is not evidence by itself that compact tiles are beneficial on player hardware.

### E. Default enablement and follow-ups

Default `auto` only after the preceding gate succeeds on the supported-device matrix and long-running robustness runs show bounded resource retirement. Keep `off` available for bisecting. Re-evaluate compute expansion only if measurements identify vertex-pulling bandwidth, topology limits, or raster work as the next constraint. Re-evaluate mesh shaders only as an optional specialization with the conventional path still maintained.

## Consequences

This choice reduces the first implementation's scope to a compact heightfield ABI, a reusable grid, shader vertex pulling, and resource lifetime integration. It preserves the existing CPU source, persistence, hierarchy, MDI, and GPU-culling investments, and makes quality knobs such as sample density, material aggregation, water, and vegetation independent of raw expanded-vertex uploads.

It also introduces a durable ABI, tile allocator, descriptor/instance versioning, new shader variants, and visual boundary obligations. The work must not be described as complete merely because this decision document or its foundation code lands: issue #917's renderer, metrics, visual validation, and maintained fallback gates remain implementation work.

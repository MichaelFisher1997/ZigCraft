pub const LODLevel = @import("engine-core").LODLevel;

/// State for LOD chunks/regions.
pub const LODState = enum {
    missing,
    queued_for_generation,
    generating,
    generated,
    queued_for_mesh,
    meshing,
    mesh_ready,
    uploading,
    renderable,
    unloading,
};

pub const ChunkStateCounts = struct {
    total: u32 = 0,
    missing: u32 = 0,
    generating: u32 = 0,
    meshing: u32 = 0,
    renderable: u32 = 0,
    other_states: u32 = 0,
    dirty: u32 = 0,
};

pub const WorldStateData = struct {
    generator_name: []const u8,
    seed: u64,
    gen_queue: u32,
    mesh_queue: u32,
    upload_queue: u32,
};

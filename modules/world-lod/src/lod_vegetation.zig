//! Vegetation and canopy helper surface for LOD mesh generation.

const geom = @import("lod_geometry.zig");

pub const LOD_TREE_COVERAGE_THRESHOLD = geom.LOD_TREE_COVERAGE_THRESHOLD;

pub const addTreeCanopyColumn = geom.addTreeCanopyColumn;
pub const addTreeColumn = geom.addTreeColumn;
pub const foldedCanopyColumnForLOD = geom.foldedCanopyColumnForLOD;
pub const representativeVegetationForLOD = geom.representativeVegetationForLOD;
pub const shouldRenderLODTree = geom.shouldRenderLODTree;

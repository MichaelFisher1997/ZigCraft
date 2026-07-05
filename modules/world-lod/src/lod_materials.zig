//! Material, tint, and color-selection helpers for LOD mesh generation.

const geom = @import("lod_geometry.zig");

pub const LODTextureFace = geom.LODTextureFace;

pub const ambient_occlusion_for_lod = geom.ambient_occlusion_for_lod;
pub const applyColorBrightness = geom.applyColorBrightness;
pub const applyTextureLuminance = geom.applyTextureLuminance;
pub const averageColor = geom.averageColor;
pub const blockForLODQuad = geom.blockForLODQuad;
pub const cell_color_for_lod = geom.cell_color_for_lod;
pub const getLodSideTile = geom.getLodSideTile;
pub const getLodTopColor = geom.getLodTopColor;
pub const getLodTopTile = geom.getLodTopTile;
pub const isLeafBlock = geom.isLeafBlock;
pub const packBlockDefaultColor = geom.packBlockDefaultColor;
pub const selectCellMaterial = geom.selectCellMaterial;
pub const terrainBlockForLODQuadForLOD = geom.terrainBlockForLODQuadForLOD;
pub const tintColorForLodFace = geom.tintColorForLodFace;
pub const unpackB = geom.unpackB;
pub const unpackG = geom.unpackG;
pub const unpackR = geom.unpackR;

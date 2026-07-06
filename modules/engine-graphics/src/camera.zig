//! FPS-style camera with mouse look and WASD movement.

const std = @import("std");
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;

pub const Camera = struct {
    pub const MovementVector = struct { x: f32, z: f32 };

    // 4-tap Halton(2,3) sequence centered to [-0.5, 0.5] pixel offsets.
    // We keep this to 4 samples to keep temporal convergence fast while matching
    // the current low-latency TAA target (minimal history lag and ghosting).
    const JITTER_SEQUENCE = [_][2]f32{
        .{ 0.0, -0.16666667 },
        .{ -0.25, 0.16666667 },
        .{ 0.25, -0.3888889 },
        .{ -0.375, -0.055555556 },
    };

    position: Vec3,

    /// Yaw in radians (rotation around Y axis)
    yaw: f32,

    /// Pitch in radians (rotation around X axis)
    pitch: f32,

    /// Field of view in radians
    fov: f32,

    /// Near clipping plane
    near: f32,

    /// Far clipping plane
    far: f32,

    /// Movement speed in units per second
    move_speed: f32,

    /// Mouse sensitivity
    sensitivity: f32,

    // Cached vectors (updated when rotation changes)
    forward: Vec3,
    right: Vec3,
    up: Vec3,
    jitter_index: usize,

    pub const Config = struct {
        position: Vec3 = Vec3.init(0, 0, 3),
        yaw: f32 = -std.math.pi / 2.0, // Looking toward -Z
        pitch: f32 = 0,
        fov: f32 = std.math.degreesToRadians(70.0),
        near: f32 = 0.03,
        far: f32 = 10000.0, // Increased for large render distances
        move_speed: f32 = 5.0,
        sensitivity: f32 = 0.002,
    };

    pub fn init(config: Config) Camera {
        var cam = Camera{
            .position = config.position,
            .yaw = config.yaw,
            .pitch = config.pitch,
            .fov = config.fov,
            .near = config.near,
            .far = config.far,
            .move_speed = config.move_speed,
            .sensitivity = config.sensitivity,
            .forward = Vec3.zero,
            .right = Vec3.zero,
            .up = Vec3.zero,
            .jitter_index = 0,
        };
        cam.updateVectors();
        return cam;
    }

    pub fn resetJitter(self: *Camera) void {
        self.jitter_index = 0;
    }

    pub fn advanceJitter(self: *Camera) void {
        self.jitter_index = (self.jitter_index + 1) % JITTER_SEQUENCE.len;
    }

    fn currentJitterPixel(self: *const Camera, enabled: bool) [2]f32 {
        if (!enabled) return .{ 0.0, 0.0 };
        return JITTER_SEQUENCE[self.jitter_index];
    }

    /// Set camera orientation directly and refresh cached axes.
    pub fn setYawPitch(self: *Camera, yaw: f32, pitch: f32) void {
        self.yaw = yaw;
        self.pitch = pitch;
        self.updateVectors();
    }

    fn updateVectors(self: *Camera) void {
        // Calculate forward vector from yaw and pitch
        self.forward = Vec3.init(
            std.math.cos(self.yaw) * std.math.cos(self.pitch),
            std.math.sin(self.pitch),
            std.math.sin(self.yaw) * std.math.cos(self.pitch),
        ).normalize();

        // Right = forward cross world up
        self.right = self.forward.cross(Vec3.up).normalize();

        // Up = right cross forward
        self.up = self.right.cross(self.forward).normalize();
    }

    /// Get view matrix
    pub fn getViewMatrix(self: *const Camera) Mat4 {
        const target = self.position.add(self.forward);
        return Mat4.lookAt(self.position, target, Vec3.up);
    }

    /// Get projection matrix
    pub fn getProjectionMatrix(self: *const Camera, aspect_ratio: f32) Mat4 {
        // Standard perspective for compatibility
        return Mat4.perspective(self.fov, aspect_ratio, self.near, self.far);
    }

    pub fn getProjectionMatrixReverseZ(self: *const Camera, aspect_ratio: f32) Mat4 {
        return Mat4.perspectiveReverseZ(self.fov, aspect_ratio, self.near, self.far);
    }

    pub fn getJitteredProjectionMatrixReverseZ(self: *const Camera, aspect_ratio: f32, viewport_width: f32, viewport_height: f32, jitter_enabled: bool) Mat4 {
        const base_projection = self.getProjectionMatrixReverseZ(aspect_ratio);
        if (!jitter_enabled or viewport_width <= 0.0 or viewport_height <= 0.0) {
            return base_projection;
        }

        const jitter = self.currentJitterPixel(jitter_enabled);
        const jitter_x_ndc = (jitter[0] * 2.0) / viewport_width;
        const jitter_y_ndc = (jitter[1] * 2.0) / viewport_height;
        const jitter_matrix = Mat4.translate(Vec3.init(jitter_x_ndc, jitter_y_ndc, 0.0));
        return jitter_matrix.multiply(base_projection);
    }

    /// Get view matrix centered at origin (for floating origin rendering)
    /// Camera is conceptually at origin looking in the forward direction
    pub fn getViewMatrixOriginCentered(self: *const Camera) Mat4 {
        // View matrix with camera at origin - just rotation, no translation
        const target = self.forward;
        return Mat4.lookAt(Vec3.zero, target, Vec3.up);
    }

    /// Get combined view-projection matrix for floating origin rendering
    /// Use this with camera-relative chunk positions
    pub fn getViewProjectionMatrixOriginCentered(self: *const Camera, aspect_ratio: f32) Mat4 {
        return self.getProjectionMatrix(aspect_ratio).multiply(self.getViewMatrixOriginCentered());
    }

    /// Get inverse view-projection matrix for sky rendering
    /// Used to reconstruct world directions from clip space
    pub fn getInvViewProjectionMatrix(self: *const Camera, aspect_ratio: f32) Mat4 {
        const view_proj = self.getViewProjectionMatrixOriginCentered(aspect_ratio);
        return view_proj.inverse();
    }
};

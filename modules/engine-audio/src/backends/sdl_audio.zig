//! SDL3 Audio Backend with Software 3D Mixer.

const std = @import("std");
const sync = @import("sync");
const c = @import("c").c;
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const Vec3 = @import("engine-math").Vec3;
const log = @import("engine-core").log;

pub const AudioConfig = struct {
    // Currently, these values are informational as the backend uses static limits.
    // In the future, we can use these to allocate dynamic buffers.
    max_voices: u32 = MAX_VOICES,
    mix_rate: u32 = MIX_RATE,
    mix_channels: u8 = MIX_CHANNELS,
};

pub const MAX_VOICES = 64;
pub const MIX_RATE = 44100;
pub const MIX_CHANNELS = 2; // Stereo
pub const MIX_FORMAT = c.SDL_AUDIO_S16;

const Voice = struct {
    active: bool = false,
    sound_data: ?*const types.SoundData = null,
    cursor: f32 = 0.0, // Sample index (float for pitch shifting)

    // Playback properties
    loop: bool = false,
    pitch: f32 = 1.0,
    base_volume: f32 = 1.0,
    category: types.SoundCategory = .sfx,

    // Spatial properties
    is_spatial: bool = false,
    position: Vec3 = Vec3.init(0, 0, 0),
    min_dist: f32 = 1.0,
    max_dist: f32 = 50.0,

    // Calculated per frame
    effective_volume_l: f32 = 1.0,
    effective_volume_r: f32 = 1.0,

    // Priority/Age for stealing
    start_time: i64 = 0, // Ticks when started
    id: u32 = 0,
    generation: u64 = 0,
};

/// One decoded source frame, expressed as a stereo pair of S16-scaled float
/// samples (range roughly [-32768, 32767]). This is independent of the source's
/// native format/channel count; format conversion and channel routing happen in
/// `readSourceFrame`.
const StereoSample = struct { l: f32, r: f32 };

/// Number of bytes a single (per-channel) sample occupies for `format`.
fn bytesPerSample(format: types.AudioFormat) usize {
    return switch (format) {
        .unsigned8 => 1,
        .signed16 => 2,
        .float32 => 4,
    };
}

/// Reads a single sample (one channel) at byte offset `byte_off` from `buf`,
/// converting it to an S16-scaled float value regardless of the source format.
/// The output scale matches the i32 mix accumulators so every format mixes at
/// consistent loudness before final clipping to i16.
fn readSampleAt(buf: []const u8, format: types.AudioFormat, byte_off: usize) f32 {
    return switch (format) {
        .unsigned8 => blk: {
            // Unsigned 8-bit is centered at 128. Center it and scale to the
            // signed 16-bit range so it mixes at the same loudness as S16 data.
            const u: u8 = buf[byte_off];
            const centered: i16 = @as(i16, u) - 128; // [-128, 127]
            const s16: i16 = centered * 256; // [-32768, 32512]
            break :blk @floatFromInt(s16);
        },
        .signed16 => blk: {
            const sample: i16 = std.mem.readInt(i16, buf[byte_off..][0..2], .little);
            break :blk @floatFromInt(sample);
        },
        .float32 => blk: {
            const bits: u32 = std.mem.readInt(u32, buf[byte_off..][0..4], .little);
            const f: f32 = @bitCast(bits);
            // Guard against NaN/inf which would produce undefined behavior
            // when converted to the i32 accumulators via @intFromFloat.
            if (!std.math.isFinite(f)) break :blk 0.0;
            const clamped: f32 = std.math.clamp(f, -1.0, 1.0);
            break :blk clamped * 32767.0;
        },
    };
}

/// Reads one source frame at frame index `frame_idx` and returns it as a stereo
/// pair of S16-scaled float samples.
///
/// Channel routing:
///   - mono (1 ch): single sample duplicated to both outputs
///   - stereo (2 ch): left and right samples kept separate
///   - 3+ channels: folded to stereo using the first two channels
///
/// Returns null when the frame is out of bounds (or the source is empty /
/// malformed), so callers can handle looping or voice stop without indexing
/// past the buffer. This is the single source of truth for source sample
/// interpretation; `mix()` must never read `data.buffer` directly.
fn readSourceFrame(data: *const types.SoundData, frame_idx: usize) ?StereoSample {
    const bps = bytesPerSample(data.format);
    const src_channels: usize = if (data.channels == 0) 1 else data.channels;
    const frame_bytes = bps * src_channels;

    const buf = data.buffer;
    if (buf.len == 0 or frame_bytes == 0) return null;

    // Overflow-safe bounds check for the whole frame.
    const start_ov = @mulWithOverflow(frame_idx, frame_bytes);
    if (start_ov[1] != 0) return null;
    const end_ov = @addWithOverflow(start_ov[0], frame_bytes);
    if (end_ov[1] != 0) return null;
    if (end_ov[0] > buf.len) return null;

    const start = start_ov[0];
    const l = readSampleAt(buf, data.format, start);
    const r = if (src_channels >= 2)
        readSampleAt(buf, data.format, start + bps)
    else
        l;

    return .{ .l = l, .r = r };
}

const Mixer = struct {
    /// Mutex protecting all mixer state.
    /// Acquired by all public methods: play, stop, update, mix.
    /// Safe to call from any thread (Main or Audio Callback).
    mutex: sync.Mutex = .{},
    voices: [MAX_VOICES]Voice = undefined,
    voice_generation_counter: u64 = 1,
    master_volume: f32 = 1.0,
    music_volume: f32 = 0.5,
    sfx_volume: f32 = 1.0,
    ambient_volume: f32 = 1.0,

    listener_pos: Vec3 = Vec3.zero,
    listener_fwd: Vec3 = Vec3.init(0, 0, 1),
    listener_up: Vec3 = Vec3.init(0, 1, 0),
    listener_right: Vec3 = Vec3.init(1, 0, 0),

    pub fn init() Mixer {
        return .{
            .voices = [_]Voice{.{}} ** MAX_VOICES,
        };
    }

    pub fn play(self: *Mixer, sound: *const types.SoundData, config: types.PlayConfig) types.VoiceHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        var oldest_idx: usize = 0;
        var oldest_time: i64 = std.math.maxInt(i64);
        var found_slot = false;

        // Find free voice or oldest voice
        for (&self.voices, 0..) |*voice, i| {
            if (!voice.active) {
                oldest_idx = i;
                found_slot = true;
                break;
            }
            if (voice.start_time < oldest_time) {
                oldest_time = voice.start_time;
                oldest_idx = i;
            }
        }

        // Voice stealing if full (or just picking the free one found)
        const voice = &self.voices[oldest_idx];
        const gen = self.voice_generation_counter;
        // Check for overflow (extremely unlikely with u64, but for correctness)
        if (self.voice_generation_counter == std.math.maxInt(u64)) {
            self.voice_generation_counter = 1;
        } else {
            self.voice_generation_counter += 1;
        }

        voice.* = .{
            .active = true,
            .sound_data = sound,
            .cursor = 0.0,
            .loop = config.loop,
            .pitch = config.pitch,
            .base_volume = std.math.clamp(config.volume, 0.0, 1.0),
            .category = config.category,
            .is_spatial = config.is_spatial,
            .position = config.position,
            .min_dist = config.min_distance,
            .max_dist = config.max_distance,
            .start_time = @intCast(c.SDL_GetTicksNS()),
            .id = @intCast(oldest_idx),
            .generation = gen,
        };
        // Initial update to set volume
        self.updateVoiceSpatial(voice);

        return .{ .id = @intCast(oldest_idx), .generation = gen };
    }

    pub fn stopVoice(self: *Mixer, handle: types.VoiceHandle) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (handle.id >= MAX_VOICES) return;
        const voice = &self.voices[handle.id];

        if (voice.active and voice.generation == handle.generation) {
            voice.active = false;
        } else if (voice.active) {
            log.log.debug("stopVoice: generation mismatch (req: {}, act: {}), ignoring.", .{ handle.generation, voice.generation });
        }
    }

    fn updateVoiceSpatial(self: *Mixer, voice: *Voice) void {
        var vol = voice.base_volume * self.master_volume;

        // Apply category volume
        switch (voice.category) {
            .master => {}, // Already applied
            .music => vol *= self.music_volume,
            .sfx => vol *= self.sfx_volume,
            .ambient => vol *= self.ambient_volume,
        }

        if (voice.is_spatial) {
            const to_sound = voice.position.sub(self.listener_pos);
            const dist = to_sound.length();

            // Attenuation (Inverse Distance Clamped)
            var attenuation: f32 = 1.0;
            if (dist > voice.min_dist) {
                const range = @max(0.1, voice.max_dist - voice.min_dist);
                attenuation = 1.0 - std.math.clamp((dist - voice.min_dist) / range, 0.0, 1.0);
                // Square it for smoother falloff
                attenuation *= attenuation;
            }

            // Panning
            var pan: f32 = 0.0; // -1.0 left, 1.0 right
            if (dist > 0.001) {
                // Normalize manually to avoid edge cases if vec3 implementation is not robust
                // But we checked dist > 0.001, so to_sound length is safe.
                // However, double check before normalize is good practice.
                if (to_sound.lengthSquared() > 0.000001) {
                    const dir = to_sound.normalize();
                    pan = dir.dot(self.listener_right);
                }
            }

            // Stereo balance (Unity-style: Center=1.0, Hard Pan=1.0 on one side)
            var pan_l: f32 = 1.0;
            var pan_r: f32 = 1.0;

            if (pan > 0) {
                pan_l = 1.0 - pan;
            } else {
                pan_r = 1.0 + pan;
            }

            voice.effective_volume_l = vol * attenuation * pan_l;
            voice.effective_volume_r = vol * attenuation * pan_r;
        } else {
            voice.effective_volume_l = vol;
            voice.effective_volume_r = vol;
        }
    }

    pub fn update(self: *Mixer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.listener_right = self.listener_fwd.cross(self.listener_up).normalize();

        for (&self.voices) |*voice| {
            if (voice.active) {
                self.updateVoiceSpatial(voice);
            }
        }
    }

    // Mix samples into the output buffer (S16 stereo)
    pub fn mix(self: *Mixer, stream: *c.SDL_AudioStream, _: c_int) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // We only mix if we need more data. SDL3 stream buffers for us.
        // But here we are just pushing data.

        // Let's create a temporary buffer on stack or heap to mix into
        const SAMPLES_TO_MIX = 1024; // Small chunks
        var mix_buf: [SAMPLES_TO_MIX * 2]i32 = [_]i32{0} ** (SAMPLES_TO_MIX * 2); // 32-bit accumulator to prevent clip

        // Check if any voice is active
        var any_active = false;
        for (self.voices) |v| {
            if (v.active) {
                any_active = true;
                break;
            }
        }

        if (!any_active) {
            // Push silence
            const silence = [_]i16{0} ** (SAMPLES_TO_MIX * 2);
            _ = c.SDL_PutAudioStreamData(stream, &silence, silence.len * 2);
            return;
        }

        // Mix
        for (&self.voices) |*voice| {
            if (!voice.active) continue;

            // Critical Issue 1: Null check
            if (voice.sound_data == null) {
                voice.active = false;
                continue;
            }

            const data = voice.sound_data.?;

            var i: usize = 0;
            while (i < SAMPLES_TO_MIX) : (i += 1) {
                // Nearest-neighbor resampling. The cursor is a frame index into
                // the source buffer (see readSourceFrame for frame sizing).
                const pos_idx = @as(usize, @intFromFloat(voice.cursor));

                // readSourceFrame validates the source format, channel count,
                // and byte bounds. It returns null when the cursor has reached
                // or passed the end of the buffer (or the source is empty /
                // malformed), so we never index past `data.buffer` here.
                if (readSourceFrame(data, pos_idx)) |frame| {
                    mix_buf[i * 2] += @intFromFloat(frame.l * voice.effective_volume_l);
                    mix_buf[i * 2 + 1] += @intFromFloat(frame.r * voice.effective_volume_r);
                    voice.cursor += voice.pitch;
                } else if (voice.loop) {
                    // Wrap to the start and retry once so looping voices emit
                    // continuous audio instead of a frame of silence.
                    voice.cursor = 0.0;
                    if (readSourceFrame(data, 0)) |frame| {
                        mix_buf[i * 2] += @intFromFloat(frame.l * voice.effective_volume_l);
                        mix_buf[i * 2 + 1] += @intFromFloat(frame.r * voice.effective_volume_r);
                        voice.cursor += voice.pitch;
                    } else {
                        // Empty/invalid source: cannot loop, give up on voice.
                        voice.active = false;
                        break;
                    }
                } else {
                    voice.active = false;
                    break;
                }
            }
        }

        // Clip and Convert to output
        var out_buf: [SAMPLES_TO_MIX * 2]i16 = undefined;
        var i: usize = 0;
        while (i < SAMPLES_TO_MIX * 2) : (i += 1) {
            out_buf[i] = @intCast(std.math.clamp(mix_buf[i], -32767, 32767));
        }

        _ = c.SDL_PutAudioStreamData(stream, &out_buf, out_buf.len * 2);
    }

    pub fn stopAll(self: *Mixer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.voices) |*voice| {
            voice.active = false;
        }
    }
};

pub const SDLAudioError = error{
    SDLInitFailed,
    SDLStreamFailed,
};

pub const SDLAudioBackend = struct {
    backend: backend.IAudioBackend, // Interface wrapper
    allocator: std.mem.Allocator,
    stream: *c.SDL_AudioStream,
    mixer: *Mixer,

    pub const CreateError = std.mem.Allocator.Error || SDLAudioError;

    pub fn create(allocator: std.mem.Allocator, config: AudioConfig) CreateError!*SDLAudioBackend {
        // We accept config to adhere to the interface/pattern, even if we don't use it yet
        // for dynamic allocation (using static MAX_VOICES for now).
        _ = config;

        // Init SDL Audio if not already
        if (c.SDL_WasInit(c.SDL_INIT_AUDIO) == 0) {
            if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
                log.log.err("Failed to init SDL Audio: {s}", .{c.SDL_GetError()});
                return SDLAudioError.SDLInitFailed;
            }
        }

        // Create Stream
        const spec = c.SDL_AudioSpec{
            .format = MIX_FORMAT,
            .channels = MIX_CHANNELS,
            .freq = MIX_RATE,
        };

        const stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
        if (stream == null) {
            log.log.err("Failed to open audio stream: {s}", .{c.SDL_GetError()});
            return SDLAudioError.SDLStreamFailed;
        }
        errdefer _ = c.SDL_DestroyAudioStream(stream);

        const mixer = try allocator.create(Mixer);
        errdefer allocator.destroy(mixer);
        mixer.* = Mixer.init();

        const self = try allocator.create(SDLAudioBackend);
        self.* = .{
            .backend = .{
                .ptr = self,
                .vtable = &vtable,
            },
            .allocator = allocator,
            .stream = stream.?,
            .mixer = mixer,
        };

        // Start playback
        _ = c.SDL_ResumeAudioDevice(c.SDL_GetAudioStreamDevice(stream));

        return self;
    }

    pub fn destroy(self: *SDLAudioBackend) void {
        _ = c.SDL_DestroyAudioStream(self.stream);
        self.allocator.destroy(self.mixer);
        self.allocator.destroy(self);
    }

    pub fn stopAllVoices(self: *SDLAudioBackend) void {
        self.mixer.stopAll();
    }

    // IAudioBackend impl

    /// Update logic, called from the main thread usually.
    fn update(ptr: *anyopaque) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.update();

        // Keep buffer fed
        // Check how much is queued
        const queued = c.SDL_GetAudioStreamQueued(self.stream);
        const MIN_QUEUED = MIX_RATE * MIX_CHANNELS * 2 / 10; // 100ms

        if (queued < MIN_QUEUED) {
            // mix() acquires the mutex internally.
            // Note: In this architecture, mix() is called from the main thread to push data.
            // The Mixer struct is protected by a mutex to allow safe concurrent access if we
            // later move mixing to the audio callback thread or another worker thread.
            self.mixer.mix(self.stream, 0);
        }
    }

    fn setListener(ptr: *anyopaque, pos: Vec3, fwd: Vec3, up: Vec3) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.mutex.lock();
        defer self.mixer.mutex.unlock();
        self.mixer.listener_pos = pos;
        self.mixer.listener_fwd = fwd;
        self.mixer.listener_up = up;
        self.mixer.listener_right = fwd.cross(up).normalize();
    }

    fn playSound(ptr: *anyopaque, sound: *const types.SoundData, config: types.PlayConfig) types.VoiceHandle {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        return self.mixer.play(sound, config);
    }

    fn stopVoice(ptr: *anyopaque, handle: types.VoiceHandle) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.stopVoice(handle);
    }

    fn stopAll(ptr: *anyopaque) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.stopAll();
    }

    fn setMasterVolume(ptr: *anyopaque, vol: f32) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.mutex.lock();
        defer self.mixer.mutex.unlock();
        self.mixer.master_volume = std.math.clamp(vol, 0.0, 1.0);
    }

    fn setCategoryVolume(ptr: *anyopaque, cat: types.SoundCategory, vol: f32) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.mutex.lock();
        defer self.mixer.mutex.unlock();
        const clamped = std.math.clamp(vol, 0.0, 1.0);

        switch (cat) {
            .master => self.mixer.master_volume = clamped,
            .music => self.mixer.music_volume = clamped,
            .sfx => self.mixer.sfx_volume = clamped,
            .ambient => self.mixer.ambient_volume = clamped,
        }
    }

    const vtable = backend.IAudioBackend.VTable{
        .update = update,
        .setListener = setListener,
        .playSound = playSound,
        .stopVoice = stopVoice,
        .stopAll = stopAll,
        .setMasterVolume = setMasterVolume,
        .setCategoryVolume = setCategoryVolume,
    };
};

// ---------------------------------------------------------------------------
// Tests for source sample decoding (Issue #731).
//
// These cover the format/channel handling that mix() now delegates to
// readSourceFrame. They require no SDL/audio device: the helpers are pure.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bytesPerSample matches format sizes" {
    try testing.expectEqual(@as(usize, 1), bytesPerSample(.unsigned8));
    try testing.expectEqual(@as(usize, 2), bytesPerSample(.signed16));
    try testing.expectEqual(@as(usize, 4), bytesPerSample(.float32));
}

test "readSourceFrame mono S16 reads correct value and duplicates to both channels" {
    // Two mono S16 samples: 100, -200
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 100, .little);
    std.mem.writeInt(i16, buf[2..4], -200, .little);
    const data = types.SoundData{
        .buffer = &buf,
        .frequency = 44100,
        .channels = 1,
        .format = .signed16,
        .length_samples = 2,
    };

    const f0 = readSourceFrame(&data, 0).?;
    try testing.expectEqual(@as(f32, 100.0), f0.l);
    try testing.expectEqual(@as(f32, 100.0), f0.r);

    const f1 = readSourceFrame(&data, 1).?;
    try testing.expectEqual(@as(f32, -200.0), f1.l);
    try testing.expectEqual(@as(f32, -200.0), f1.r);

    // Out of bounds -> null (no buffer overrun).
    try testing.expect(readSourceFrame(&data, 2) == null);
}

test "readSourceFrame stereo S16 keeps left/right channel separation" {
    // One stereo frame: L=500, R=-500
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 500, .little);
    std.mem.writeInt(i16, buf[2..4], -500, .little);
    const data = types.SoundData{
        .buffer = &buf,
        .frequency = 44100,
        .channels = 2,
        .format = .signed16,
        .length_samples = 1,
    };

    const f = readSourceFrame(&data, 0).?;
    try testing.expectEqual(@as(f32, 500.0), f.l);
    try testing.expectEqual(@as(f32, -500.0), f.r);

    // Second frame is out of bounds even though there are 4 bytes, because a
    // stereo frame consumes 4 bytes per frame.
    try testing.expect(readSourceFrame(&data, 1) == null);
}

test "readSourceFrame mono unsigned8 scales to S16 range with 128 as silence" {
    // unsigned8: 128 == silence (0), 255 == max positive, 0 == max negative
    var buf = [_]u8{ 128, 255, 0 };
    const data = types.SoundData{
        .buffer = &buf,
        .frequency = 8000,
        .channels = 1,
        .format = .unsigned8,
        .length_samples = 3,
    };

    const silence = readSourceFrame(&data, 0).?;
    try testing.expectEqual(@as(f32, 0.0), silence.l);
    try testing.expectEqual(@as(f32, 0.0), silence.r);

    const max_pos = readSourceFrame(&data, 1).?;
    try testing.expectEqual(@as(f32, 127.0 * 256.0), max_pos.l);

    const max_neg = readSourceFrame(&data, 2).?;
    try testing.expectEqual(@as(f32, -128.0 * 256.0), max_neg.l);

    try testing.expect(readSourceFrame(&data, 3) == null);
}

test "readSourceFrame float32 converts to S16 scale and clamps out-of-range" {
    // Three mono float32 samples: 0.5, -1.0, 2.0 (over-driven -> clamp to 1.0)
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @bitCast(@as(f32, 0.5)), .little);
    std.mem.writeInt(u32, buf[4..8], @bitCast(@as(f32, -1.0)), .little);
    std.mem.writeInt(u32, buf[8..12], @bitCast(@as(f32, 2.0)), .little);
    const data = types.SoundData{
        .buffer = &buf,
        .frequency = 44100,
        .channels = 1,
        .format = .float32,
        .length_samples = 3,
    };

    const a = readSourceFrame(&data, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5 * 32767.0), a.l, 0.5);

    const b = readSourceFrame(&data, 1).?;
    try testing.expectApproxEqAbs(@as(f32, -32767.0), b.l, 0.5);

    const over = readSourceFrame(&data, 2).?;
    try testing.expectApproxEqAbs(@as(f32, 32767.0), over.l, 0.5);

    try testing.expect(readSourceFrame(&data, 3) == null);
}

test "readSourceFrame stereo float32 preserves channel separation" {
    // One stereo float32 frame: L=0.25, R=-0.75
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @bitCast(@as(f32, 0.25)), .little);
    std.mem.writeInt(u32, buf[4..8], @bitCast(@as(f32, -0.75)), .little);
    const data = types.SoundData{
        .buffer = &buf,
        .frequency = 44100,
        .channels = 2,
        .format = .float32,
        .length_samples = 1,
    };

    const f = readSourceFrame(&data, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25 * 32767.0), f.l, 0.5);
    try testing.expectApproxEqAbs(@as(f32, -0.75 * 32767.0), f.r, 0.5);
    try testing.expect(readSourceFrame(&data, 1) == null);
}

test "readSourceFrame sanitizes NaN float32 data" {
    // A NaN must not reach @intFromFloat (which would be UB). Expect silence.
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0x7FC00000, .little); // quiet NaN
    const data = types.SoundData{
        .buffer = &buf,
        .frequency = 44100,
        .channels = 1,
        .format = .float32,
        .length_samples = 1,
    };

    const f = readSourceFrame(&data, 0).?;
    try testing.expectEqual(@as(f32, 0.0), f.l);
    try testing.expectEqual(@as(f32, 0.0), f.r);
}

test "readSourceFrame rejects empty and malformed sources safely" {
    const empty = types.SoundData{
        .buffer = &[_]u8{},
        .frequency = 44100,
        .channels = 1,
        .format = .signed16,
        .length_samples = 0,
    };
    try testing.expect(readSourceFrame(&empty, 0) == null);

    // channels == 0 is treated as mono (channel 0) rather than crashing.
    var sample: [2]u8 = undefined;
    std.mem.writeInt(i16, &sample, 42, .little);
    const zero_ch = types.SoundData{
        .buffer = &sample,
        .frequency = 44100,
        .channels = 0,
        .format = .signed16,
        .length_samples = 1,
    };
    const f = readSourceFrame(&zero_ch, 0).?;
    try testing.expectEqual(@as(f32, 42.0), f.l);
    try testing.expectEqual(@as(f32, 42.0), f.r);
}

test "readSourceFrame handles large frame index without overflow overrun" {
    // A huge frame index that, when multiplied by frame_bytes, would overflow
    // usize must return null instead of wrapping into a valid-looking offset.
    var sample: [2]u8 = undefined;
    std.mem.writeInt(i16, &sample, 1, .little);
    const data = types.SoundData{
        .buffer = &sample,
        .frequency = 44100,
        .channels = 1,
        .format = .signed16,
        .length_samples = 1,
    };
    try testing.expect(readSourceFrame(&data, std.math.maxInt(usize)) == null);
}

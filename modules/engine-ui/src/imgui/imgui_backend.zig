//! Dear ImGui integration seam.

const build_options = @import("engine_ui_options");
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const sdl = @import("c").c;

pub const available = build_options.imgui;

pub const c = if (build_options.imgui) @cImport({
    @cInclude("cimgui_backend.h");
}) else struct {};

pub const Backend = struct {
    initialized: bool = false,
    has_draw_commands: bool = false,
    imgui: rhi.IImGuiContext = undefined,

    pub fn init(window: *sdl.SDL_Window, rhi_ptr: *rhi.RHI) !Backend {
        if (!build_options.imgui) return error.ImguiDisabled;

        c.ZigCraft_ImGui_CreateContext();
        errdefer c.ZigCraft_ImGui_DestroyContext();
        c.ZigCraft_ImGui_StyleColorsDark();

        const imgui = rhi_ptr.imgui();
        if (!imgui.initBackend(@ptrCast(window))) {
            log.log.err("Failed to initialize ImGui SDL3 backend", .{});
            return error.ImguiBackendInitFailed;
        }
        errdefer imgui.shutdownBackend();

        return .{ .initialized = true, .imgui = imgui };
    }

    pub fn deinit(self: *Backend) void {
        if (!build_options.imgui or !self.initialized) return;
        self.imgui.shutdownBackend();
        c.ZigCraft_ImGui_DestroyContext();
        self.initialized = false;
    }

    pub fn processEvent(event: *const sdl.SDL_Event) void {
        if (!build_options.imgui) return;
        _ = c.ZigCraft_ImGui_ImplSDL3_ProcessEvent(@ptrCast(event));
    }

    pub fn beginFrame(self: *Backend) void {
        if (!build_options.imgui or !self.initialized) return;
        self.imgui.newFrame();
        c.ZigCraft_ImGui_NewFrame();
        self.has_draw_commands = false;
    }

    pub fn markDrawCommands(self: *Backend) void {
        if (!build_options.imgui or !self.initialized) return;
        self.has_draw_commands = true;
    }

    pub fn hasDrawCommands(self: *const Backend) bool {
        return build_options.imgui and self.initialized and self.has_draw_commands;
    }

    pub fn endFrame(self: *Backend) void {
        if (!build_options.imgui or !self.initialized) return;
        c.ZigCraft_ImGui_Render();
        if (!self.has_draw_commands) return;
        self.imgui.renderDrawData(@ptrCast(c.ZigCraft_ImGui_GetDrawData()));
    }
};

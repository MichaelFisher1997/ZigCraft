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

    pub fn init(window: *sdl.SDL_Window, rhi_ptr: *rhi.RHI) !Backend {
        if (!build_options.imgui) return error.ImguiDisabled;

        c.ZigCraft_ImGui_CreateContext();
        c.ZigCraft_ImGui_StyleColorsDark();

        if (!c.ZigCraft_ImGui_ImplSDL3_InitForVulkan(@ptrCast(window))) {
            log.log.err("Failed to initialize ImGui SDL3 backend", .{});
            return error.ImguiBackendInitFailed;
        }

        const native = rhi_ptr.nativeHandles();
        const image_count = native.getSwapchainImageCount();
        var init_info = c.ZigCraftImGuiVulkanInitInfo{
            .instance = @ptrFromInt(native.getInstance()),
            .physical_device = @ptrFromInt(native.getPhysicalDevice()),
            .device = @ptrFromInt(native.getDevice()),
            .queue = @ptrFromInt(native.getQueue()),
            .queue_family = native.getQueueFamily(),
            .descriptor_pool = @ptrFromInt(native.getDescriptorPool()),
            .render_pass = @ptrFromInt(native.getUiRenderPass()),
            .min_image_count = if (image_count > 1) image_count else 2,
            .image_count = if (image_count > 0) image_count else 2,
            .msaa_samples = 1,
        };
        if (!c.ZigCraft_ImGui_ImplVulkan_Init(&init_info)) {
            c.ZigCraft_ImGui_ImplSDL3_Shutdown();
            log.log.err("Failed to initialize ImGui Vulkan backend", .{});
            return error.ImguiBackendInitFailed;
        }

        return .{ .initialized = true };
    }

    pub fn deinit(self: *Backend) void {
        if (!build_options.imgui or !self.initialized) return;
        c.ZigCraft_ImGui_ImplVulkan_Shutdown();
        c.ZigCraft_ImGui_ImplSDL3_Shutdown();
        c.ZigCraft_ImGui_DestroyContext();
        self.initialized = false;
    }

    pub fn processEvent(event: *const sdl.SDL_Event) void {
        if (!build_options.imgui) return;
        _ = c.ZigCraft_ImGui_ImplSDL3_ProcessEvent(@ptrCast(event));
    }

    pub fn beginFrame(self: *Backend) void {
        if (!build_options.imgui or !self.initialized) return;
        c.ZigCraft_ImGui_ImplVulkan_NewFrame();
        c.ZigCraft_ImGui_ImplSDL3_NewFrame();
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

    pub fn endFrame(self: *Backend, command_buffer: u64) void {
        if (!build_options.imgui or !self.initialized) return;
        c.ZigCraft_ImGui_Render();
        if (!self.has_draw_commands) return;
        if (command_buffer == 0) return;
        c.ZigCraft_ImGui_ImplVulkan_RenderDrawData(c.ZigCraft_ImGui_GetDrawData(), @ptrFromInt(command_buffer));
    }
};

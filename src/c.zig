pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_vulkan.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("stb_image.h");
    @cInclude("stb_rect_pack.h");
    @cInclude("stb_truetype.h");
});

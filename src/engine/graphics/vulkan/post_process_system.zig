const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("../rhi.zig");
const Utils = @import("utils.zig");
const shader_registry = @import("shader_registry.zig");
const VulkanBuffer = @import("resource_manager.zig").VulkanBuffer;

pub const PostProcessPushConstants = extern struct {
    bloom_enabled: f32,
    bloom_intensity: f32,
    vignette_intensity: f32,
    film_grain_intensity: f32,
    color_grading_enabled: f32, // 0.0 = disabled, 1.0 = enabled
    color_grading_intensity: f32, // LUT blend intensity (0.0 = original, 1.0 = full LUT)
    _pad0: f32 = 0.0,
    _pad1: f32 = 0.0,
};

pub const PostProcessSystem = struct {
    pipeline: c.VkPipeline = null,
    pipeline_layout: c.VkPipelineLayout = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
    sampler: c.VkSampler = null,
    pass_active: bool = false,
    lut_texture: rhi.TextureHandle = 0,

    pub fn init(
        self: *PostProcessSystem,
        vk: c.VkDevice,
        allocator: std.mem.Allocator,
        descriptor_pool: c.VkDescriptorPool,
        render_pass: c.VkRenderPass,
        hdr_view: c.VkImageView,
        global_ubos: [rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
        global_uniform_size: usize,
    ) !void {
        if (render_pass == null) return error.RenderPassNotInitialized;

        if (self.descriptor_set_layout == null) {
            var bindings = [_]c.VkDescriptorSetLayoutBinding{
                .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
                .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
                .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
                .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            };
            var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
            layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            layout_info.bindingCount = bindings.len;
            layout_info.pBindings = &bindings[0];
            try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));
        }

        if (self.pipeline_layout == null) {
            var push_constant = std.mem.zeroes(c.VkPushConstantRange);
            push_constant.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
            push_constant.offset = 0;
            push_constant.size = @sizeOf(PostProcessPushConstants);

            var pipe_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
            pipe_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            pipe_layout_info.setLayoutCount = 1;
            pipe_layout_info.pSetLayouts = &self.descriptor_set_layout;
            pipe_layout_info.pushConstantRangeCount = 1;
            pipe_layout_info.pPushConstantRanges = &push_constant;
            try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipe_layout_info, null, &self.pipeline_layout));
        }

        if (self.sampler != null) c.vkDestroySampler(vk, self.sampler, null);
        self.sampler = null;

        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
        try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &self.sampler));

        if (self.pipeline != null) {
            c.vkDestroyPipeline(vk, self.pipeline, null);
            self.pipeline = null;
        }

        const vert_code = try fs.cwd().readFileAlloc(shader_registry.POST_PROCESS_VERT, allocator, 1024 * 1024);
        defer allocator.free(vert_code);
        const frag_code = try fs.cwd().readFileAlloc(shader_registry.POST_PROCESS_FRAG, allocator, 1024 * 1024);
        defer allocator.free(frag_code);
        const vert_module = try Utils.createShaderModule(vk, vert_code);
        defer c.vkDestroyShaderModule(vk, vert_module, null);
        const frag_module = try Utils.createShaderModule(vk, frag_code);
        defer c.vkDestroyShaderModule(vk, frag_module, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };

        var vi_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vi_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        var ia_info = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        ia_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia_info.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var vp_info = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        vp_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp_info.viewportCount = 1;
        vp_info.scissorCount = 1;

        var rs_info = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rs_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs_info.lineWidth = 1.0;
        rs_info.cullMode = c.VK_CULL_MODE_NONE;
        rs_info.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;

        var ms_info = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        ms_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms_info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        var cb_attach = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        cb_attach.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        var cb_info = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        cb_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        cb_info.attachmentCount = 1;
        cb_info.pAttachments = &cb_attach;

        var dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dyn_info = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dyn_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn_info.dynamicStateCount = 2;
        dyn_info.pDynamicStates = &dyn_states[0];

        var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipe_info.stageCount = 2;
        pipe_info.pStages = &stages[0];
        pipe_info.pVertexInputState = &vi_info;
        pipe_info.pInputAssemblyState = &ia_info;
        pipe_info.pViewportState = &vp_info;
        pipe_info.pRasterizationState = &rs_info;
        pipe_info.pMultisampleState = &ms_info;
        pipe_info.pColorBlendState = &cb_info;
        pipe_info.pDynamicState = &dyn_info;
        pipe_info.layout = self.pipeline_layout;
        pipe_info.renderPass = render_pass;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipe_info, null, &self.pipeline));

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.descriptor_sets[i] == null) {
                var alloc_ds_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
                alloc_ds_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
                alloc_ds_info.descriptorPool = descriptor_pool;
                alloc_ds_info.descriptorSetCount = 1;
                alloc_ds_info.pSetLayouts = &self.descriptor_set_layout;
                try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_ds_info, &self.descriptor_sets[i]));
            }

            var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
            image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            image_info.imageView = hdr_view;
            image_info.sampler = self.sampler;

            var buffer_info = std.mem.zeroes(c.VkDescriptorBufferInfo);
            buffer_info.buffer = global_ubos[i].buffer;
            buffer_info.offset = 0;
            buffer_info.range = global_uniform_size;

            var writes = [_]c.VkWriteDescriptorSet{
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &image_info },
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &buffer_info },
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &image_info },
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &image_info }, // placeholder for LUT, updated later
            };
            c.vkUpdateDescriptorSets(vk, writes.len, &writes[0], 0, null);
        }
    }

    pub fn updateBloomDescriptors(self: *PostProcessSystem, vk: c.VkDevice, bloom_view: c.VkImageView, bloom_sampler: c.VkSampler) void {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.descriptor_sets[i] == null) continue;

            var bloom_image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
            bloom_image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            bloom_image_info.imageView = bloom_view;
            bloom_image_info.sampler = bloom_sampler;

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = self.descriptor_sets[i];
            write.dstBinding = 2;
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            write.descriptorCount = 1;
            write.pImageInfo = &bloom_image_info;

            c.vkUpdateDescriptorSets(vk, 1, &write, 0, null);
        }
    }

    pub fn updateSourceDescriptor(self: *PostProcessSystem, vk: c.VkDevice, frame_index: usize, source_view: c.VkImageView, source_sampler: c.VkSampler) void {
        if (frame_index >= rhi.MAX_FRAMES_IN_FLIGHT) return;
        if (self.descriptor_sets[frame_index] == null) return;

        var source_image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        source_image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        source_image_info.imageView = source_view;
        source_image_info.sampler = source_sampler;

        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.descriptor_sets[frame_index];
        write.dstBinding = 0;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.descriptorCount = 1;
        write.pImageInfo = &source_image_info;

        c.vkUpdateDescriptorSets(vk, 1, &write, 0, null);
    }

    pub fn updateLUTDescriptor(self: *PostProcessSystem, vk: c.VkDevice, lut_view: c.VkImageView, lut_sampler: c.VkSampler) void {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.descriptor_sets[i] == null) continue;

            var lut_image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
            lut_image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            lut_image_info.imageView = lut_view;
            lut_image_info.sampler = lut_sampler;

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = self.descriptor_sets[i];
            write.dstBinding = 3;
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            write.descriptorCount = 1;
            write.pImageInfo = &lut_image_info;

            c.vkUpdateDescriptorSets(vk, 1, &write, 0, null);
        }
    }

    pub fn deinit(self: *PostProcessSystem, vk: c.VkDevice, descriptor_pool: c.VkDescriptorPool) void {
        if (self.sampler != null) {
            c.vkDestroySampler(vk, self.sampler, null);
            self.sampler = null;
        }
        if (self.pipeline != null) {
            c.vkDestroyPipeline(vk, self.pipeline, null);
            self.pipeline = null;
        }
        if (self.pipeline_layout != null) {
            c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.descriptor_sets[i] != null) {
                _ = c.vkFreeDescriptorSets(vk, descriptor_pool, 1, &self.descriptor_sets[i]);
                self.descriptor_sets[i] = null;
            }
        }

        if (self.descriptor_set_layout != null) {
            c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
            self.descriptor_set_layout = null;
        }

        self.pass_active = false;
    }
};

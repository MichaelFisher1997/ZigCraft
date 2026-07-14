// SPDX-License-Identifier: MIT
// Stable C ABI for the RmlUi 6.2 integration. This header intentionally does
// not expose RmlUi C++ types so it can be imported directly from Zig.
#ifndef ZIGCRAFT_RMLUI_H
#define ZIGCRAFT_RMLUI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <SDL3/SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZigCraftRmlUi ZigCraftRmlUi;
typedef struct ZigCraftRmlUiContext ZigCraftRmlUiContext;
typedef struct ZigCraftRmlUiDocument ZigCraftRmlUiDocument;
typedef struct ZigCraftRmlUiAction ZigCraftRmlUiAction;

typedef struct ZigCraftRmlUiVertex {
    float x;
    float y;
    uint8_t color[4];
    float u;
    float v;
} ZigCraftRmlUiVertex;

typedef uintptr_t (*ZigCraftRmlUiCompileGeometryFn)(
    void *user_data,
    const ZigCraftRmlUiVertex *vertices,
    size_t vertex_count,
    const int32_t *indices,
    size_t index_count);
typedef void (*ZigCraftRmlUiRenderGeometryFn)(
    void *user_data, uintptr_t geometry, float translation_x, float translation_y, uintptr_t texture);
typedef void (*ZigCraftRmlUiReleaseGeometryFn)(void *user_data, uintptr_t geometry);
typedef uintptr_t (*ZigCraftRmlUiLoadTextureFn)(
    void *user_data, const char *source, int *out_width, int *out_height);
typedef uintptr_t (*ZigCraftRmlUiGenerateTextureFn)(
    void *user_data, const uint8_t *pixels_rgba_premultiplied, size_t size, int width, int height);
typedef void (*ZigCraftRmlUiReleaseTextureFn)(void *user_data, uintptr_t texture);
typedef void (*ZigCraftRmlUiEnableScissorFn)(void *user_data, bool enable);
typedef void (*ZigCraftRmlUiSetScissorFn)(void *user_data, int x, int y, int width, int height);

typedef struct ZigCraftRmlUiRenderCallbacks {
    void *user_data;
    ZigCraftRmlUiCompileGeometryFn compile_geometry;
    ZigCraftRmlUiRenderGeometryFn render_geometry;
    ZigCraftRmlUiReleaseGeometryFn release_geometry;
    ZigCraftRmlUiLoadTextureFn load_texture;
    ZigCraftRmlUiGenerateTextureFn generate_texture;
    ZigCraftRmlUiReleaseTextureFn release_texture;
    ZigCraftRmlUiEnableScissorFn enable_scissor;
    ZigCraftRmlUiSetScissorFn set_scissor;
} ZigCraftRmlUiRenderCallbacks;

// Creates the process-global RmlUi runtime. Only one instance may exist at a
// time. Call zigcraft_rmlui_destroy() before creating another instance.
ZigCraftRmlUi *zigcraft_rmlui_init(const ZigCraftRmlUiRenderCallbacks *callbacks);
void zigcraft_rmlui_destroy(ZigCraftRmlUi *rmlui);

// Supplies the SDL window used for text input and clipboard integration.
void zigcraft_rmlui_set_sdl_window(ZigCraftRmlUi *rmlui, SDL_Window *window);

ZigCraftRmlUiContext *zigcraft_rmlui_context_create(ZigCraftRmlUi *rmlui, const char *name, int width, int height);
void zigcraft_rmlui_context_destroy(ZigCraftRmlUi *rmlui, ZigCraftRmlUiContext *context);
void zigcraft_rmlui_context_resize(ZigCraftRmlUiContext *context, int width, int height);
bool zigcraft_rmlui_context_update(ZigCraftRmlUiContext *context);
bool zigcraft_rmlui_context_render(ZigCraftRmlUiContext *context);

bool zigcraft_rmlui_load_font_face(const char *path, bool fallback_face);
ZigCraftRmlUiDocument *zigcraft_rmlui_context_load_document(ZigCraftRmlUiContext *context, const char *path);
ZigCraftRmlUiDocument *zigcraft_rmlui_context_load_document_memory(
    ZigCraftRmlUiContext *context, const char *rml, const char *source_url);
void zigcraft_rmlui_document_show(ZigCraftRmlUiDocument *document);
void zigcraft_rmlui_document_hide(ZigCraftRmlUiDocument *document);
void zigcraft_rmlui_document_close(ZigCraftRmlUi *rmlui, ZigCraftRmlUiDocument *document);
bool zigcraft_rmlui_document_set_inner_rml(ZigCraftRmlUiDocument *document, const char *element_id, const char *rml);
bool zigcraft_rmlui_document_set_class(ZigCraftRmlUiDocument *document, const char *element_id, const char *class_name, bool active);
bool zigcraft_rmlui_document_set_property(ZigCraftRmlUiDocument *document, const char *element_id, const char *property_name, const char *value);
size_t zigcraft_rmlui_document_get_value(ZigCraftRmlUiDocument *document, const char *element_id, char *buffer, size_t buffer_size);
bool zigcraft_rmlui_document_set_value(ZigCraftRmlUiDocument *document, const char *element_id, const char *value);
bool zigcraft_rmlui_document_set_disabled(ZigCraftRmlUiDocument *document, const char *element_id, bool disabled);
bool zigcraft_rmlui_document_focus(ZigCraftRmlUiDocument *document, const char *element_id, bool focus_visible);

// Returns true when RmlUi did not consume the event. The event can still be
// dispatched to the rest of the game when this returns true.
bool zigcraft_rmlui_process_sdl_event(
    ZigCraftRmlUi *rmlui, ZigCraftRmlUiContext *context, SDL_Window *window, const SDL_Event *event);

typedef void (*ZigCraftRmlUiActionCallback)(
    void *user_data, const char *event_type, const char *target_id);

// Attach a bubbling document-level action callback (for example, "click").
// The event and target strings are only valid for the duration of the callback.
ZigCraftRmlUiAction *zigcraft_rmlui_document_add_action(
    ZigCraftRmlUi *rmlui,
    ZigCraftRmlUiDocument *document,
    const char *event_type,
    ZigCraftRmlUiActionCallback callback,
    void *user_data);
void zigcraft_rmlui_action_remove(ZigCraftRmlUi *rmlui, ZigCraftRmlUiAction *action);

#ifdef __cplusplus
}
#endif

#endif

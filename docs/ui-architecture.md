# Player UI Architecture

ZigCraft uses three deliberately separate UI layers:

- **RmlUi** is the opt-in player-facing layout and widget system. It is enabled
  with `-Drmlui=true` and currently owns the home-screen vertical slice.
- **`engine-ui` / `UIRenderer`** remains the render abstraction. RmlUi submits
  indexed geometry, generated textures, and scissors through the existing RHI;
  it does not own a Vulkan instance, device, swapchain, or command buffer.
- **Dear ImGui** remains developer-only UI for diagnostics and tooling.

## Dependency boundary

RmlUi 6.2 is pinned in `flake.nix`. `libs/rmlui_bridge` contains the only C++
integration code and exposes a narrow C ABI to Zig. Feature-off builds do not
link the bridge or allocate the retained-geometry Vulkan buffers and pipelines.

## Lifetime and input

`UISystemManager` owns a heap-stable `RmlUi` backend. Screens own documents and
event listeners, while the backend owns compiled geometry and generated texture
handles until RmlUi releases them. Raw SDL events carry an explicit callback
context; when an active Rml document consumes an event, game input does not see
the same event.

## Current vertical slice

With `-Drmlui=true`, normal menu startup and menu screenshot startup use
`RmlHomeScreen`. It retains the deterministic world preview and provides Play,
Resource Packs, Sky & Lighting, Settings, and Exit actions. If RmlUi fails to
initialize, startup falls back to the legacy home screen.

Destination screens still use the immediate-mode renderer, but share the same
dark-glass palette, 75% black backdrop, cyan interaction states, and compact row
treatment through `menu_theme.zig`. `ScreenManager.drawBackgroundFor` finds the
nearest background provider below a menu without redrawing intermediate pages;
home screens provide the deterministic world preview, while the pause screen
provides the active world. This keeps nested pages visually continuous until
their controls are migrated to RmlUi.

## Migration sequence

1. Validate the home screen on windowed Vulkan and the repaired offscreen path.
2. Move world list and destructive/rename modals to RML/RCSS.
3. Move world creation and settings, replacing manual focus and text entry.
4. Move inventory and HUD components that benefit from responsive layout.
5. Remove migrated presentation code from `menu_theme.zig`; keep specialized
   low-level overlays and ImGui diagnostics separate.

Each migrated screen must support mouse, keyboard/controller focus, resize and
HiDPI, clean document teardown, and visual regression captures at 1280x720,
1920x1080, and a high-DPI resolution.

## Known limitation

The tracked menu golden is invalid because it is black. The comparison script
now rejects black inputs. A new golden must not be promoted until the headless
capture visibly contains the final player UI and is deterministic under the
`ci-graphics` Nix shell.

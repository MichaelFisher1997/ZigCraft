{
  description = "Zig 0.16 SDL3 Vulkan Voxel Engine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        zig_version = "0.16.0";
        nix_dynamic_linker = if pkgs.stdenv.isLinux then pkgs.stdenv.cc.bintools.dynamicLinker else "";
        nix_runtime_library_path = if pkgs.stdenv.isLinux then pkgs.lib.makeLibraryPath [
          pkgs.glibc
          pkgs.stdenv.cc.cc.lib
          pkgs.sdl3
          pkgs.vulkan-loader
          pkgs.mesa
          cimgui
          rmluiBridge
          rmlui
          pkgs.freetype
        ] else "";
        zig_sources = {
          x86_64-linux = {
            url = "https://ziglang.org/download/${zig_version}/zig-x86_64-linux-${zig_version}.tar.xz";
            hash = "sha256-cOSWZKdDdLSLUebz/fv0N/Y5XUJQkFBYi9SavlK6PQA=";
          };

          aarch64-linux = {
            url = "https://ziglang.org/download/${zig_version}/zig-aarch64-linux-${zig_version}.tar.xz";
            hash = "sha256-6ksJv7IuxvbGzqxXq2PvtrRuF6sI0h9p86SLOOFTTxc=";
          };

          x86_64-darwin = {
            url = "https://ziglang.org/download/${zig_version}/zig-x86_64-macos-${zig_version}.tar.xz";
            hash = "sha256-A4dVftGHe8ai4YAsg5GVO63bp2CBh2MBxSL1KXe1K6c=";
          };

          aarch64-darwin = {
            url = "https://ziglang.org/download/${zig_version}/zig-aarch64-macos-${zig_version}.tar.xz";
            hash = "sha256-sj1w3qqHm1wtSG7TMW9+qlPoSs9vycx0feFSRQ1AFIk=";
          };
        };

        zig_source = zig_sources.${system};
        zig_tarball = pkgs.fetchurl {
          url = zig_source.url;
          hash = zig_source.hash;
        };

        zig = pkgs.stdenvNoCC.mkDerivation {
          pname = "zig";
          version = zig_version;
          src = zig_tarball;

          dontUnpack = true;
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            mkdir -p $out
            tar -xJf ${zig_tarball} -C $out --strip-components=1
            mkdir -p $out/bin
            cp $out/zig $out/bin/zig
          '';

          meta = {
            mainProgram = "zig";
            platforms = builtins.attrNames zig_sources;
          };
        };

        cimgui = pkgs.stdenv.mkDerivation rec {
          pname = "cimgui";
          version = "1.92.7-docking";

          src = pkgs.fetchFromGitHub {
            owner = "cimgui";
            repo = "cimgui";
            rev = "d3f0c2f4a7d4d116ef908295b971a36bdfdafe27";
            hash = "sha256-CsnoCFSzAibhUz2ffbGQcxczzhpQKpz9WJoRYbNH+kc=";
            fetchSubmodules = true;
          };

          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.sdl3 pkgs.vulkan-headers ];

          dontConfigure = true;

          cimguiBackendHeader = pkgs.writeText "cimgui_backend.h" ''
            #pragma once
            #include <stdbool.h>
            #include <SDL3/SDL.h>
            #include <vulkan/vulkan.h>

            #ifdef __cplusplus
            extern "C" {
            #endif

            typedef struct ZigCraftImGuiVulkanInitInfo {
              VkInstance instance;
              VkPhysicalDevice physical_device;
              VkDevice device;
              VkQueue queue;
              uint32_t queue_family;
              VkDescriptorPool descriptor_pool;
              VkRenderPass render_pass;
              uint32_t min_image_count;
              uint32_t image_count;
              VkSampleCountFlagBits msaa_samples;
            } ZigCraftImGuiVulkanInitInfo;

            bool ZigCraft_ImGui_ImplSDL3_InitForVulkan(SDL_Window* window);
            bool ZigCraft_ImGui_ImplSDL3_ProcessEvent(const SDL_Event* event);
            void ZigCraft_ImGui_ImplSDL3_NewFrame(void);
            void ZigCraft_ImGui_ImplSDL3_Shutdown(void);

            bool ZigCraft_ImGui_ImplVulkan_Init(const ZigCraftImGuiVulkanInitInfo* info);
            void ZigCraft_ImGui_ImplVulkan_NewFrame(void);
            void ZigCraft_ImGui_ImplVulkan_RenderDrawData(void* draw_data, VkCommandBuffer command_buffer);
            void ZigCraft_ImGui_ImplVulkan_Shutdown(void);

            void ZigCraft_ImGui_CreateContext(void);
            void ZigCraft_ImGui_DestroyContext(void);
            void ZigCraft_ImGui_StyleColorsDark(void);
            void ZigCraft_ImGui_NewFrame(void);
            bool ZigCraft_ImGui_Begin(const char* name);
            bool ZigCraft_ImGui_Checkbox(const char* label, bool* value);
            void ZigCraft_ImGui_SameLine(void);
            void ZigCraft_ImGui_TextUnformatted(const char* text);
            void ZigCraft_ImGui_End(void);
            void ZigCraft_ImGui_Render(void);
            void* ZigCraft_ImGui_GetDrawData(void);

            #ifdef __cplusplus
            }
            #endif
          '';

          cimguiBackendSource = pkgs.writeText "cimgui_backend.cpp" ''
            #include "cimgui_backend.h"
            #include "imgui.h"
            #include "backends/imgui_impl_sdl3.h"
            #include "backends/imgui_impl_vulkan.h"

            bool ZigCraft_ImGui_ImplSDL3_InitForVulkan(SDL_Window* window) {
              return ImGui_ImplSDL3_InitForVulkan(window);
            }

            bool ZigCraft_ImGui_ImplSDL3_ProcessEvent(const SDL_Event* event) {
              return ImGui_ImplSDL3_ProcessEvent(event);
            }

            void ZigCraft_ImGui_ImplSDL3_NewFrame(void) {
              ImGui_ImplSDL3_NewFrame();
            }

            void ZigCraft_ImGui_ImplSDL3_Shutdown(void) {
              ImGui_ImplSDL3_Shutdown();
            }

            bool ZigCraft_ImGui_ImplVulkan_Init(const ZigCraftImGuiVulkanInitInfo* info) {
              ImGui_ImplVulkan_InitInfo init_info = {};
              init_info.Instance = info->instance;
              init_info.PhysicalDevice = info->physical_device;
              init_info.Device = info->device;
              init_info.QueueFamily = info->queue_family;
              init_info.Queue = info->queue;
              init_info.DescriptorPool = info->descriptor_pool;
              init_info.PipelineInfoMain.RenderPass = info->render_pass;
              init_info.MinImageCount = info->min_image_count;
              init_info.ImageCount = info->image_count;
              init_info.PipelineInfoMain.MSAASamples = info->msaa_samples;
              return ImGui_ImplVulkan_Init(&init_info);
            }

            void ZigCraft_ImGui_ImplVulkan_NewFrame(void) {
              ImGui_ImplVulkan_NewFrame();
            }

            void ZigCraft_ImGui_ImplVulkan_RenderDrawData(void* draw_data, VkCommandBuffer command_buffer) {
              ImGui_ImplVulkan_RenderDrawData(static_cast<ImDrawData*>(draw_data), command_buffer);
            }

            void ZigCraft_ImGui_ImplVulkan_Shutdown(void) {
              ImGui_ImplVulkan_Shutdown();
            }

            void ZigCraft_ImGui_CreateContext(void) {
              ImGui::CreateContext();
            }

            void ZigCraft_ImGui_DestroyContext(void) {
              ImGui::DestroyContext();
            }

            void ZigCraft_ImGui_StyleColorsDark(void) {
              ImGui::StyleColorsDark();
            }

            void ZigCraft_ImGui_NewFrame(void) {
              ImGui::NewFrame();
            }

            bool ZigCraft_ImGui_Begin(const char* name) {
              return ImGui::Begin(name);
            }

            bool ZigCraft_ImGui_Checkbox(const char* label, bool* value) {
              return ImGui::Checkbox(label, value);
            }

            void ZigCraft_ImGui_SameLine(void) {
              ImGui::SameLine();
            }

            void ZigCraft_ImGui_TextUnformatted(const char* text) {
              ImGui::TextUnformatted(text);
            }

            void ZigCraft_ImGui_End(void) {
              ImGui::End();
            }

            void ZigCraft_ImGui_Render(void) {
              ImGui::Render();
            }

            void* ZigCraft_ImGui_GetDrawData(void) {
              return ImGui::GetDrawData();
            }
          '';

          cimguiCompatSource = pkgs.writeText "cimgui_compat.c" ''
            #include <stdarg.h>
            #include <stdio.h>

            extern int __isoc99_vsscanf(const char* str, const char* format, va_list args);

            int __isoc23_sscanf(const char* str, const char* format, ...) {
              va_list args;
              va_start(args, format);
              int result = __isoc99_vsscanf(str, format, args);
              va_end(args);
              return result;
            }
          '';

          buildPhase = ''
            runHook preBuild
            cxxflags="-std=c++17 -O2 -fPIC -I. -Iimgui -Iimgui/backends $(pkg-config --cflags sdl3) -I${pkgs.vulkan-headers}/include"
            $CXX $cxxflags -c cimgui.cpp -o cimgui.o
            $CXX $cxxflags -c imgui/imgui.cpp -o imgui.o
            $CXX $cxxflags -c imgui/imgui_draw.cpp -o imgui_draw.o
            $CXX $cxxflags -c imgui/imgui_demo.cpp -o imgui_demo.o
            $CXX $cxxflags -c imgui/imgui_tables.cpp -o imgui_tables.o
            $CXX $cxxflags -c imgui/imgui_widgets.cpp -o imgui_widgets.o
            $CXX $cxxflags -c imgui/backends/imgui_impl_sdl3.cpp -o imgui_impl_sdl3.o
            $CXX $cxxflags -c imgui/backends/imgui_impl_vulkan.cpp -o imgui_impl_vulkan.o
            cp ${cimguiBackendHeader} cimgui_backend.h
            $CXX $cxxflags -I. -c ${cimguiBackendSource} -o cimgui_backend.o
            $CC -O2 -fPIC -c ${cimguiCompatSource} -o cimgui_compat.o
            ar rcs libcimgui.a cimgui.o imgui.o imgui_draw.o imgui_demo.o imgui_tables.o imgui_widgets.o imgui_impl_sdl3.o imgui_impl_vulkan.o cimgui_backend.o cimgui_compat.o
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/pkgconfig $out/include/cimgui $out/include/cimgui/imgui
            cp cimgui.h cimconfig.h $out/include/cimgui/
            cp imgui/imgui.h imgui/imconfig.h imgui/imgui_internal.h $out/include/cimgui/imgui/
            cp imgui/imstb_rectpack.h imgui/imstb_textedit.h imgui/imstb_truetype.h $out/include/cimgui/imgui/
            cp ${cimguiBackendHeader} $out/include/cimgui/cimgui_backend.h
            cp imgui/backends/imgui_impl_sdl3.h imgui/backends/imgui_impl_vulkan.h $out/include/cimgui/imgui/
            cp libcimgui.a $out/lib/libcimgui.a
            cat > $out/lib/pkgconfig/cimgui.pc <<EOF
            prefix=$out
            libdir=$out/lib
            includedir=$out/include/cimgui

            Name: cimgui
            Description: C API for Dear ImGui with ZigCraft SDL3/Vulkan backend wrapper
            Version: ${version}
            Libs: -L$out/lib -lcimgui
            Cflags: -I$out/include/cimgui -I$out/include/cimgui/imgui
            EOF
            runHook postInstall
          '';
        };

        rmlui = pkgs.llvmPackages.libcxxStdenv.mkDerivation rec {
          pname = "rmlui-core";
          version = "6.2";

          src = pkgs.fetchFromGitHub {
            owner = "mikke89";
            repo = "RmlUi";
            rev = "2230d1a6e8e0848ed87a5761e2a5160b2a175ba4";
            hash = "sha256-K/znksrli3/FQ+lHgZgMgefFrWAGbxKNvFIIqtybOMc=";
          };

          nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
          buildInputs = [ pkgs.freetype ];

          # The upstream top-level target normally pulls the optional debugger
          # library too. ZigCraft consumes only Core through the C ABI bridge.
          postPatch = ''
            substituteInPlace Source/CMakeLists.txt --replace-fail 'add_subdirectory("Debugger")' ""
            substituteInPlace CMakeLists.txt --replace-fail 'target_link_libraries(rmlui INTERFACE rmlui_core rmlui_debugger)' 'target_link_libraries(rmlui INTERFACE rmlui_core)'
          '';

          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DBUILD_TESTING=OFF"
            "-DRMLUI_SAMPLES=OFF"
            "-DRMLUI_FONT_ENGINE=freetype"
            "-DRMLUI_LUA_BINDINGS=OFF"
            "-DRMLUI_LOTTIE_PLUGIN=OFF"
            "-DRMLUI_SVG_PLUGIN=OFF"
            "-DRMLUI_PRECOMPILED_HEADERS=OFF"
          ];
        };

        rmluiBridge = pkgs.llvmPackages.libcxxStdenv.mkDerivation {
          pname = "zigcraft-rmlui-bridge";
          version = "6.2";
          src = ./.;

          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.sdl3 pkgs.freetype rmlui ];
          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            $CXX -std=c++17 -DRMLUI_STATIC_LIB -O2 -fPIC -I$src/libs/rmlui_bridge -I${rmlui}/include $(pkg-config --cflags sdl3) \
              -c $src/libs/rmlui_bridge/zigcraft_rmlui.cpp -o zigcraft_rmlui.o
            ar rcs libzigcraft_rmlui_bridge.a zigcraft_rmlui.o
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/include/zigcraft $out/lib/pkgconfig
            cp $src/libs/rmlui_bridge/zigcraft_rmlui.h $out/include/zigcraft/
            cp libzigcraft_rmlui_bridge.a $out/lib/
            cat > $out/lib/pkgconfig/zigcraft-rmlui-bridge.pc <<EOF
            prefix=$out
            libdir=$out/lib
            includedir=$out/include

            Name: ZigCraft RmlUi bridge
            Description: C ABI bridge for RmlUi 6.2 Core and SDL3
            Version: 6.2
            Requires: sdl3 freetype2
            Libs: -L$out/lib -lzigcraft_rmlui_bridge -L${rmlui}/lib -lrmlui
            Cflags: -I$out/include
            EOF
            runHook postInstall
          '';
        };
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zigcraft";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            zig
            pkgs.pkg-config
            pkgs.patchelf
            pkgs.makeWrapper
          ];

          buildInputs = [
            pkgs.sdl3
            pkgs.vulkan-loader
            pkgs.vulkan-headers
            cimgui
            rmluiBridge
            rmlui
            pkgs.freetype
          ];

          # Disable hardening to fix "__builtin_va_arg_pack" error during C import
          hardeningDisable = [ "all" ];

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build -Doptimize=Debug -Dtarget=x86_64-linux-gnu --prefix $out
          '';

          postFixup = ''
            patchelf --add-rpath ${pkgs.lib.makeLibraryPath [ pkgs.sdl3 pkgs.vulkan-loader pkgs.stdenv.cc.cc.lib cimgui rmluiBridge rmlui pkgs.freetype ]} $out/bin/zigcraft
            wrapProgram $out/bin/zigcraft \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.vulkan-loader cimgui rmluiBridge rmlui pkgs.freetype ]}
          '';
        };

        packages.cimgui = cimgui;
        packages.rmlui = rmlui;
        packages.rmlui-bridge = rmluiBridge;

        devShells = {
          default = pkgs.mkShell {
            nativeBuildInputs = [
              zig
              pkgs.zls
              pkgs.pkg-config
              pkgs.glslang
              pkgs.kcov
              pkgs.shellcheck
              pkgs.weston
            ];

            buildInputs = [
              pkgs.sdl3
              pkgs.vulkan-loader
              pkgs.vulkan-headers
              pkgs.mesa
              cimgui
              rmluiBridge
              rmlui
              pkgs.freetype
            ];

            ZIGCRAFT_DYNAMIC_LINKER = nix_dynamic_linker;
            ZIGCRAFT_RUNTIME_LIBRARY_PATH = nix_runtime_library_path;

            shellHook = ''
              echo "Zig ${zig_version} + SDL3 Dev Environment"
              echo "Compiler: $(zig version)"
            '';
          };

          ci-unit = pkgs.mkShell {
            nativeBuildInputs = [
              zig
              pkgs.pkg-config
              pkgs.glslang
              pkgs.kcov
              pkgs.shellcheck
            ];

            buildInputs = [
              pkgs.sdl3
              pkgs.vulkan-loader
              pkgs.vulkan-headers
              cimgui
              rmluiBridge
              rmlui
              pkgs.freetype
            ];

            # Use the Nix glibc loader for binaries that link Nix libraries on
            # non-NixOS CI hosts. Mixing those libraries with the host loader
            # fails when the runner's glibc is older than nixpkgs' glibc.
            ZIGCRAFT_DYNAMIC_LINKER = nix_dynamic_linker;
            ZIGCRAFT_RUNTIME_LIBRARY_PATH = nix_runtime_library_path;

            shellHook = ''
              echo "Zig ${zig_version} CI unit environment"
              echo "Compiler: $(zig version)"
            '';
          };

          ci-graphics = pkgs.mkShell {
            nativeBuildInputs = [
              zig
              pkgs.pkg-config
              pkgs.glslang
              pkgs.shellcheck
              pkgs.weston
            ];

            buildInputs = [
              pkgs.sdl3
              pkgs.vulkan-loader
              pkgs.vulkan-headers
              pkgs.mesa
              cimgui
              rmluiBridge
              rmlui
              pkgs.freetype
            ];

            ZIGCRAFT_DYNAMIC_LINKER = nix_dynamic_linker;
            ZIGCRAFT_RUNTIME_LIBRARY_PATH = nix_runtime_library_path;

            shellHook = ''
              echo "Zig ${zig_version} CI graphics environment"
              echo "Compiler: $(zig version)"
            '';
          };
        };
      });
}

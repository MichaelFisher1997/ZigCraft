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
            pkgs.vulkan-validation-layers
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
            patchelf --add-rpath ${pkgs.lib.makeLibraryPath [ pkgs.sdl3 pkgs.vulkan-loader pkgs.stdenv.cc.cc.lib ]} $out/bin/zigcraft
            wrapProgram $out/bin/zigcraft \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.vulkan-loader ]}
          '';
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            zig
            pkgs.zls
            pkgs.pkg-config
            pkgs.glslang
            pkgs.weston
          ];

          buildInputs = [
            pkgs.sdl3
            pkgs.vulkan-loader
            pkgs.vulkan-headers
            pkgs.vulkan-validation-layers
            pkgs.mesa.drivers
          ];

          shellHook = ''
            echo "Zig ${zig_version} + SDL3 Dev Environment"
            echo "Compiler: $(zig version)"
          '';
        };
      });
}

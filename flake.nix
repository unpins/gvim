{
  description = "Standalone build of gvim (Windows GUI)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Windows-only by design. Static gvim on Linux requires GTK statically
  # linked (infeasible: GTK loads modules dynamically); on macOS the GUI
  # editor is MacVim (.app bundle, not a CLI binary). Win32 GUI is the
  # only platform where gvim ships as a self-contained .exe.
  outputs = { self, unpins-lib }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "gvim";
      nativeBuild = false;

      # Same Make_ming.mak path as unpins/vim, but GUI=yes so the build
      # links against Win32 GUI (USER32/GDI32/comdlg32/comctl32) and
      # the resulting binary is `gvim.exe` linked with -mwindows
      # (Windows subsystem; opens a window, doesn't attach to a console).
      windowsBuild = pkgs:
        let
          cross = pkgs.pkgsCross.mingwW64;
          prefix = cross.stdenv.hostPlatform.config;
        in
        cross.stdenv.mkDerivation {
          pname = "gvim";
          inherit (pkgs.vim) version src;

          dontConfigure = true;

          # libwinpthread.a — same as unpins/vim, needed by Make_ming.mak's
          # `-Wl,-Bstatic -lwinpthread` line.
          buildInputs = [ cross.windows.pthreads ];
          strictDeps = true;
          enableParallelBuilding = true;

          # Make_ming.mak knobs (delta vs unpins/vim is GUI=yes + target):
          #   FEATURES=NORMAL — no Lua/Python/Ruby/Tcl; keeps syntax/spell/...
          #   GUI=yes         — Win32 GUI build → gvim.exe (-mwindows subsystem).
          #   OLE=no          — skip Windows shell extension (gvimext.dll).
          #   DIRECTX=no      — skip Direct2D renderer (extra deps; ours is GDI).
          #   CROSS=yes       — skips host probes.
          #   STATIC_*=yes    — embed gcc/winpthread runtime; no DLL companions.
          buildPhase = ''
            runHook preBuild
            make -C src -f Make_ming.mak \
              FEATURES=NORMAL \
              GUI=yes \
              OLE=no \
              DIRECTX=no \
              CROSS=yes \
              CROSS_COMPILE=${prefix}- \
              STATIC_STDCPLUS=yes \
              STATIC_WINPTHREAD=yes \
              WINDRES=${prefix}-windres \
              ARCH=x86-64 \
              -j$NIX_BUILD_CORES \
              gvim.exe
            runHook postBuild
          '';

          # Runtime tree (share/vim/vim92) is identical to unpins/vim — pure
          # text, reused from pkgs.vim. gvim discovers it the same way
          # (walks up from $argv[0]).
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/share
            cp src/gvim.exe $out/bin/gvim.exe
            cp -r ${pkgs.vim}/share/vim $out/share/vim
            runHook postInstall
          '';

          passthru = { pname = "gvim"; inherit (pkgs.vim) version; };
        };
    };
}

{
  description = "Standalone build of gvim (Linux GTK2 + Windows GUI)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";
  inputs.nixpkgs.follows = "unpins-lib/nixpkgs";

  # Departure from tree/flake.nix minimum:
  #   - Linux native is one static binary against pkgsStatic.gtk2 (6 overrides
  #     + 2 patches; see playground/static-gtk2-recipe/ for the standalone
  #     proof-of-concept and [[static-gtk2-on-musl-is-buildable]] in memory).
  #   - Windows uses Make_ming.mak directly (pkgsCross.mingwW64.vim is broken
  #     upstream — same situation as unpins/vim).
  #   - Darwin is intentionally absent: GUI Vim on macOS is MacVim.app, not a
  #     CLI binary.
  outputs = { self, unpins-lib, nixpkgs }:
    let
      linuxGvim = system:
        let
          pkgs = import nixpkgs { inherit system; };

          # graphite2's pkgsStatic .la still claims library_names=libgraphite2.so
          # (which isn't installed). libtool obeys the .la over the .a → link
          # fails. Strip the .la files.
          static = pkgs.pkgsStatic.extend (selfP: superP: {
            graphite2 = superP.graphite2.overrideAttrs (old: {
              postFixup = (old.postFixup or "") + ''
                find $out -name '*.la' -delete
              '';
            });
          });

          # at-spi2-core in atk_only mode: builds just the libatk stub without
          # at-spi-bus-launcher (which would need dbus + dconf at runtime).
          # GTK2 only needs libatk symbols at link time. Nullifying dconf and
          # wiping postFixup (which referenced ${lib.getLib dconf}) cuts the
          # transitive closure that otherwise pulls in pam/systemd.
          atkstatic = (static.at-spi2-core.override {
            dconf = null;
            gsettings-desktop-schemas = null;
            gobject-introspection = null;
          }).overrideAttrs (old: {
            postFixup = "";
            mesonFlags = [
              "-Datk_only=true"
              "-Dintrospection=disabled"
              "-Dx11=disabled"
              "-Duse_systemd=false"
              "-Ddocs=false"
              # pkgsStatic injects these, but our mesonFlags rewrite replaces
              # them — re-assert so meson doesn't try to build libatk-1.0.so.
              "-Ddefault_library=static"
              "-Ddefault_both_libraries=static"
            ];
          });

          # Static GTK2: route atk to our atk_only build, drop gobject-introspection
          # (only generates .gir/.typelib; not needed for a C link), and disable
          # cups (it propagates linux-pam, which is dlopen-by-design and not
          # buildable under musl). The two patches silence GModule warnings on
          # every gtk_init() — without them, host desktop's GTK_MODULES env and
          # ~/.gtkrc-2.0 each spam stderr because dlopen always fails statically.
          gtk2static = (static.gtk2.override {
            atk = atkstatic;
            gobject-introspection = null;
            cupsSupport = false;
          }).overrideAttrs (old: {
            nativeBuildInputs = builtins.filter (x: x != null) old.nativeBuildInputs;
            patches = (old.patches or [ ]) ++ [
              ./gtk2-static-mixed-deps.patch
              ./gtk2-static-silence-dlopen.patch
            ];
            configureFlags = (old.configureFlags or [ ]) ++ [
              "--disable-introspection"
              # Bake pixbuf loaders (PNG/JPG/GIF/...) and immodules into
              # libgdk_pixbuf/libgtk rather than expecting them as .so modules.
              "--with-included-loaders=yes"
              "--with-included-immodules=yes"
            ];
            # perf/testperf generates a duplicate marshalers.c whose symbols
            # collide with gtk/gtkmarshalers.o under static link. We don't need
            # the benchmark — replace its Makefile with a no-op.
            postConfigure = (old.postConfigure or "") + ''
              printf 'all install clean check distclean install-strip:\n\t@true\n' \
                > perf/Makefile
            '';
          });

          # nixpkgs's vim-full passes --disable-gtk{,2}_check by default, which
          # cripples --enable-gui=gtk2; also --disable-xsmp leaves libXt.a's
          # SmcXxx references unresolved (libXt was compiled with SM hooks).
          # AC_PATH_X heuristics (xmkmf + /usr/X11R6) miss nix-store-resident X
          # libs and set no_x=yes; preset the autoconf cache so vim's configure
          # proceeds past the X gate. -I/-L paths come from stdenv via buildInputs.
          vim = (static.vim-full.override {
            features = "normal";
            guiSupport = "gtk2";
            gtk2-x11 = gtk2static;
            luaSupport = false;
            pythonSupport = false;
            rubySupport = false;
            tclSupport = false;
            perlSupport = false;
            cscopeSupport = false;
            netbeansSupport = false;
            sodiumSupport = false;
            waylandSupport = false;
            ximSupport = false;
          }).overrideAttrs (old: {
            configureFlags = builtins.filter (f:
              f != "--disable-gtk_check"
              && f != "--disable-gtk2_check"
              && f != "--disable-xsmp"
              && f != "--disable-xsmp_interact"
            ) old.configureFlags ++ [
              "ac_cv_have_x=have_x=yes ac_x_includes= ac_x_libraries="
            ];
            # Linux vim hardcodes the compile-time pathdef ($VIMRUNTIME =
            # /nix/store/.../share/vim/<ver>) and never walks argv[0] for it
            # (USE_EXE_NAME is Mac/Win/VMS-only upstream). Without this patch
            # the deployed binary can't find its own runtime → :menu empty,
            # no syntax. Patch enables USE_EXE_NAME on Unix + teaches
            # vim_version_dir the FHS <root>/bin + <root>/share/vim/<ver>
            # layout, and warns to stderr if the resolved path is missing.
            patches = (old.patches or [ ]) ++ [
              ./vim-relocatable-runtime.patch
            ];
          });
        in
        # vim-full installs `vim` (real binary, GUI-capable when configured)
        # plus symlinks: gvim, evim, view, vi, ex, rview, rvim, vimdiff. Vim's
        # mode is chosen by argv[0]. We ship just `gvim` → make it the real
        # file. Drop the desktop/icon files; unpins is CLI-only.
        vim.overrideAttrs (old: {
          pname = "gvim";
          postInstall = (old.postInstall or "") + ''
            find "$out/bin" -mindepth 1 -not -name vim -delete
            mv "$out/bin/vim" "$out/bin/gvim"
            rm -rf "$out/share/applications" "$out/share/icons"
          '';
        });

      base = unpins-lib.lib.mkStandaloneFlake {
        inherit self;
        name = "gvim";
        nativeBuild = false; # native (Linux) is wired up manually below

        # Same Make_ming.mak path as unpins/vim, but GUI=yes so the build
        # links against Win32 GUI (USER32/GDI32/comdlg32/COMCTL32) and the
        # resulting binary is `gvim.exe` linked with -mwindows (Windows
        # subsystem; opens a window, doesn't attach to a console).
        windowsBuild = pkgs:
          let
            cross = pkgs.pkgsCross.mingwW64;
            prefix = cross.stdenv.hostPlatform.config;
          in
          cross.stdenv.mkDerivation {
            pname = "gvim";
            inherit (pkgs.vim) version src;

            dontConfigure = true;

            buildInputs = [ cross.windows.pthreads ];
            strictDeps = true;
            enableParallelBuilding = true;

            # Knobs (delta vs unpins/vim is GUI=yes + target):
            #   GUI=yes      — Win32 GUI build → gvim.exe (-mwindows subsystem).
            #   OLE=no       — skip Windows shell extension (gvimext.dll).
            #   DIRECTX=no   — skip Direct2D renderer; we use the GDI renderer.
            #   CROSS=yes    — skips host probes.
            #   STATIC_*=yes — embed gcc/winpthread runtime; no DLL companions.
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

      linuxNative = linuxGvim "x86_64-linux";
    in
    base // {
      packages = base.packages // {
        x86_64-linux = (base.packages.x86_64-linux or { }) // {
          default = linuxNative;
        };
      };
      apps = base.apps // {
        x86_64-linux = {
          default = {
            type = "app";
            program = "${linuxNative}/bin/gvim";
          };
        };
      };
    };
}

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
      # Man tree embedded into both the native gvim and gvim.exe via withMan.
      # vim-full's installed man (vim/vimdiff/evim/vimtutor.1) is the same set
      # the gvim build produces and is version-locked to this flake's nixpkgs.
      # Upstream installs NO gvim.1 (nixpkgs skips vim's GUI man-link step; gvim
      # is documented inside vim.1), so synthesize a `.so man1/vim.1` redirect —
      # `unpin man gvim` then resolves to vim.1 through the .unpin_man kind-0
      # mechanism, no renderer special-case. Also gives gvim.exe man (the mingw
      # cross build ships none, and nixpkgs has no `gvim` attr to source from).
      gvimMan = pkgs: pkgs.runCommand "gvim-man" { } ''
        mkdir -p $out/share/man/man1
        cp ${pkgs.vim-full}/share/man/man1/*.1.gz $out/share/man/man1/
        printf '.so man1/vim.1\n' > $out/share/man/man1/gvim.1
      '';

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
          vimBase = (static.vim-full.override {
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
          });

          # Pack the upstream runtime tree (share/vim/vim92) into a deflate
          # ZIP. Linked into the binary as a section via `ld -r -b binary`
          # and served from memory by the VFS layer. Drops the on-disk
          # share/vim/vim92/ from the install.
          runtimeZip = pkgs.runCommand "vim-runtime.zip" {
            nativeBuildInputs = [ pkgs.buildPackages.zip ];
          } ''
            cd ${vimBase}/share/vim
            rt=$(ls -d vim* | head -1)
            zip -9 -r -q $out "$rt"
            if [ ! -f $out ] && [ -f $out.zip ]; then mv $out.zip $out; fi
          '';

          vim = vimBase.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              echo "==> inject unpins VFS sources"
              cp ${./unpins_vfs.h}            src/unpins_vfs.h
              cp ${./unpins_vfs_hooks.h}      src/unpins_vfs_hooks.h
              cp ${./unpins_vfs.c}            src/unpins_vfs.c
              cp ${./unpins_init.c}           src/unpins_init.c
              cp ${./unpins_runtime_data.S}   src/unpins_runtime_data.S
              cp ${./miniz.h}                 src/miniz.h
              cp ${./miniz.c}                 src/miniz.c

              echo "==> stage runtime ZIP at src/unpins_runtime.zip for .incbin"
              cp ${runtimeZip} src/unpins_runtime.zip
              chmod 0644 src/unpins_runtime.zip

              echo "==> insert hooks include INSIDE vim.h's VIM__H guard"
              sed -i 's|^#endif // VIM__H|#include "unpins_vfs_hooks.h"\n#endif // VIM__H|' src/vim.h

              echo "==> inject unpins_init() right after mch_early_init() in main.c"
              sed -i '0,/mch_early_init();/{s|mch_early_init();|mch_early_init();\n    unpins_init();|}' src/main.c

              echo "==> add OBJ entries + compile rules to autotools Makefile"
              sed -i 's|$(XDIFF_OBJS_USED)|$(XDIFF_OBJS_USED) \\\n\tobjects/unpins_vfs.o \\\n\tobjects/unpins_init.o \\\n\tobjects/unpins_runtime_data.o \\\n\tobjects/miniz.o|' src/Makefile
              cat ${./patches/Makefile_append} >> src/Makefile
            '';
          });
        in
        # vim-full installs `vim` (real binary, GUI-capable when configured)
        # plus symlinks: gvim, evim, view, vi, ex, rview, rvim, vimdiff. Vim's
        # mode is chosen by argv[0]. We ship just `gvim` → make it the real
        # file. Drop the desktop/icon files; unpins is CLI-only. Runtime
        # tree is embedded in the binary, so wipe share/vim/vim* too.
        #
        # withMan: gvim's native path is wired manually (nativeBuild = false),
        # so it bypasses mkStandaloneFlake's automatic embedMan step. Apply
        # withMan here (with the shared gvimMan tree, incl. the gvim→vim .so) so
        # `gvim` carries man pages like unpins/vim does.
        unpins-lib.lib.withMan pkgs { primary = "gvim"; manRoot = "${gvimMan pkgs}"; } (vim.overrideAttrs (old: {
          pname = "gvim";
          postInstall = (old.postInstall or "") + ''
            find "$out/bin" -mindepth 1 -not -name vim -delete
            mv "$out/bin/vim" "$out/bin/gvim"
            rm -rf "$out/share/applications" "$out/share/icons"
            rm -rf "$out"/share/vim/vim*
            rm -f  "$out/share/vim/vimrc"
            rmdir  "$out/share/vim" 2>/dev/null || true
          '';
        }));

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

            runtimeZip = pkgs.runCommand "vim-runtime.zip" {
              nativeBuildInputs = [ pkgs.buildPackages.zip ];
            } ''
              cd ${pkgs.vim}/share/vim
              rt=$(ls -d vim* | head -1)
              zip -9 -r -q $out "$rt"
              if [ ! -f $out ] && [ -f $out.zip ]; then mv $out.zip $out; fi
            '';
          in
          # gvim.exe gets no man from mkStandaloneFlake's windows path
          # (it sources from x86_64-linux.gvim, which nixpkgs lacks → null),
          # so embed it here from the shared gvimMan tree.
          unpins-lib.lib.withMan pkgs { primary = "gvim"; manRoot = "${gvimMan pkgs}"; } (
          cross.stdenv.mkDerivation {
            pname = "gvim";
            inherit (pkgs.vim) version src;

            dontConfigure = true;

            buildInputs = [ cross.windows.pthreads ];
            strictDeps = true;
            enableParallelBuilding = true;

            postPatch = ''
              echo "==> inject unpins VFS sources"
              cp ${./unpins_vfs.h}            src/unpins_vfs.h
              cp ${./unpins_vfs_hooks.h}      src/unpins_vfs_hooks.h
              cp ${./unpins_vfs.c}            src/unpins_vfs.c
              cp ${./unpins_init.c}           src/unpins_init.c
              cp ${./unpins_runtime_data.S}   src/unpins_runtime_data.S
              cp ${./miniz.h}                 src/miniz.h
              cp ${./miniz.c}                 src/miniz.c

              echo "==> stage runtime ZIP at src/unpins_runtime.zip for .incbin"
              cp ${runtimeZip} src/unpins_runtime.zip
              chmod 0644 src/unpins_runtime.zip

              echo "==> insert hooks include inside VIM__H guard"
              sed -i 's|^#endif // VIM__H|#include "unpins_vfs_hooks.h"\n#endif // VIM__H|' src/vim.h

              echo "==> inject unpins_init() right after mch_early_init() in main.c"
              sed -i '0,/mch_early_init();/{s|mch_early_init();|mch_early_init();\n    unpins_init();|}' src/main.c

              echo "==> patch os_win32.c mch_open/mch_fopen to dispatch virtual paths"
              awk '
              /^mch_open\(const char \*name, int flags, int mode\)$/ {
                  print; getline; print;
                  print "    if (unpins_vfs_is_virtual(name))";
                  print "\treturn unpins_vfs_open(name, flags, mode);";
                  next;
              }
              /^mch_fopen\(const char \*name, const char \*mode\)$/ {
                  print; getline; print;
                  print "    if (unpins_vfs_is_virtual(name))";
                  print "\treturn unpins_vfs_fopen(name, mode);";
                  next;
              }
              { print }' src/os_win32.c > src/os_win32.c.new
              mv src/os_win32.c.new src/os_win32.c

              echo "==> add OBJ entries to Make_cyg_ming.mak"
              cat ${./patches/Make_cyg_ming_append} >> src/Make_cyg_ming.mak
            '';

            # Knobs (delta vs unpins/vim is GUI=yes + target):
            #   GUI=yes      — Win32 GUI build → gvim.exe (-mwindows subsystem).
            #   OLE=no       — skip Windows shell extension (gvimext.dll).
            #   DIRECTX=no   — skip Direct2D renderer; we use the GDI renderer.
            #   CROSS=yes    — skips host probes.
            #   STATIC_*=yes — embed gcc/winpthread runtime; no DLL companions.
            buildPhase = ''
              runHook preBuild

              # Pre-build our objects into OUTDIR (gobjx86-64 for ARCH=x86-64).
              mkdir -p src/gobjx86-64
              MINIZ_DEFS='-DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES'
              CFLAGS_BASE='-I. -O2 -march=x86-64 -DWIN32 -DWINVER=0x0601 -D_WIN32_WINNT=0x0601'
              ( cd src && \
                ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -o gobjx86-64/unpins_vfs.o            unpins_vfs.c          && \
                ${prefix}-gcc -c $CFLAGS_BASE             -o gobjx86-64/unpins_init.o           unpins_init.c         && \
                ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -w -o gobjx86-64/miniz.o              miniz.c               && \
                ${prefix}-gcc -c $CFLAGS_BASE             -o gobjx86-64/unpins_runtime_data.o   unpins_runtime_data.S )

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
              mkdir -p $out/bin
              cp src/gvim.exe $out/bin/gvim.exe
              # Runtime tree is embedded — no companion share/vim to ship.
              runHook postInstall
            '';

            passthru = { pname = "gvim"; inherit (pkgs.vim) version; };
          });
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

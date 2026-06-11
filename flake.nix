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
      ulib = unpins-lib.lib;

      # Man tree embedded into both the native gvim and gvim.exe (manRoot in
      # the per-target withUnpinEmbed call).
      # vim-full's installed man (vim/vimdiff/evim/vimtutor.1) is the same set
      # the gvim build produces and is version-locked to this flake's nixpkgs.
      # Upstream installs NO gvim.1 (nixpkgs skips vim's GUI man-link step; gvim
      # is documented inside vim.1), so synthesize a `.so man1/vim.1` redirect —
      # `unpin man gvim` then resolves to vim.1 through the .unpin_man kind-0
      # mechanism, no renderer special-case. Also gives gvim.exe man (the mingw
      # cross build ships none, and nixpkgs has no `gvim` attr to source from).
      # Sourced from the BUILD platform (buildPackages) so cross targets don't
      # cross-build vim-full just to harvest its (arch-independent) man pages.
      gvimMan = pkgs: pkgs.buildPackages.runCommand "gvim-man" { } ''
        mkdir -p $out/share/man/man1
        cp ${pkgs.buildPackages.vim-full}/share/man/man1/*.1.gz $out/share/man/man1/
        printf '.so man1/vim.1\n' > $out/share/man/man1/gvim.1
      '';

      # Stage the vim<NN>/ tree CONTENTS (no version prefix) as the ZIP root so
      # $VIMRUNTIME is exactly the mount marker -- same model as unpins/vim.
      # The tree is arch-independent text, so every target stages it from the
      # BUILD-host vim (one cache-hit drv for the whole matrix) instead of
      # harvesting a second full GTK2 build per arch, as the old .incbin zip
      # did. chmod: the store copy is read-only and the embed needs writable
      # staging.
      vimRuntimeStage = rtSrc: ''
        __vim_rt=$(ls -d ${rtSrc}/share/vim/vim* | head -1)
        cp -a "$__vim_rt/." "$__unpin_stage/"
        chmod -R u+w "$__unpin_stage"
      '';

      # Takes the per-target `pkgs` mkStandaloneFlake hands the `build` closure
      # (native scope, or a pkgsCross.<arch> scope for the Linux crosses), so a
      # single definition covers every Linux arch.
      linuxGvim = pkgs:
        let
          # graphite2's pkgsStatic .la still claims library_names=libgraphite2.so
          # (which isn't installed). libtool obeys the .la over the .a → link
          # fails. Strip the .la files.
          static = pkgs.pkgsStatic.extend (selfP: superP: {
            graphite2 = superP.graphite2.overrideAttrs (old: {
              postFixup = (old.postFixup or "") + ''
                find $out -name '*.la' -delete
              '';
            });
          } // superP.lib.optionalAttrs superP.stdenv.hostPlatform.isRiscV {
            # riscv64: libjpeg-turbo's RVV SIMD coverage helper (simdcoverage.c)
            # fails to compile under gcc-15 — the new RVV jsimd port doesn't
            # declare every jsimd_can_* the helper references
            # (jsimd_can_encode_mcu_AC_refine_prepare). Pulled in transitively
            # via gtk2 -> gdk-pixbuf's JPEG/TIFF image loaders. Reuse nix-lib's
            # shared fix (drops the unused helper; the RVV lib code is untouched)
            # — gate to riscv so the other arches keep the cache-hit libjpeg.
            libjpeg = ulib.nativeFixes."libjpeg-turbo" superP;
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
            # Replace the Makefiles of every non-installed subdir with a no-op.
            #   perf/  — testperf generates a duplicate marshalers.c whose
            #            symbols collide with gtk/gtkmarshalers.o under static
            #            link (original reason).
            #   tests/ demos/ examples/ — each builds dozens of throwaway
            #            programs that statically link the FULL GTK2 + X11 +
            #            codec closure (~20 MB apiece). They are never installed,
            #            but `make all` links them all, which blows the build
            #            tmpdir on disk-constrained runners ("No space left on
            #            device"). Skipping them leaves the installed lib
            #            byte-identical and keeps the cross builds CI-disk-safe.
            postConfigure = (old.postConfigure or "") + ''
              for d in perf tests demos examples; do
                [ -f "$d/Makefile" ] && \
                  printf 'all install clean check distclean install-strip:\n\t@true\n' \
                    > "$d/Makefile"
              done
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

          vim = vimBase.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              echo "==> inject unpin-vfs core (vfs.c + miniz.c, routed via ld --wrap)"
              cp ${./vfs.c}                   src/vfs.c
              cp ${./vfs.h}                   src/vfs.h
              cp ${./unpins_init.c}           src/unpins_init.c
              cp ${./miniz.h}                 src/miniz.h
              cp ${./miniz.c}                 src/miniz.c
              cp ${./unpin_zstd.c}            src/unpin_zstd.c
              cp ${./unpin_zstd.h}            src/unpin_zstd.h
              cp ${./zstddeclib.c}            src/zstddeclib.c

              echo "==> declare + call unpins_init() (env pin) after mch_early_init()"
              # No vim.h macro hooks anymore -- ld --wrap intercepts vim's libc
              # open/stat/opendir/... at link time (see patches/Makefile_append).
              sed -i '1i extern void unpins_init(void);' src/main.c
              sed -i '0,/mch_early_init();/{s|mch_early_init();|mch_early_init();\n    unpins_init();|}' src/main.c

              echo "==> add OBJ entries + compile rules to autotools Makefile"
              sed -i 's|$(XDIFF_OBJS_USED)|$(XDIFF_OBJS_USED) \\\n\tobjects/vfs.o \\\n\tobjects/unpins_init.o \\\n\tobjects/unpin_zstd.o \\\n\tobjects/miniz.o|' src/Makefile
              cat ${./patches/Makefile_append} >> src/Makefile
            '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.is32bit ''
              echo "==> 32-bit musl is _REDIR_TIME64: wrap the __stat_time64 aliases too"
              printf '%s\n' \
                'UNPIN_VFS_DEFS += -DUNPIN_WRAP_TIME64' \
                'override ALL_LIBS += -Wl,--wrap=__stat_time64 -Wl,--wrap=__lstat_time64' >> src/Makefile
            '';
          });
        in
        # vim-full installs `vim` (real binary, GUI-capable when configured)
        # plus symlinks: gvim, evim, view, vi, ex, rview, rvim, vimdiff. Vim's
        # mode is chosen by argv[0]. We ship just `gvim` → make it the real
        # file. Drop the desktop/icon files; unpins is CLI-only. Runtime
        # tree is embedded in the binary, so wipe share/vim/vim* too.
        #
        # ONE withUnpinEmbed call builds the whole embedded container in a
        # single pack: the runtime tree (read back by the VFS's self-EOF mode)
        # plus the man pages from the shared gvimMan tree (incl. the gvim→vim
        # .so redirect — nixpkgs has no `gvim` attr to harvest from, hence the
        # explicit manRoot). No aliases: gvim ships only the GUI binary.
        unpins-lib.lib.withUnpinEmbed pkgs
          {
            primary = "gvim";
            manRoot = "${gvimMan pkgs}";
            runtimeStage = vimRuntimeStage pkgs.buildPackages.vim;
          }
          (vim.overrideAttrs (old: {
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

        # gvim has no macOS build (on macOS, gvim ships as MacVim.app), so drop
        # every darwin attr from the auto-discovered matrix. All Linux archs +
        # Windows remain.
        linuxOnly = true;

        # `build` (native + every Linux cross) and `windowsBuild` each embed
        # man via their own withUnpinEmbed call (custom gvimMan tree — nixpkgs
        # has no `gvim` attr to graft from), so opt out of mkStandaloneFlake's
        # automatic embedMan. (The call's passthru.unpinEmbedsMan would make it
        # skip anyway; this just states the intent.)
        embedMan = false;

        # Linux native + cross (i686/ppc64le/riscv64/aarch64/armv7l): the static
        # GTK2 gvim is built from the per-target `pkgs` mkStandaloneFlake hands
        # us, so the whole matrix fans out automatically (same shape as
        # unpins/vim — no manual per-arch wiring below anymore).
        build = pkgs: linuxGvim pkgs;

        # Same Make_ming.mak path as unpins/vim, but GUI=yes so the build
        # links against Win32 GUI (USER32/GDI32/comdlg32/COMCTL32) and the
        # resulting binary is `gvim.exe` linked with -mwindows (Windows
        # subsystem; opens a window, doesn't attach to a console).
        windowsBuild = pkgs:
          let
            cross = pkgs.pkgsCross.mingwW64;
            prefix = cross.stdenv.hostPlatform.config;
          in
          # ONE withUnpinEmbed call, same shape as the native build: runtime
          # tree (from the native vim — host-agnostic text files) + man from
          # the shared gvimMan tree (mkStandaloneFlake's windows graft sources
          # from x86_64-linux.gvim, which nixpkgs lacks → null, so it must be
          # explicit here).
          unpins-lib.lib.withUnpinEmbed pkgs
            {
              primary = "gvim";
              manRoot = "${gvimMan pkgs}";
              runtimeStage = vimRuntimeStage pkgs.vim;
            }
            (cross.stdenv.mkDerivation {
            pname = "gvim";
            inherit (pkgs.vim) version src;

            dontConfigure = true;

            buildInputs = [ cross.windows.pthreads ];
            strictDeps = true;
            enableParallelBuilding = true;

            # Same unpin-vfs core as unpins/vim's Windows build, marker mode
            # (-DUNPIN_VFS_WIN_MARKER): vim canonicalises virtual paths to
            # "C:\<marker>\…" and there is no win32_* layer to --wrap, so the
            # real mch_open/mch_fopen get a virtual-path fast path patched in at
            # entry, calling the explicit unpin_vfs_* API. No xxd fold here --
            # gvim.exe is the GUI (-mwindows) binary only.
            postPatch = ''
              echo "==> inject unpin-vfs core sources"
              cp ${./vfs.h}                   src/vfs.h
              cp ${./vfs.c}                   src/vfs.c
              cp ${./unpins_init.c}           src/unpins_init.c
              cp ${./miniz.h}                 src/miniz.h
              cp ${./miniz.c}                 src/miniz.c
              cp ${./unpin_zstd.c}            src/unpin_zstd.c
              cp ${./unpin_zstd.h}            src/unpin_zstd.h
              cp ${./zstddeclib.c}            src/zstddeclib.c

              echo "==> declare + call unpins_init() (env pin) after mch_early_init()"
              sed -i '1i extern void unpins_init(void);' src/main.c
              sed -i '0,/mch_early_init();/{s|mch_early_init();|mch_early_init();\n    unpins_init();|}' src/main.c

              echo "==> patch os_win32.c mch_open/mch_fopen to dispatch virtual paths via the VFS"
              sed -i 's|^#include "vim.h"|#include "vim.h"\nextern int unpin_vfs_is_virtual(const char *);\nextern int unpin_vfs_open(const char *, int, ...);\nextern FILE *unpin_vfs_fopen(const char *, const char *);|' src/os_win32.c
              awk '
              /^mch_open\(const char \*name, int flags, int mode\)$/ {
                  print; getline; print;
                  print "    if (unpin_vfs_is_virtual(name))";
                  print "\treturn unpin_vfs_open(name, flags, mode);";
                  next;
              }
              /^mch_fopen\(const char \*name, const char \*mode\)$/ {
                  print; getline; print;
                  print "    if (unpin_vfs_is_virtual(name))";
                  print "\treturn unpin_vfs_fopen(name, mode);";
                  next;
              }
              { print }' src/os_win32.c > src/os_win32.c.new
              mv src/os_win32.c.new src/os_win32.c

              echo "==> patch os_mswin.c vim_stat so :runtime/:syntax/menu resolve in the VFS"
              # mch_stat is a macro -> vim_stat() -> stat_impl(). vim's
              # gen_expand_wildcards verifies a wildcard-free runtime file with
              # mch_getperm()->mch_stat() before sourcing, so without this the
              # runtime tree (syntax/menu/ftplugin/indent) is invisible to the
              # GUI too. Materialise to a temp and let vim's stat_impl fill stat_T.
              sed -i 's|^#include "vim.h"|#include "vim.h"\nextern int unpin_vfs_is_virtual(const char *);\nextern const char *unpin_vfs_winpath(const char *);|' src/os_mswin.c
              awk '
              /^vim_stat\(const char \*name, stat_T \*stp\)$/ {
                  print; getline; print;
                  print "    if (unpin_vfs_is_virtual(name)) {";
                  print "\tconst char *__m = unpin_vfs_winpath(name);";
                  print "\treturn __m ? stat_impl(__m, stp, TRUE) : -1;";
                  print "    }";
                  next;
              }
              { print }' src/os_mswin.c > src/os_mswin.c.new
              mv src/os_mswin.c.new src/os_mswin.c

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

              # Pre-build our objects into OUTDIR (gobjx86-64 for the GUI build).
              # Make_ming.mak's pattern rule doesn't carry the VFS/miniz defines,
              # so the explicit compile here is the simplest reliable hook. The
              # string-literal -D flags are inlined (single quotes round the
              # double quotes) so the C string survives the shell -- same form
              # the native Makefile_append uses.
              mkdir -p src/gobjx86-64
              MINIZ_DEFS='-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES'
              CFLAGS_BASE='-I. -O2 -march=x86-64 -DWIN32 -DWINVER=0x0601 -D_WIN32_WINNT=0x0601'
              ( cd src && \
                ${prefix}-gcc -c $CFLAGS_BASE \
                  -DUNPIN_VFS_WIN_MARKER='"__unpins_vimruntime__"' \
                  -DUNPIN_VFS_ROOT='"/__unpins_vimruntime__/"' \
                  -DUNPIN_VFS_SELF \
                  $MINIZ_DEFS -o gobjx86-64/vfs.o                vfs.c                 && \
                ${prefix}-gcc -c $CFLAGS_BASE                    -o gobjx86-64/unpins_init.o        unpins_init.c         && \
                ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -w     -o gobjx86-64/miniz.o              miniz.c               && \
                ${prefix}-gcc -c $CFLAGS_BASE $MINIZ_DEFS -DUNPIN_ZSTD_VENDORED -w -o gobjx86-64/unpin_zstd.o unpin_zstd.c )

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

    in
    base;
}

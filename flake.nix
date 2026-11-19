{
  description = "gvim (Linux GTK2 + Windows GUI) as a single self-contained binary";

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
      # runtimeEmbed below).
      # vim-full's installed man (vim/vimdiff/evim.1) is the same set the gvim
      # build produces and is version-locked to this flake's nixpkgs.
      # Upstream installs NO gvim.1 (nixpkgs skips vim's GUI man-link step; gvim
      # is documented inside vim.1), so synthesize a `.so man1/vim.1` redirect —
      # `unpin man gvim` then resolves to vim.1 through the .unpin_man kind-0
      # mechanism, no renderer special-case. Also gives gvim.exe man (the mingw
      # cross build ships none, and nixpkgs has no `gvim` attr to source from).
      # Sourced from the BUILD platform (buildPackages) so cross targets don't
      # cross-build vim-full just to harvest its (arch-independent) man pages.
      # vimtutor.1 is left out: it documents a shell script this artifact does
      # not contain and has no flag for, unlike evim.1 and vimdiff.1 -- `gvim
      # -y` and `gvim -d` are modes of this very binary (its own -h lists both).
      gvimMan = pkgs: pkgs.buildPackages.runCommand "gvim-man" { } ''
        mkdir -p $out/share/man/man1
        cp ${pkgs.buildPackages.vim-full}/share/man/man1/*.1.gz $out/share/man/man1/
        rm -f $out/share/man/man1/vimtutor.1.gz
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
          # The graphite2 (host python, .la), riscv libjpeg and X11 RAWCPP
          # fixes this flake used to carry are set-wide in nix-lib under the
          # engine.
          static = pkgs.pkgsStatic.extend (selfP: superP: {
            # pixman (via cairo) builds its test suite; `matrix-test` needs
            # __float128 soft-float builtins compiler-rt has not got on i686.
            # Only libpixman-1.a is linked.
            pixman = superP.pixman.overrideAttrs (o: {
              mesonFlags = (o.mesonFlags or [ ]) ++ [ "-Dtests=disabled" "-Ddemos=disabled" ];
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
            guiSupport = "gtk2";
            gtk2-x11 = gtk2static;
            luaSupport = false;
            pythonSupport = false;
            rubySupport = false;
            tclSupport = false;
            perlSupport = false;
            waylandSupport = false;
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
            patches = (old.patches or [ ]) ++ [
              ./patches/unpins-init.patch
              ./patches/makefile-unpin-objs.patch
            ];
            postPatch = (old.postPatch or "") + ''
              echo "==> inject unpin-vfs core (vfs.c + miniz.c, routed via ld --wrap)"
              cp ${ulib.vfsCore}/*.c ${ulib.vfsCore}/*.h src/
              cp ${./unpins_init.c} src/unpins_init.c

              # ld --wrap routes vim's libc open/stat/opendir/... through the
              # VFS at link time (patches/Makefile_append).
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
        # PRISTINE gvim base (no embed); the runtime tree + man (from the shared
        # gvimMan tree) are embedded once, post-build, via runtimeEmbed →
        # unpinEmbedWrap (the single embed path). No aliases: gvim ships only the
        # GUI binary.
        vim.overrideAttrs (old: {
          pname = "gvim";
          postInstall = (old.postInstall or "") + ''
            find "$out/bin" -mindepth 1 -not -name vim -delete
            mv "$out/bin/vim" "$out/bin/gvim"
            rm -rf "$out/share/applications" "$out/share/icons"
            rm -rf "$out"/share/vim/vim*
            rm -f  "$out/share/vim/vimrc"
            rmdir  "$out/share/vim" 2>/dev/null || true
          '';
        });

      base = unpins-lib.lib.mkStandaloneFlake {
        inherit self;
        name = "gvim";
        engine = "unpin-llvm";
        multicall = {
          # The `.exe` on the engine too, not the nixpkgs mingw-gcc cross.
          windows = true;
          # Both builds link `vim` and install it as gvim.
          programs = [{ name = "gvim"; linkName = "vim"; }];
        };

        # gvim had no smoke at all. `-v` forces the console UI (without it gvim
        # wants a display and exits 1), and ex mode is the only mode that writes
        # to stdout without a /dev/stdout redir. Reading a runtime file through
        # readfile() is what proves the embedded tree is reachable — a version
        # banner would print with the VFS unbound. The count must be NONZERO:
        # readfile() of a missing path returns an empty list, so an unreachable
        # runtime prints "0 lines".
        #
        # The SECOND count is there because reading a file by name and SEARCHING
        # a directory are different code paths: getcompletion() globs
        # colors/*.vim, so an unsearchable runtime prints "0 colors" while the
        # line count above stays perfectly green. That is exactly the shape the
        # Windows build shipped in.
        smoke = [
          "-v"
          "-e"
          "-s"
          "-u"
          "NONE"
          "-c"
          ''call setline(1, "unpins-runtime-ok ".len(readfile($VIMRUNTIME."/filetype.vim"))." lines ".len(getcompletion("", "color"))." colors features ".has("terminal").has("channel").has("job").has("sodium"))''
          "-c"
          "1p"
          "-c"
          "qa!"
        ];
        # `features 1111`: :terminal, channels, jobs and libsodium (`:X` with
        # xchacha20) — the Huge feature set, on both platforms.
        smokePattern = "unpins-runtime-ok [1-9][0-9]* lines [1-9][0-9]* colors features 1111";

        # …but not on windows: `GUI=yes` links gvim.exe -mwindows, and Windows
        # gives a GUI-subsystem process no console, so there is no stdout to
        # match — measured, `--version` and `-h` write nothing and never return.
        # `-v` only reaches the console UI where a console exists. CI checks the
        # PE really is GUI-subsystem, so this cannot go stale unnoticed.
        smokeWindows = false;

        # The .exe still gets executed, it just answers in a file. Same two
        # counts as the console smoke, and for the same reason: `readfile()`
        # proves the embedded runtime opens by name, `getcompletion()` globs
        # colors/*.vim and proves it can be SEARCHED — the half that was broken
        # on Windows while every other check stayed green.
        smokeWindowsGui = {
          files."probe.vim" = ''
            call writefile(["unpins-runtime-ok "
              \ .len(readfile($VIMRUNTIME."/filetype.vim"))." lines "
              \ .len(getcompletion("", "color"))." colors features "
              \ .has("terminal").has("channel").has("job").has("sodium")
              \ ." directx ".has("directx")." iconv ".has("iconv")], "probe.out")
            qa!
          '';
          # -f: don't fork, so the runner's shell waits for the exit. -u/-U
          # NONE: no vimrc/gvimrc of the runner's own. -i NONE: no viminfo.
          args = [ "-f" "-N" "-u" "NONE" "-U" "NONE" "-i" "NONE" "-S" "probe.vim" ];
          outFile = "probe.out";
          pattern = "unpins-runtime-ok [1-9][0-9]* lines [1-9][0-9]* colors features 1111 directx 1 iconv 1";
        };

        # gvim has no macOS build (on macOS, gvim ships as MacVim.app), so drop
        # every darwin attr from the auto-discovered matrix. All Linux archs +
        # Windows remain.
        linuxOnly = true;

        # Dead data paths the static link bakes in: the toolkit closure's
        # module/locale/config dirs (gtk+/glib/pango/gdk-pixbuf lib/, pango's
        # etc/, fontconfig's conf.avail and its dejavu fallback dir, X11's
        # XErrorDB/XKeysymDB/locale, libthai's thbrk.tri), ncurses' terminfo
        # and gvim's own share/vim -- the runtime tree rides the embedded VFS.
        # None is reachable for anyone running the artifact, yet Nix counted
        # all ten as runtime references: a 776 MB closure behind a 33 MB
        # self-contained binary. Measured with /nix/store bind-mounted empty:
        # the GTK2 window still comes up, the VFS runtime still loads, menus
        # and syntax still work. Same treatment `vim` already gets (16 MB
        # closure, 0 refs).
        removeReferences = [
          "gvim-static" "gtk+-static" "glib-static" "pango-static"
          "gdk-pixbuf-static" "fontconfig-static" "dejavu-fonts-minimal"
          "libx11-static" "libxt-static" "libxcursor-static" "libthai-static"
          "ncurses-static"
        ];

        # Both builds embed man through runtimeEmbed (custom gvimMan tree —
        # nixpkgs has no `gvim` attr to graft from), so opt out of
        # mkStandaloneFlake's automatic embedMan.
        embedMan = false;

        # Linux native + cross (i686/ppc64le/riscv64/aarch64/armv7l): the static
        # GTK2 gvim is built from the per-target `pkgs` mkStandaloneFlake hands
        # us, so the whole matrix fans out automatically (same shape as
        # unpins/vim — no manual per-arch wiring below anymore).
        build = pkgs: linuxGvim pkgs;

        # gvim embeds its own custom gvimMan tree (nixpkgs has no `gvim` attr to
        # graft from) + the vim runtime — both via runtimeEmbed → unpinEmbedWrap
        # (man = true overrides embedMan = false). Native runtime comes from the
        # build-host vim, windows from the native vim (host-agnostic text files).
        runtimeEmbed = {
          native = pkgs: base: {
            man = true;
            manRoot = "${gvimMan pkgs}";
            runtimeStage = vimRuntimeStage pkgs.buildPackages.vim;
          };
          windows = pkgs: base: {
            man = true;
            manRoot = "${gvimMan pkgs}";
            runtimeStage = vimRuntimeStage pkgs.vim;
          };
        };

        # Same Make_ming.mak path as unpins/vim, but GUI=yes so the build
        # links against Win32 GUI (USER32/GDI32/comdlg32/COMCTL32) and the
        # resulting binary is `gvim.exe` linked with -mwindows (Windows
        # subsystem; opens a window, doesn't attach to a console).
        windowsBuild = pkgs:
          let
            cross = pkgs.pkgsCross.mingwW64;
            prefix = cross.stdenv.hostPlatform.config;
            # vim's tree ships src/xpm/x64/lib/libXpm.a prebuilt against msvcrt
            # (`__iob_func`), which does not link into a UCRT binary. Build the
            # Win32 port its README names instead.
            xpm = cross.stdenv.mkDerivation {
              pname = "libxpm-win32";
              version = "unstable-2022-10-01";
              src = pkgs.fetchFromGitHub {
                owner = "koron";
                repo = "libXpm-win32";
                rev = "2fd6b2f88c4ce49e6f264469e447dd2dc41c576a";
                hash = "sha256-OKPGODmtIN4xJXYWgpw+EiHVWxA7DG1XoarhoeOVj/8=";
              };
              patches = [ ./patches/libxpm-win32-header-case.patch ];
              dontConfigure = true;
              buildPhase = ''
                make -C src -f Make_ming.mak CC=$CC AR=$AR -j$NIX_BUILD_CORES libXpm.a
              '';
              installPhase = ''
                install -Dm644 src/libXpm.a $out/lib/libXpm.a
                install -Dm644 include/X11/xpm.h $out/include/xpm.h
                install -Dm644 src/simx.h $out/include/simx.h
              '';
            };
            iconv = (ulib.mingwStaticCross pkgs).libiconv;
            sodium = (ulib.mingwStaticCross pkgs).libsodium;
          in
          cross.stdenv.mkDerivation {
            pname = "gvim";
            inherit (pkgs.vim) version src;

            dontConfigure = true;

            buildInputs = [ cross.windows.pthreads iconv sodium ];
            strictDeps = true;
            enableParallelBuilding = true;

            # Same unpin-vfs core as unpins/vim's Windows build, marker mode
            # (-DUNPIN_VFS_WIN_MARKER): vim canonicalises virtual paths to
            # "C:\<marker>\…" and there is no win32_* layer to --wrap, so the
            # real mch_open/mch_fopen get a virtual-path fast path patched in at
            # entry, calling the explicit unpin_vfs_* API. No xxd fold here --
            # gvim.exe is the GUI (-mwindows) binary only.
            patches = [
              ./patches/unpins-init.patch
              ./patches/windows-toolbar-metrics.patch
              ./patches/windows-main-entry.patch
              ./patches/windows-vfs-open.patch
              ./patches/windows-vfs-stat.patch
              ./patches/windows-vfs-getfileattributes.patch
              ./patches/windows-vfs-findfirst.patch
            ];
            postPatch = ''
              echo "==> inject unpin-vfs core sources"
              cp ${ulib.vfsCore}/*.c ${ulib.vfsCore}/*.h src/
              cp ${./unpins_init.c} src/unpins_init.c

              echo "==> add OBJ entries to Make_cyg_ming.mak"
              cat ${./patches/Make_cyg_ming_append} >> src/Make_cyg_ming.mak
            '';

            # Knobs (delta vs unpins/vim is GUI=yes + target):
            #   GUI=yes      — Win32 GUI build → gvim.exe (-mwindows subsystem).
            #   OLE=no       — no OLE automation server (registering one writes
            #                  the registry, which a portable binary doesn't).
            #   DIRECTX=yes  — DirectWrite renderer (`:set renderoptions=type:directx`);
            #                  d2d1/dwrite are loaded from System32 at run time.
            #   SODIUM=…     — libsodium linked statically (DYNAMIC_SODIUM=no).
            #   CROSS=yes    — skips host probes.
            #   STATIC_WINPTHREAD=yes — winpthread linked statically.
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

              # HAS_GCC_EH=no: the engine has no libgcc_eh (it unwinds with libunwind).
              # STATIC_STDCPLUS=no: it would add -lstdc++ -lgcc for gui_dwrite.cpp;
              # the engine clang++ links its own libc++ statically.
              # TARGET=vim.exe: link under the name the native build links (see
              # `linkName`), installed as gvim.exe below.
              make -C src -f Make_ming.mak \
                FEATURES=HUGE \
                ICONV= \
                GUI=yes \
                XPM=${xpm} \
                OLE=no \
                DIRECTX=yes \
                SODIUM=${sodium.dev or sodium} \
                DYNAMIC_SODIUM=no \
                CROSS=yes \
                CROSS_COMPILE=${prefix}- \
                STATIC_STDCPLUS=no \
                STATIC_WINPTHREAD=yes \
                HAS_GCC_EH=no \
                WINDRES=${prefix}-windres \
                ARCH=x86-64 \
                TARGET=vim.exe \
                -j$NIX_BUILD_CORES \
                vim.exe
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp src/vim.exe $out/bin/gvim.exe
              # Runtime tree is embedded — no companion share/vim to ship.
              runHook postInstall
            '';

            passthru = { pname = "gvim"; inherit (pkgs.vim) version; };
          };
      };

    in
    base;
}

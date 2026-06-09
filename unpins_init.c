/* gvim startup glue for the unpin-vfs runtime.
 *
 * Called once from main() right after mch_early_init(). The runtime tree is a
 * ZIP blob embedded as a section (unpins_runtime_data.S); the unpin-vfs core
 * (vfs.c, linked via `ld --wrap`) serves every libc open/stat/opendir/... whose
 * path falls under the mount root. All this glue does is pin $VIMRUNTIME/$VIM at
 * that root so vim's runtime discovery produces paths the wrappers intercept.
 *
 * Same model as unpins/vim, minus the xxd multicall: gvim ships only the `gvim`
 * binary (the GUI build renames vim -> gvim and drops every other applet), so
 * there is no xxd applet to dispatch here.
 *
 * The mount root must match -DUNPIN_VFS_ROOT passed to vfs.c (see flake.nix).
 * The runtime ZIP holds the vim92/ tree CONTENTS directly (no version prefix),
 * so $VIMRUNTIME is exactly the marker.
 *
 * Idempotent: multiple calls no-op after the first success.
 */

#include "vfs.h"

#include <stdio.h>
#include <stdlib.h>

/* Bare mount point (no trailing slash); UNPIN_VFS_ROOT is this + "/". */
#define VFS_PREFIX "/__unpins_vimruntime__"

void unpins_init(void)
{
    static int done;
    if (done) return;

    const char *dbg = getenv("UNPINS_DEBUG");
    if (dbg) fprintf(stderr, "[unpins] unpins_init called\n");

    /* Fail fast (and visibly under UNPINS_DEBUG) if the embedded blob is
     * unusable; the wrappers would otherwise just lazily ENOENT later. */
    if (!unpin_vfs_init()) {
        if (dbg) fprintf(stderr, "[unpins] unpin_vfs_init failed\n");
        return;
    }
    if (dbg) fprintf(stderr, "[unpins] VFS ready, VIMRUNTIME=%s\n", VFS_PREFIX);

#ifdef _WIN32
    _putenv("VIMRUNTIME=" VFS_PREFIX);
    _putenv("VIM=" VFS_PREFIX "/..");
#else
    setenv("VIMRUNTIME", VFS_PREFIX, 1);
    setenv("VIM", VFS_PREFIX "/..", 1);
#endif

    done = 1;
}

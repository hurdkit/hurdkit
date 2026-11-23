# Shared 3p source pins, imported by the top-level Makefile (image pipeline)
# and toolchain/Makefile (cross toolchain). Every 3p repo is listed once:
# its clone URL and its verified commit. Changing a pin here updates both
# Makefiles; there is no second place to forget.

# Clone URLs for the 3p checkouts (keyed by repo name, "repo:url").
3P_REPOS := \
	mig:https://git.savannah.gnu.org/git/hurd/mig.git \
	gnumach:https://github.com/hurdkit/gnumach.git \
	glibc:https://sourceware.org/git/glibc.git \
	hurd:https://github.com/hurdkit/hurd.git \
	parted:https://git.savannah.gnu.org/git/parted.git \
	9pfs:https://github.com/bugaevc/9pfs.git \
	libpciaccess:https://gitlab.freedesktop.org/xorg/lib/libpciaccess.git

# Verified commits the toolchain builds against (keyed by repo name,
# "repo:sha"). Matches the 3P_PINS that used to live in toolchain/Makefile.
# gnumach and hurd are pinned to branches instead of hashes
# ("repo:@branch"): each pin checkout tracks that branch, so an upstream push
# moves the build forward with it
3P_PINS := \
	mig:cb48044b30fcfe10529ecc1129dd68e93ed73835 \
	glibc:03628c2f85acaab6ef71c37c954fd0707685e0f0 \
	gnumach:@hurdkit \
	hurd:@hurdkit \
	parted:35909e6ae55fdfbde03c449a0ca170dda6bbbd3b \
	9pfs:b5b23deb1df6eb383fd2c0f5271c068861b745a8 \
	libpciaccess:e33aa5fd28f63b9842e36c1a8a954577eec042e3

# Where to fetch a pinned commit when it is not reachable from origin.
3P_PIN_REMOTES := \
	libpciaccess:https://gitlab.freedesktop.org/xorg/lib/libpciaccess.git

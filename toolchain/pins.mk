# Shared 3p source pins, imported by the top-level Makefile (image pipeline)
# and toolchain/Makefile (cross toolchain). Every 3p repo is listed once:
# its clone URL and its verified commit. Changing a pin here updates both
# Makefiles; there is no second place to forget.

# Clone URLs for the 3p checkouts (keyed by repo name, "repo:url").
3P_REPOS := \
	mig:https://git.savannah.gnu.org/git/hurd/mig.git \
	gnumach:https://git.savannah.gnu.org/git/hurd/gnumach.git \
	glibc:https://sourceware.org/git/glibc.git \
	hurd:https://github.com/joshumax/hurd.git \
	9pfs:https://github.com/bugaevc/9pfs.git \
	partitionfs:https://github.com/madscientist42/partitionfs.git \
	libpciaccess:https://gitlab.freedesktop.org/xorg/lib/libpciaccess.git

# Verified commits the toolchain builds against (keyed by repo name,
# "repo:sha"). Matches the 3P_PINS that used to live in toolchain/Makefile.
3P_PINS := \
	mig:cb48044b30fcfe10529ecc1129dd68e93ed73835 \
	glibc:03628c2f85acaab6ef71c37c954fd0707685e0f0 \
	gnumach:12a3efa846b574070f90aa0c22c3f3e67cca10c4 \
	hurd:9b556c6ad91197125bff8261462f51b024ad8e00 \
	9pfs:b5b23deb1df6eb383fd2c0f5271c068861b745a8 \
	partitionfs:1da79f0d12383dab960ca9b2a5b60f4ee738a2a2 \
	libpciaccess:e33aa5fd28f63b9842e36c1a8a954577eec042e3

# Where to fetch a pinned commit when it is not reachable from origin.
3P_PIN_REMOTES := \
	libpciaccess:https://gitlab.freedesktop.org/xorg/lib/libpciaccess.git

# Partitionfs is the only 3p dependency of the base image pipeline
# (scripts/prepare_base.sh runs its binary). These mirror the partitionfs
# entries in 3P_REPOS / 3P_PINS above; they are split out so the top-level
# Makefile can fetch and pin partitionfs alone without importing the rest
# of the toolchain's pin list.
PARTITIONFS_URL  := https://github.com/madscientist42/partitionfs.git
PARTITIONFS_PIN  := 1da79f0d12383dab960ca9b2a5b60f4ee738a2a2

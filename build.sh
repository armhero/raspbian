#!/bin/sh

set -e
set -x

usage() {
	printf >&2 '%s: [-a arch] [-r release] [-t tag] [-m mirror] [-t tag]\n' "$0"
	exit 1
}

tmp() {
	TMP=$(mktemp -d ${TMPDIR:-$PWD}/raspbian-docker-XXXXXXXXXX)
	ROOTFS=$(mktemp -d ${TMPDIR:-$PWD}/raspbian-docker-rootfs-XXXXXXXXXX)
	trap "rm -rf $TMP $ROOTFS" EXIT TERM INT
}

mkbase() {
	cd $TMP
	echo "Creating rootfs in $ROOTFS"
	debootstrap --arch $ARCH --variant minbase $REL $ROOTFS/ $MIRROR
}

conf() {
	# some Docker-specific tweaks

	# prevent init scripts from running during install/update
	echo >&2 "+ echo exit 101 > '$ROOTFS/usr/sbin/policy-rc.d'"
	cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh

# For most Docker users, "apt-get install" only happens during "docker build",
# where starting services doesn't work and often fails in humorous ways. This
# prevents those failures by stopping the services from attempting to start.

exit 101
EOF
	chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

	# prevent upstart scripts from running during install/update
	(
		set -x
		chroot "$ROOTFS" dpkg-divert --local --rename --add /sbin/initctl
		cp -a "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS/sbin/initctl"
		sed -i 's/^exit.*/exit 0/' "$ROOTFS/sbin/initctl"
	)

	# shrink a little, since apt makes us cache-fat (wheezy: ~157.5MB vs ~120MB)
	( set -x; chroot "$ROOTFS" apt-get clean )

	# this file is one APT creates to make sure we don't "autoremove" our currently
	# in-use kernel, which doesn't really apply to debootstraps/Docker images that
	# don't even have kernels installed
	rm -f "$ROOTFS/etc/apt/apt.conf.d/01autoremove-kernels"

	# Ubuntu 10.04 sucks... :)
	if strings "$ROOTFS/usr/bin/dpkg" | grep -q unsafe-io; then
		# force dpkg not to call sync() after package extraction (speeding up installs) echo >&2 "+ echo force-unsafe-io > '$ROOTFS/etc/dpkg/dpkg.cfg.d/docker-apt-speedup'"
		cat > "$ROOTFS/etc/dpkg/dpkg.cfg.d/docker-apt-speedup" <<-'EOF'
		# For most Docker users, package installs happen during "docker build", which
		# doesn't survive power loss and gets restarted clean afterwards anyhow, so
		# this minor tweak gives us a nice speedup (much nicer on spinning disks,
		# obviously).

		force-unsafe-io
		EOF
	fi

	if [ -d "$ROOTFS/etc/apt/apt.conf.d" ]; then
		# _keep_ us lean by effectively running "apt-get clean" after every install
		aptGetClean='"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true";'
		echo >&2 "+ cat > '$ROOTFS/etc/apt/apt.conf.d/docker-clean'"
		cat > "$ROOTFS/etc/apt/apt.conf.d/docker-clean" <<-EOF
			# Since for most Docker users, package installs happen in "docker build" steps,
			# they essentially become individual layers due to the way Docker handles
			# layering, especially using CoW filesystems.  What this means for us is that
			# the caches that APT keeps end up just wasting space in those layers, making
			# our layers unnecessarily large (especially since we'll normally never use
			# these caches again and will instead just "docker build" again and make a brand
			# new image).

			# Ideally, these would just be invoking "apt-get clean", but in our testing,
			# that ended up being cyclic and we got stuck on APT's lock, so we get this fun
			# creation that's essentially just "apt-get clean".
			DPkg::Post-Invoke { ${aptGetClean} };
			APT::Update::Post-Invoke { ${aptGetClean} };

			Dir::Cache::pkgcache "";
			Dir::Cache::srcpkgcache "";

			# Note that we do realize this isn't the ideal way to do this, and are always
			# open to better suggestions (https://github.com/docker/docker/issues).
		EOF

		# remove apt-cache translations for fast "apt-get update"
		echo >&2 "+ echo Acquire::Languages 'none' > '$ROOTFS/etc/apt/apt.conf.d/docker-no-languages'"
		cat > "$ROOTFS/etc/apt/apt.conf.d/docker-no-languages" <<-'EOF'
		# In Docker, we don't often need the "Translations" files, so we're just wasting
		# time and space by downloading them, and this inhibits that.  For users that do
		# need them, it's a simple matter to delete this file and "apt-get update". :)

		Acquire::Languages "none";
		EOF

		echo >&2 "+ echo Acquire::GzipIndexes 'true' > '$ROOTFS/etc/apt/apt.conf.d/docker-gzip-indexes'"
		cat > "$ROOTFS/etc/apt/apt.conf.d/docker-gzip-indexes" <<-'EOF'
		# Since Docker users using "RUN apt-get update && apt-get install -y ..." in
		# their Dockerfiles don't go delete the lists files afterwards, we want them to
		# be as small as possible on-disk, so we explicitly request "gz" versions and
		# tell Apt to keep them gzipped on-disk.

		# For comparison, an "apt-get update" layer without this on a pristine
		# "debian:wheezy" base image was "29.88 MB", where with this it was only
		# "8.273 MB".

		Acquire::GzipIndexes "true";
		Acquire::CompressionTypes::Order:: "gz";
		EOF
	fi

	chroot "$ROOTFS" bash -c 'apt-get update && apt-get dist-upgrade -y'

	rm -rf "$ROOTFS/var/lib/apt/lists"/*
}

pack() {
	local id
	id=$(tar --numeric-owner -C $ROOTFS -c . | docker import - armhero/raspbian:$REL)

	docker tag $id armhero/raspbian:$TAG
	docker run --rm armhero/raspbian:$TAG cat /etc/os-release
}

while getopts ":a:r:m:t:h" opt; do
	case $opt in
		a)
		  ARCH=$OPTARG
		  ;;
		r)
			REL=$OPTARG
			;;
		m)
			MIRROR=$OPTARG
			;;
		t)
		  TAG=$OPTARG
			;;
		h)
			usage
			;;
		\?)
	    echo "Invalid option: -$OPTARG" >&2
			exit 1
	    ;;
	esac
done

REL=${REL:-jessie}
MIRROR=${MIRROR:-http://archive.raspbian.com/raspbian}
ARCH=${ARCH:-armhf}
TAG=${TAG:-latest}

echo "Create tmp..."
tmp
echo "Create baseimage..."
mkbase
echo "Tweak system..."
conf
echo "Pack image..."
pack
echo "Finished!"
exit 0

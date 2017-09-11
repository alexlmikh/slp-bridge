VERSION := $(shell cat version.txt)

all: clean build

build: 

	mkdir -p build/slpbridge-${VERSION}
	cp -R package/* build/slpbridge-${VERSION}/
	sed -i 's/$${VERSION}/'${VERSION}'/' build/slpbridge-${VERSION}/DEBIAN/control

	mkdir -p build/slpbridge-${VERSION}/usr/local/sbin/
	cp slpbridge.pl build/slpbridge-${VERSION}/usr/local/sbin/slpbridge
	dpkg-deb --build build/slpbridge-${VERSION}/	

clean:

	rm -rf build

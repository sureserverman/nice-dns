# gui/mac: the macOS GUI of nice-dns.
#
#   make               check the bundled action table, build, and assemble
#                      build/nice-dns.app (ad-hoc signed)
#   make check         run KitCheck
#   make screenshot    the app's --screenshot hook, into build/screenshot.png
#   make strings       copy ../share/actions.tsv into the kit's resources
#   make strings-check fail when the kit's copy differs from ../share/actions.tsv
#   make clean         remove build/ and .build/
#
# The copy is committed so `swift build` needs no make step; KitCheck checks it
# against ../share/actions.tsv as well. VERSION (default 0.0.0) goes into the
# app's Info.plist; the release job passes the tag without its v.

SHARED_TABLE := ../share/actions.tsv
KIT_TABLE    := Sources/NiceDNSKit/Resources/actions.tsv
APP          := build/nice-dns.app
LOGO         := ../../docs/images/logo.png
VERSION      ?= 0.0.0
# The logo's globe mark (568x250 logo; mark at 55,64-212,205), cut square as
# the Linux icon is: the wordmark is unreadable at icon size.
MARK_CROP    := --cropToHeightWidth 170 170 --cropOffset 49 48

.PHONY: all build app check screenshot strings strings-check clean

all: app

build: strings-check
	swift build -c release

# The kit's resource bundle goes into Contents/Resources, where the kit looks
# for it first (Actions.resourceBundleCandidates).
app: build build/AppIcon.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/NiceDNSGUI $(APP)/Contents/MacOS/NiceDNSGUI
	cp -R .build/release/NiceDNS_NiceDNSKit.bundle $(APP)/Contents/Resources/
	cp build/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	sed 's/__VERSION__/$(VERSION)/g' Info.plist > $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP)

build/AppIcon.icns: $(LOGO) Makefile
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	sips -s format png $(MARK_CROP) $(LOGO) --out build/mark.png >/dev/null
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s build/mark.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null && \
	  sips -z $$((s * 2)) $$((s * 2)) build/mark.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null || exit 1; \
	done
	iconutil -c icns build/AppIcon.iconset -o $@

check:
	swift run KitCheck

screenshot: app
	$(APP)/Contents/MacOS/NiceDNSGUI --screenshot build/screenshot.png

strings:
	cp $(SHARED_TABLE) $(KIT_TABLE)

strings-check:
	@if cmp -s $(SHARED_TABLE) $(KIT_TABLE); then \
	  echo "strings-check: $(KIT_TABLE) equals $(SHARED_TABLE)"; \
	else \
	  echo "strings-check: $(KIT_TABLE) differs from $(SHARED_TABLE); run make strings" >&2; \
	  diff $(SHARED_TABLE) $(KIT_TABLE) >&2; \
	  exit 1; \
	fi

clean:
	rm -rf build .build

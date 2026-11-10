# gui/mac: the macOS GUI of nice-dns.
#
#   make               check the bundled action table, then swift build -c release
#   make strings       copy ../share/actions.tsv into the kit's resources
#   make strings-check fail when the kit's copy differs from ../share/actions.tsv
#
# The copy is committed so `swift build` needs no make step; KitCheck checks it
# against ../share/actions.tsv as well.

SHARED_TABLE := ../share/actions.tsv
KIT_TABLE    := Sources/NiceDNSKit/Resources/actions.tsv

.PHONY: all build strings strings-check

all: build

build: strings-check
	swift build -c release

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

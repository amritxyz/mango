PROJECT     := mango
VERSION     := 0.18.6

PREFIX      ?= /usr/local
SYSCONFDIR  ?= /etc
MANDIR      ?= $(PREFIX)/share/man
DESTDIR     ?=
BUILDDIR    ?= build

XWAYLAND    ?= 1
ASAN        ?= 0

CC          ?= cc
PKG_CONFIG  ?= pkg-config

# Parallel jobs (`make JOBS=12`)
JOBS        ?= 12
MAKEFLAGS   += -j$(JOBS)

# version
GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null)
ifeq ($(GIT_HASH),)
GIT_HASH := release
endif
VERSION_FULL := $(VERSION)($(GIT_HASH))

# deps
WAYLAND_SCANNER := $(shell $(PKG_CONFIG) --variable=wayland_scanner wayland-scanner 2>/dev/null)
ifeq ($(WAYLAND_SCANNER),)
WAYLAND_SCANNER := wayland-scanner
endif
WL_PROTO_DIR := $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols 2>/dev/null)

MANGO_PKGS := libdrm wayland-server wlroots-0.20 xkbcommon libinput \
              wayland-client libpcre2-8 scenefx-0.5 pixman-1 libcjson pangocairo
MMSG_PKGS  := wayland-client wlroots-0.20 libpcre2-8
NAG_PKGS   := wayland-client pangocairo

C_DEFS := -DWLR_USE_UNSTABLE -D_POSIX_C_SOURCE=200809L
C_BASE := -g -O2 -U_FORTIFY_SOURCE -Wno-unused-function -Wno-unused-parameter
LDLIBS_BASE :=

ifeq ($(XWAYLAND),1)
MANGO_PKGS += xcb xcb-icccm xcb-randr
C_DEFS     += -DXWAYLAND
endif

ifeq ($(ASAN),1)
C_BASE      += -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls
LDLIBS_BASE += -fsanitize=address
endif

pkgcflags = $(shell $(PKG_CONFIG) --cflags $(1))
pkglibs   = $(shell $(PKG_CONFIG) --libs $(1))

# ---------------------------------------------------------------- protocols
# Local protocol XMLs plus the ones taken from wayland-protocols.
# ADJUST WLP_XMLS to match what protocols/meson.build uses.
WLP_XMLS := \
	$(WL_PROTO_DIR)/stable/xdg-shell/xdg-shell.xml \
	$(WL_PROTO_DIR)/unstable/xdg-output/xdg-output-unstable-v1.xml \
	$(WL_PROTO_DIR)/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml \
	$(WL_PROTO_DIR)/unstable/relative-pointer/relative-pointer-unstable-v1.xml

PROTO_XMLS  := $(wildcard protocols/*.xml) $(WLP_XMLS)
PROTO_NAMES := $(sort $(basename $(notdir $(PROTO_XMLS))))

vpath %.xml $(sort $(dir $(PROTO_XMLS)))

SERVER_HDRS := $(PROTO_NAMES:%=$(BUILDDIR)/server/%-protocol.h)
CLIENT_HDRS := $(PROTO_NAMES:%=$(BUILDDIR)/client/%-protocol.h)
PROTO_SRCS  := $(PROTO_NAMES:%=$(BUILDDIR)/proto/%-protocol.c)
PROTO_OBJS  := $(PROTO_SRCS:.c=.o)

$(BUILDDIR)/server/%-protocol.h: %.xml
	@mkdir -p $(@D)
	$(WAYLAND_SCANNER) server-header $< $@

$(BUILDDIR)/client/%-protocol.h: %.xml
	@mkdir -p $(@D)
	$(WAYLAND_SCANNER) client-header $< $@

$(BUILDDIR)/proto/%-protocol.c: %.xml
	@mkdir -p $(@D)
	$(WAYLAND_SCANNER) private-code $< $@

# ---------------------------------------------------------------- mango
SRCS := $(shell find src -name '*.c')
OBJS := $(SRCS:%.c=$(BUILDDIR)/obj/%.o)

MANGO_CFLAGS := $(C_BASE) $(C_DEFS) \
	-DVERSION='"$(VERSION_FULL)"' -DSYSCONFDIR='"/etc"' \
	-I. -Iinclude -I$(BUILDDIR)/server $(call pkgcflags,$(MANGO_PKGS))

$(BUILDDIR)/obj/src/%.o: src/%.c | $(SERVER_HDRS)
	@mkdir -p $(@D)
	$(CC) $(MANGO_CFLAGS) -Wno-unused-result -MMD -MP -c $< -o $@

$(BUILDDIR)/proto/%.o: $(BUILDDIR)/proto/%.c
	$(CC) $(C_BASE) $(C_DEFS) -c $< -o $@

MANGO_BIN := $(BUILDDIR)/mango
$(MANGO_BIN): $(OBJS) $(PROTO_OBJS)
	$(CC) $^ -o $@ $(LDLIBS_BASE) -lm $(call pkglibs,$(MANGO_PKGS))

# mmsg
MMSG_SRCS := mmsg/mmsg.c src/config/error_store.c src/common/log.c src/common/util.c
MMSG_OBJS := $(MMSG_SRCS:%.c=$(BUILDDIR)/mmsg-obj/%.o)

MMSG_CFLAGS := $(C_BASE) $(C_DEFS) -I. -Iinclude -I$(BUILDDIR)/client \
	$(call pkgcflags,$(MMSG_PKGS))

$(BUILDDIR)/mmsg-obj/%.o: %.c | $(CLIENT_HDRS)
	@mkdir -p $(@D)
	$(CC) $(MMSG_CFLAGS) -MMD -MP -c $< -o $@

MMSG_BIN := $(BUILDDIR)/mmsg
$(MMSG_BIN): $(MMSG_OBJS) $(PROTO_OBJS)
	$(CC) $^ -o $@ $(LDLIBS_BASE) $(call pkglibs,$(MMSG_PKGS))

# mangonag
NAG_GEN := $(BUILDDIR)/mangonag-gen
NAG_HDRS := $(NAG_GEN)/wlr-layer-shell-unstable-v1-client-protocol.h \
            $(NAG_GEN)/xdg-shell-client-protocol.h
NAG_PROTO_OBJS := $(NAG_GEN)/wlr-layer-shell-unstable-v1-protocol.o \
                  $(NAG_GEN)/xdg-shell-protocol.o

$(NAG_GEN)/wlr-layer-shell-unstable-v1-client-protocol.h: protocols/wlr-layer-shell-unstable-v1.xml
	@mkdir -p $(@D)
	$(WAYLAND_SCANNER) client-header $< $@
$(NAG_GEN)/wlr-layer-shell-unstable-v1-protocol.c: protocols/wlr-layer-shell-unstable-v1.xml
	@mkdir -p $(@D)
	$(WAYLAND_SCANNER) private-code $< $@
$(NAG_GEN)/xdg-shell-client-protocol.h: $(WL_PROTO_DIR)/stable/xdg-shell/xdg-shell.xml
	@mkdir -p $(@D)
	$(WAYLAND_SCANNER) client-header $< $@
$(NAG_GEN)/xdg-shell-protocol.c: $(WL_PROTO_DIR)/stable/xdg-shell/xdg-shell.xml
	@mkdir -p $(@D)
	$(WAYLAND_SCANNER) private-code $< $@

NAG_CFLAGS := $(C_BASE) $(C_DEFS) -I. -Iinclude -I$(NAG_GEN) $(call pkgcflags,$(NAG_PKGS))

$(NAG_GEN)/%.o: $(NAG_GEN)/%.c
	$(CC) $(NAG_CFLAGS) -c $< -o $@

$(BUILDDIR)/mangonag.o: mangonag/mangonag.c $(NAG_HDRS)
	$(CC) $(NAG_CFLAGS) -MMD -MP -c $< -o $@

NAG_BIN := $(BUILDDIR)/mangonag
$(NAG_BIN): $(BUILDDIR)/mangonag.o $(NAG_PROTO_OBJS)
	$(CC) $^ -o $@ $(LDLIBS_BASE) $(call pkglibs,$(NAG_PKGS))

# man pages
$(BUILDDIR)/mmsg.1: mmsg/mmsg.1.in
	@mkdir -p $(@D)
	sed 's/@VERSION@/$(VERSION)/g' $< > $@

$(BUILDDIR)/mangonag.1: mangonag/mangonag.1.in
	@mkdir -p $(@D)
	sed 's/@VERSION@/$(VERSION)/g' $< > $@

# targets
.PHONY: all install uninstall clean
all: $(MANGO_BIN) $(MMSG_BIN) $(NAG_BIN) $(BUILDDIR)/mmsg.1 $(BUILDDIR)/mangonag.1

install: all
	install -Dm755 $(MANGO_BIN) $(DESTDIR)$(PREFIX)/bin/mango
	install -Dm755 $(MMSG_BIN)  $(DESTDIR)$(PREFIX)/bin/mmsg
	install -Dm755 $(NAG_BIN)   $(DESTDIR)$(PREFIX)/bin/mangonag
	install -Dm644 assets/mango.desktop       $(DESTDIR)$(PREFIX)/share/wayland-sessions/mango.desktop
	install -Dm644 assets/mango-portals.conf  $(DESTDIR)$(PREFIX)/share/xdg-desktop-portal/mango-portals.conf
	install -Dm644 assets/config.conf         $(DESTDIR)$(SYSCONFDIR)/mango/config.conf
	install -Dm644 assets/config.toml         $(DESTDIR)$(SYSCONFDIR)/mango/config.toml
	install -Dm644 assets/mango-session.target $(DESTDIR)$(PREFIX)/lib/systemd/user/mango-session.target
	install -Dm644 $(BUILDDIR)/mmsg.1         $(DESTDIR)$(MANDIR)/man1/mmsg.1
	install -Dm644 $(BUILDDIR)/mangonag.1     $(DESTDIR)$(MANDIR)/man1/mangonag.1

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/mango $(DESTDIR)$(PREFIX)/bin/mmsg $(DESTDIR)$(PREFIX)/bin/mangonag
	rm -f $(DESTDIR)$(PREFIX)/share/wayland-sessions/mango.desktop
	rm -f $(DESTDIR)$(PREFIX)/share/xdg-desktop-portal/mango-portals.conf
	rm -rf $(DESTDIR)$(SYSCONFDIR)/mango
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/user/mango-session.target
	rm -f $(DESTDIR)$(MANDIR)/man1/mmsg.1 $(DESTDIR)$(MANDIR)/man1/mangonag.1

clean:
	rm -rf $(BUILDDIR)

-include $(OBJS:.o=.d) $(MMSG_OBJS:.o=.d) $(BUILDDIR)/mangonag.d

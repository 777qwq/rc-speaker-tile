export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:26.5:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PWCTL
PWCTL_FILES = PWCTL.x
PWCTL_FRAMEWORKS = CoreBluetooth UIKit
PWCTL_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

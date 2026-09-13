export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:26.5:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RCSpeakerSB RCSpeakerApp
RCSpeakerSB_FILES = RCSpeakerSB.x
RCSpeakerSB_FRAMEWORKS = UIKit Foundation
RCSpeakerApp_FILES = RCSpeakerApp.x
RCSpeakerApp_FRAMEWORKS = AVFAudio

BUNDLE_NAME = RCSpeakerToggle
RCSpeakerToggle_FILES = RCSpeakerToggle.x
RCSpeakerToggle_FRAMEWORKS = UIKit CoreGraphics
RCSpeakerToggle_INSTALL_PATH = /Library/ControlCenter/Bundles
RCSpeakerToggle_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

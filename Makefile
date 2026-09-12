export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = RCSpeakerToggle

RCSpeakerToggle_FILES = RCSpeakerToggle.x
RCSpeakerToggle_FRAMEWORKS = UIKit CoreGraphics
RCSpeakerToggle_PRIVATE_FRAMEWORKS = ControlCenterUIKit
RCSpeakerToggle_INSTALL_PATH = /Library/ControlCenter/Bundles
RCSpeakerToggle_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

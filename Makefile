TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BlockpostESP

BlockpostESP_FILES = Tweak.xm
BlockpostESP_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

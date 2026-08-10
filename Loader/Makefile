TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BlockpostESPLoader

# LOADER_TOKEN must be set in the environment (CI: from the LOADER_TOKEN repo
# secret). Never hardcode the token here or in source — GitHub's push
# protection will reject the commit outright, and it shouldn't be in git
# history regardless.
ifndef LOADER_TOKEN
$(error LOADER_TOKEN is not set — export it before running make, see build.yml)
endif

BlockpostESPLoader_FILES = LoaderTweak.xm
BlockpostESPLoader_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -DGH_TOKEN='"$(LOADER_TOKEN)"'
BlockpostESPLoader_CCFLAGS = -std=c++17
BlockpostESPLoader_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

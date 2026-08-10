TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BlockpostESP

BlockpostESP_FILES = Tweak.xmm imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp imgui/imgui_widgets.cpp imgui/backends/imgui_impl_metal.mm
BlockpostESP_CFLAGS = -fobjc-arc -Iimgui -Iimgui/backends -Wno-unused-variable -Wno-deprecated-declarations
BlockpostESP_CCFLAGS = -std=c++17
BlockpostESP_FRAMEWORKS = UIKit CoreGraphics QuartzCore Metal MetalKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

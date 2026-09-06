TARGET := iphone:clang:latest:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Spotify

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotifyEQPro
SpotifyEQPro_FILES = Tweak.m
SpotifyEQPro_CFLAGS = -fobjc-arc -O2
SpotifyEQPro_FRAMEWORKS = Foundation UIKit AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

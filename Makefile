TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = SpotifyEQPro
SpotifyEQPro_FILES = Tweak.m
SpotifyEQPro_CFLAGS = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter
SpotifyEQPro_FRAMEWORKS = Foundation UIKit AudioToolbox
SpotifyEQPro_INSTALL_PATH = @rpath

include $(THEOS_MAKE_PATH)/library.mk

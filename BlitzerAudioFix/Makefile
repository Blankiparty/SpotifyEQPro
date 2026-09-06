TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BlitzerAudioFix
BlitzerAudioFix_FILES = Tweak.m
BlitzerAudioFix_CFLAGS = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter
BlitzerAudioFix_FRAMEWORKS = Foundation AVFAudio
BlitzerAudioFix_INSTALL_PATH = @rpath

include $(THEOS_MAKE_PATH)/library.mk

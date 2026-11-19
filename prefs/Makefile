TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GhostModeHomePrefs
GhostModeHomePrefs_FILES = GMRootListController.m GMAppListController.m
GhostModeHomePrefs_FRAMEWORKS = UIKit
GhostModeHomePrefs_INSTALL_PATH = /Library/PreferenceBundles
GhostModeHomePrefs_CFLAGS = -fobjc-arc
GhostModeHomePrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

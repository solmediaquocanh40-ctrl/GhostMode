TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GhostModeHomePrefs
GhostModeHomePrefs_FILES = GMRootListController.m GMAppListController.m
GhostModeHomePrefs_FRAMEWORKS = UIKit
GhostModeHomePrefs_PRIVATE_FRAMEWORKS = Preferences
GhostModeHomePrefs_INSTALL_PATH = /Library/PreferenceBundles
GhostModeHomePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

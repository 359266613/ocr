include ../AxsOcrBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsOcrPrefs
AxsOcrPrefs_FILES = $(wildcard *.m)
AxsOcrPrefs_CFLAGS = -fobjc-arc -I../Sources
AxsOcrPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsOcrPrefs_PRIVATE_FRAMEWORKS = Preferences
AxsOcrPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

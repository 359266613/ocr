DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsOcrBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsOcr
AxsOcr_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsOcr_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsOcr_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsOcr_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AxsOcrPrefs AxsOcrHelper
include $(THEOS_MAKE_PATH)/aggregate.mk

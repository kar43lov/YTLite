TARGET := iphone:clang:16.5:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := WebClientSpoof
WebClientSpoof_FILES := WebClientSpoof.x
WebClientSpoof_CFLAGS := -fobjc-arc
WebClientSpoof_FRAMEWORKS := Foundation

include $(THEOS)/makefiles/tweak.mk

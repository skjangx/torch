# Build the CEF bridge as a static library.
#
# In stub mode (no CEF_ROOT), compiles stubs returning CEF_BRIDGE_ERR_NOT_INIT.
# When CEF_ROOT points to the CEF distribution, builds with real CEF calls.

CXX ?= clang++
AR  ?= ar
ARCHS ?= arm64

# CEF_ROOT: path to extracted CEF binary distribution
# CEF_WRAPPER_LIB: path to built libcef_dll_wrapper.a
CEF_ROOT ?=
CEF_WRAPPER_LIB ?=

CXXFLAGS := -std=c++20 -fPIC -Wall -Wextra -Wno-unused-parameter
CXXFLAGS += $(foreach arch,$(ARCHS),-arch $(arch))
CXXFLAGS += -mmacosx-version-min=13.0
CXXFLAGS += -fno-exceptions -fno-rtti -fno-threadsafe-statics

ifdef CEF_ROOT
  CXXFLAGS += -I$(CEF_ROOT) -DCEF_BRIDGE_HAS_CEF=1
endif

SRC := cef_bridge.cpp
OBJ := $(SRC:.cpp=.o)
LIB := libcef_bridge.a

.PHONY: all clean

all: $(LIB)

ifdef CEF_WRAPPER_LIB
# When we have the wrapper lib, merge both into one archive
$(LIB): $(OBJ)
	cp $(CEF_WRAPPER_LIB) $@
	$(AR) rs $@ $^
else
$(LIB): $(OBJ)
	$(AR) rcs $@ $^
endif

%.o: %.cpp cef_bridge.h
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJ) $(LIB)

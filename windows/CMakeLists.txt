# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
# Force rebuild trigger v1.5.4 (Message Window)
project(OmniChat LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "OmniChat")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  # WACK binary-hardening: enable Control Flow Guard (W-C05).
  # ASLR (/DYNAMICBASE + High Entropy VA) and DEP (/NXCOMPAT) are MSVC
  # defaults; /guard:cf must be requested explicitly for both compile and link.
  target_compile_options(${TARGET} PRIVATE /guard:cf)
  target_link_options(${TARGET} PRIVATE /guard:cf)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
# Install into the per-configuration runner directory (Debug/Profile/Release) so
# that `flutter run` (Debug) and `flutter build windows` (Release) both get a
# complete bundle next to the executable.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime OPTIONAL)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# === Bundle the VC++ runtime DLLs next to the executable (app-local CRT) ===
# flutter_windows.dll and the runner link the MSVC runtime dynamically (/MD),
# so machines without the VC++ 2015-2022 Redistributable cannot start the app
# ("VCRUNTIME140.dll / VCRUNTIME140_1.dll / MSVCP140.dll not found"). Per the
# official Flutter Windows distribution guidance, copy the redist CRT DLLs into
# the bundle: the Windows loader searches the application directory first, so
# the app becomes self-contained — the ZIP, the Inno Setup installer and the
# MSIX (packed from this same Release directory) all ship the runtime without
# needing a vc_redist step or a Microsoft.VCLibs.140.00 framework dependency.
set(VCRT_DLLS msvcp140.dll vcruntime140.dll vcruntime140_1.dll)

set(VCRT_DIR "")
# 1) From the compiler in use: <VS>/VC/Tools/MSVC/<ver>/bin/Hostx64/x64/cl.exe
#    -> redist lives at <VS>/VC/Redist/MSVC/<redistver>/x64/Microsoft.VC*.CRT
get_filename_component(_VCRT_MSVC_TOOLS "${CMAKE_CXX_COMPILER}" DIRECTORY)
get_filename_component(_VCRT_MSVC_TOOLS "${_VCRT_MSVC_TOOLS}/../../.." ABSOLUTE)
file(GLOB _VCRT_CANDIDATES
  "${_VCRT_MSVC_TOOLS}/../../../Redist/MSVC/*/x64/Microsoft.VC*.CRT")
# 2) Fallback: any installed Visual Studio (Build Tools included)
file(GLOB _VCRT_FALLBACK
  "C:/Program Files (x86)/Microsoft Visual Studio/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT"
  "C:/Program Files/Microsoft Visual Studio/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT")
list(APPEND _VCRT_CANDIDATES ${_VCRT_FALLBACK})
# Glob results are ascending; keep the last usable match (newest redist).
foreach(_cand IN LISTS _VCRT_CANDIDATES)
  if(EXISTS "${_cand}/msvcp140.dll")
    set(VCRT_DIR "${_cand}")
  endif()
endforeach()

if(VCRT_DIR)
  foreach(_dll IN LISTS VCRT_DLLS)
    if(EXISTS "${VCRT_DIR}/${_dll}")
      install(FILES "${VCRT_DIR}/${_dll}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
        CONFIGURATIONS Profile;Release
        COMPONENT Runtime)
    else()
      message(WARNING "VC++ runtime: ${_dll} not found in ${VCRT_DIR}")
    endif()
  endforeach()
  message(STATUS "Bundling VC++ runtime DLLs from: ${VCRT_DIR}")
else()
  message(WARNING
    "VC++ runtime DLLs not found - the built app will require the "
    "VC++ 2015-2022 Redistributable on end-user machines. Install the "
    "C++ workload / Build Tools with the MSVC component and rebuild.")
endif()

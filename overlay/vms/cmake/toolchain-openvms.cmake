# CMake toolchain file: configure MariaDB on a Linux host *for* OpenVMS x86-64.
#
# CMake does not run on VMS, so tools/host_configure.sh runs it here with this
# file.  CMAKE_SYSTEM_NAME=OpenVMS makes the configure a cross-configure:
#  - MariaDB loads cmake/os/OpenVMS.cmake, which pre-caches every platform
#    check from cmake/os/OpenVMSCache.cmake (answers replayed with clang on a
#    VMS node by tools/replay.sh), as cmake/os/WindowsCache.cmake does for MSVC;
#  - find_* never sees the host's libraries and headers;
#  - try_run() results must come from the cache, never from the host.
# The host compiler only stands in for clang so that CMake can generate the
# build description; nothing it compiles is used.  See docs/DECISIONS.md D1, D8.
set(CMAKE_SYSTEM_NAME OpenVMS)
set(CMAKE_SYSTEM_VERSION 9.2)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER gcc)
set(CMAKE_CXX_COMPILER g++)

# CMake's own Platform/OpenVMS.cmake (UNIX=1, .exe suffix) is used as is.

# Nothing from the host.  VMS_SYSROOT (set by tools/host_configure.sh) holds
# copies of the VMS headers CMake must see, e.g. VSI SSL3's OpenSSL headers.
if(NOT VMS_SYSROOT)
  set(VMS_SYSROOT "${CMAKE_CURRENT_LIST_DIR}/no-sysroot")
endif()
set(CMAKE_FIND_ROOT_PATH "${VMS_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

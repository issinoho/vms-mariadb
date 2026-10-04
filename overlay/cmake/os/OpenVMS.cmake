# OpenVMS (x86-64, VSI C++/clang) settings.  Loaded by the top-level
# CMakeLists.txt for CMAKE_SYSTEM_NAME OpenVMS, which only a host-side
# cross-configure uses (vms/cmake/toolchain-openvms.cmake).

# Shorthand for the VMS conditions in our patches to MariaDB's CMake files.
SET(VMS 1)

# Platform checks cannot run on the host: take every answer from the cache
# produced by replaying the checks on a VMS node.
# VMS_NO_ANSWERS=ON (tools/replay.sh with REPLAY_ALL=1) runs every check on the
# host instead, so that all of them can be replayed again.
IF(NOT VMS_NO_ANSWERS)
  INCLUDE(${CMAKE_CURRENT_LIST_DIR}/OpenVMSCache.cmake OPTIONAL)
ENDIF()

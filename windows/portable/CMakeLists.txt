cmake_minimum_required(VERSION 3.15)
project(near_transfer_portable LANGUAGES CXX RC)

add_executable(near_transfer_portable WIN32 launcher.cpp
  "${PACKAGE_RESOURCES}/package.rc")
set_target_properties(near_transfer_portable PROPERTIES
  OUTPUT_NAME "NearTransfer-Windows-x64"
  MSVC_RUNTIME_LIBRARY "MultiThreaded"
)
target_compile_features(near_transfer_portable PRIVATE cxx_std_17)
target_compile_definitions(near_transfer_portable PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(near_transfer_portable PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX>:/utf-8;/W4;/WX>"
)
target_include_directories(near_transfer_portable PRIVATE "${PACKAGE_RESOURCES}")
target_link_libraries(near_transfer_portable PRIVATE ole32 shell32 uuid)

cmake_minimum_required(VERSION 3.14)
project(asterlink_keepalive_tests LANGUAGES CXX)
enable_testing()
add_executable(download_power_request_test
  download_power_request_test.cpp
  ../download_power_request.cpp
)
target_compile_features(download_power_request_test PRIVATE cxx_std_17)
target_compile_definitions(download_power_request_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(download_power_request_test PRIVATE /W4 /WX /utf-8)
add_test(NAME download_power_request COMMAND download_power_request_test)

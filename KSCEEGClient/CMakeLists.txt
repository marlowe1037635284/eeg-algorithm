cmake_minimum_required(VERSION 3.16)

project(KSCEEGClient VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(QT_QML_GENERATE_QMLLS_INI ON)

find_package(Qt6 REQUIRED COMPONENTS Quick)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(appKSCEEGClient
    main.cpp
)

qt_add_qml_module(appKSCEEGClient
    URI KSCEEGClient
    QML_FILES
        Main.qml
    RESOURCES
        assets/login-background.jpg
        assets/asset-03.svg
        assets/asset-09.svg
        assets/asset-10.svg
)

set_target_properties(appKSCEEGClient PROPERTIES
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

target_link_libraries(appKSCEEGClient
    PRIVATE Qt6::Quick
)

install(TARGETS appKSCEEGClient
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

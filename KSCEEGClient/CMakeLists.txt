cmake_minimum_required(VERSION 3.16)

project(KSCEEGClient VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (MSVC)
    # qmlcachegen 会把所有 QML 的生成代码合并成一个巨大的翻译单元，
    # QML 文件一多（本项目 20+ 个）就会报 C1060「编译器的堆空间不足」。
    # /Zm 用来提高编译器的堆上限，避免这个坑。
    add_compile_options(/Zm2000)
endif()
set(QT_QML_GENERATE_QMLLS_INI ON)

find_package(Qt6 REQUIRED COMPONENTS Quick)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(appKSCEEGClient
    main.cpp
)

# Design.qml 是设计变量单例（画板尺寸、色板、字体名），需要在 QML 引擎里注册成 singleton，
# 否则同模块的页面 import 不到它。
set_source_files_properties(Design.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(appKSCEEGClient
    URI KSCEEGClient
    QML_FILES
        AppShell.qml
        Design.qml
        DesignCanvas.qml
        EditPatientDialog.qml
        ElectrodePanel.qml
        EventPanel.qml
        HistoryPage.qml
        LoginPage.qml
        Main.qml
        NewPatientDialog.qml
        NewTagDialog.qml
        PanelDivider.qml
        PatientManagementPage.qml
        PrecheckDialog.qml
        RecordPreviewDialog.qml
        SelectPatientDialog.qml
        SpectrumPanel.qml
        SystemSettingsPage.qml
        TopographyPanel.qml
        UserManagementPage.qml
        WaveformPanel.qml
        WorkbenchPage.qml
    RESOURCES
        assets/login-background.jpg
        assets/asset-03.svg
        assets/asset-09.svg
        assets/asset-10.svg
        assets/icons/nav-monitor.svg
        assets/icons/nav-monitor-active.svg
        assets/icons/nav-patient.svg
        assets/icons/nav-patient-active.svg
        assets/icons/nav-history.svg
        assets/icons/nav-history-active.svg
        assets/icons/nav-user.svg
        assets/icons/nav-user-active.svg
        assets/icons/nav-setting.svg
        assets/icons/nav-setting-active.svg
        assets/icons/icon-play.svg
        assets/icons/icon-camera.svg
        assets/icons/icon-trash.svg
        assets/icons/icon-scan.svg
        assets/icons/icon-freeze.svg
        assets/icons/icon-close.svg
        assets/icons/icon-check-bold.svg
        assets/icons/icon-arrow-down.svg
        assets/icons/icon-check.svg
        assets/icons/head-panel.svg
        assets/icons/head-outline.svg
        assets/icons/topo-circle.svg
        assets/icons/peak-badge.svg
        assets/icons/slider-thumb.svg
)

# 字体文件又大（4 个字重共 26MB），塞进 Qt 资源会让 rcc 生成的 .cpp 膨胀到 130MB 以上，
# MSVC 直接报 C1060「编译器的堆空间不足」。改成编译后拷到可执行文件旁边，运行时从磁盘加载。
add_custom_command(TARGET appKSCEEGClient POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts
            $<TARGET_FILE_DIR:appKSCEEGClient>/assets/fonts
    COMMENT "拷贝设计字体到可执行文件目录")

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

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

find_package(Qt6 REQUIRED COMPONENTS Quick Sql)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(appKSCEEGClient
    src/main.cpp
    # 账号库用 Qt Sql 直接读写一个真正的 SQLite 文件（不用 QML 的 LocalStorage）
    src/authdatabase.cpp
    src/authdatabase.h
)

# Design.qml 是设计变量单例（画板尺寸、色板、字体名），需要在 QML 引擎里注册成 singleton，
# 否则同模块的页面 import 不到它。
set_source_files_properties(qml/Design.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(appKSCEEGClient
    URI KSCEEGClient
    QML_FILES
        qml/Design.qml
        qml/DesignCanvas.qml
        qml/Main.qml
        qml/components/AppNavRail.qml
        qml/components/AppShell.qml
        qml/components/DialogFrame.qml
        qml/components/PanelDivider.qml
        qml/components/SoftBlob.qml
        qml/components/TableRowButton.qml
        qml/dialogs/EditPatientDialog.qml
        qml/dialogs/NewPatientDialog.qml
        qml/dialogs/NewTagDialog.qml
        qml/dialogs/PrecheckDialog.qml
        qml/dialogs/RecordPreviewDialog.qml
        qml/dialogs/SelectPatientDialog.qml
        qml/pages/HistoryPage.qml
        qml/pages/LoginPage.qml
        qml/pages/PatientManagementPage.qml
        qml/pages/SystemSettingsPage.qml
        qml/pages/UserManagementPage.qml
        qml/pages/WorkbenchPage.qml
        qml/panels/ElectrodePanel.qml
        qml/panels/EventPanel.qml
        qml/panels/SpectrumPanel.qml
        qml/panels/TopographyPanel.qml
        qml/panels/WaveformPanel.qml
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

# C++ 源码在 src/ 下，QML 类型注册生成的头文件里是 #include "authdatabase.h"，
# 得把 src 加进包含路径
target_include_directories(appKSCEEGClient
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# 把源码目录告诉程序：账号库文件放在代码目录里，清理 build 目录不会丢
target_compile_definitions(appKSCEEGClient
    PRIVATE KSCEEG_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
)

target_link_libraries(appKSCEEGClient
    PRIVATE Qt6::Quick
    PRIVATE Qt6::Sql
)

install(TARGETS appKSCEEGClient
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

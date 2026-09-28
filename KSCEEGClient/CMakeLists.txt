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

# SerialPort 用于采集页：串口收发全在 C++ 侧（SerialCollector）
find_package(Qt6 REQUIRED COMPONENTS Quick Sql SerialPort)

qt_standard_project_setup(REQUIRES 6.5)

# ==================== 嵌入的 Python 环境 ====================
# 链接期只能指向**基础安装**：Windows 的 venv 里既没有 libs/ 也没有 python3xx.dll，
# pybind11 的 Development.Embed 组件找不到它，这一点绕不开。
# 但运行期整个是 venv：pythonengine.cpp 会把 PyConfig.executable 指向 venv 的
# python.exe，由 CPython 的 site.py 自己认 pyvenv.cfg，于是 sys.prefix 就是 venv，
# 基础安装与用户级的 site-packages 都不可见。
set(Python_ROOT_DIR "C:/Program Files/Python311" CACHE PATH "Python 3.11 基础安装目录")
set(Python_FIND_VIRTUALENV STANDARD)

# 下面三个都是外部依赖路径，一律走「CACHE 变量 -> 编译期宏 -> 运行时环境变量」的
# 三级覆盖，不在代码里写死，换机器/部署时不必重编译
set(PYTHON_VENV_DIR "D:/myproject/eeg-algorithm/PythonScript/venv" CACHE PATH "Python 项目使用的 venv 目录")
# 算法包是 src 布局（源码在 <PythonScript>/src/eeg_algorithm），而 venv 里并没有装
# eeg_algorithm，所以要把 src 这一层加进 sys.path —— 不能只加项目根目录
set(EEG_ALGO_SRC_DIR "D:/myproject/eeg-algorithm/PythonScript/src" CACHE PATH "eeg_algorithm 源码目录")
set(EEG_BRIDGE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/python" CACHE PATH "宿主侧适配层 eeg_bridge.py 所在目录")

# ==================== pybind11（源码方式引入） ====================
set(PYBIND11_SOURCE_DIR "D:/work/learn/pybind11/pybind11-3.1.0" CACHE PATH "pybind11 源码目录")
set(PYBIND11_FINDPYTHON ON)   # 让 pybind11 自己去 find_package(Python ... Development.Embed)
add_subdirectory("${PYBIND11_SOURCE_DIR}" pybind11 EXCLUDE_FROM_ALL)

# 默认构建为窗口程序；打开此项则构建为控制台程序，便于直接看到 Python 侧的输出，
# 也是 --selfcheck 能看见结果的前提（窗口程序没有控制台，qInfo 会丢）
option(KSCEEG_CONSOLE "构建为控制台程序以便查看 Python 日志与自检输出" OFF)

qt_add_executable(appKSCEEGClient
    src/main.cpp
    # 账号 / 偏好 / 患者都用 Qt Sql 直接读写一个真正的 SQLite 文件
    # （不用 QML 的 LocalStorage，它把文件藏在 AppData 哈希目录里）
    src/appdatabase.cpp
    src/appdatabase.h
    # 嵌入式 Python 解释器门面（算法线程在后续步骤加进来）
    src/pythonengine.h
    src/pythonengine.cpp
    src/pythontypes.h
    # 采集与算法共用的数据结构与电极表
    src/eegtypes.h
    src/eegmontage.h
    # 串口采集链路
    src/serialprotocol.h
    src/rawringbuffer.h
    src/rawringbuffer.cpp
    src/serialcollector.h
    src/serialcollector.cpp
    # 算法线程
    src/pythonworker.h
    src/pythonworker.cpp
    # QML 门面与图像 provider
    src/acquisitionbridge.h
    src/acquisitionbridge.cpp
    src/bridgeimageproviders.h
    src/bridgeimageproviders.cpp
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
        qml/components/ChoiceField.qml
        qml/components/DialogFrame.qml
        qml/components/PanelDivider.qml
        qml/components/SoftBlob.qml
        qml/components/TableRowButton.qml
        qml/dialogs/ConfirmDialog.qml
        qml/dialogs/EditPatientDialog.qml
        qml/dialogs/FilterDialog.qml
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
    WIN32_EXECUTABLE $<NOT:$<BOOL:${KSCEEG_CONSOLE}>>
)

# C++ 源码在 src/ 下，QML 类型注册生成的头文件里是 #include "appdatabase.h"，
# 得把 src 加进包含路径
target_include_directories(appKSCEEGClient
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# 把源码目录告诉程序：账号库文件放在代码目录里，清理 build 目录不会丢
target_compile_definitions(appKSCEEGClient
    PRIVATE KSCEEG_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    # Python 环境的三个路径：同样走「编译期宏 -> 运行时环境变量」的两级覆盖
    PRIVATE PYTHON_ROOT_DIR="${Python_ROOT_DIR}"
    PRIVATE PYTHON_VENV_DIR="${PYTHON_VENV_DIR}"
    PRIVATE EEG_ALGO_SRC_DIR="${EEG_ALGO_SRC_DIR}"
    PRIVATE EEG_BRIDGE_DIR="${EEG_BRIDGE_DIR}"
)

target_link_libraries(appKSCEEGClient
    PRIVATE Qt6::Quick
    PRIVATE Qt6::Sql
    PRIVATE Qt6::SerialPort
    PRIVATE pybind11::embed
)

# 嵌入 Python 需要 python311.dll 在 exe 同目录（或 PATH 上），否则启动即 0xC0000135。
# 注意取自**基础安装**，不是 venv —— venv 里没有这个 dll
add_custom_command(TARGET appKSCEEGClient POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${Python_ROOT_DIR}/python311.dll"
            "$<TARGET_FILE_DIR:appKSCEEGClient>"
    COMMENT "复制 python311.dll 到输出目录"
)

install(TARGETS appKSCEEGClient
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

cmake_minimum_required(VERSION 3.16)

project(KSCEEGClient VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (MSVC)
    # qmlcachegen 会把所有 QML 的生成代码合并成一个巨大的翻译单元，
    # QML 文件一多（本项目 20+ 个）就会报 C1060「编译器的堆空间不足」。
    # /Zm 用来提高编译器的堆上限，避免这个坑。
    add_compile_options(/Zm2000)
    # 源码一律按 UTF-8 读、字符串字面量一律按 UTF-8 写。
    #
    # **不能省**：MSVC 默认按系统代码页（中文 Windows 上是 GBK）解释源文件。
    # 中文正好能「GBK 解一次、GBK 编回去」地原样绕一圈，所以中文一直看着没问题；
    # 希腊字母（频段的 δ θ α β γ）编码成 UTF-8 是两字节，被当成 GBK 就会落到
    # 别的字符上 —— 界面上出现的不是 δ，而是一个没人认识的符号，且不报任何错
    add_compile_options(/utf-8)
endif()
set(QT_QML_GENERATE_QMLLS_INI ON)

# SerialPort 用于采集页：串口收发全在 C++ 侧（SerialCollector）
# Concurrent 用于后处理页：一轮分析要算几百毫秒（滤波 + Welch + 相关性），
# 放在 GUI 线程上就是「拖一下滑块界面卡住」，改成 QtConcurrent 丢到线程池
# Network 用于授权校验：QNetworkInterface 取本机网卡 MAC，与授权文件里的绑定值比对
find_package(Qt6 REQUIRED COMPONENTS Quick Sql SerialPort Concurrent Network)

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

# ==================== 授权校验的外部依赖 ====================
# OpenSSL 用于 license.lic 的 RSA 验签（见 src/common/licensemanager.cpp），
# nlohmann/json 用于还原待验签串 —— 必须与签发侧同款序列化，否则签名对不上。
# 两者都在统一的外部依赖目录下，同样走 CACHE 变量覆盖：
#   OpenSSL 是「编译期链接 + 运行期要 dll」的形态，libcrypto-3-x64.dll 由文末的
#   POST_BUILD 拷到 exe 旁边；nlohmann 是纯头文件，只需加包含目录、无需部署。
set(KSCEEG_DEPENDLIB_DIR "D:/QML/dependlib" CACHE PATH "外部依赖根目录（OpenSSL / nlohmann-json）")
set(OPENSSL_ROOT_DIR "${KSCEEG_DEPENDLIB_DIR}/openssl" CACHE PATH "OpenSSL 安装目录")
find_package(OpenSSL REQUIRED)
set(NLOHMANN_JSON_INCLUDE_DIR "${KSCEEG_DEPENDLIB_DIR}/json-3.12.0/include" CACHE PATH "nlohmann/json 头文件目录")

# 默认构建为窗口程序；打开此项则构建为控制台程序，便于直接看到 Python 侧的输出，
# 也是 --selfcheck 能看见结果的前提（窗口程序没有控制台，qInfo 会丢）
option(KSCEEG_CONSOLE "构建为控制台程序以便查看 Python 日志与自检输出" OFF)

# ==================== 源码模块划分 ====================
# src/ 按职责分成 6 个模块；main.cpp 留在根上，只负责把各门面组装起来，不属于任何单一模块。
# 依赖方向尽量自下而上（→ 表示「依赖」），便于顺着方向阅读：
#
#   common/      跨模块共用的地基：跨线程数据结构、电极蒙太奇、.eegbin 格式、地形图配色
#   storage/     本地 SQLite（账号 / 偏好 / 患者 / 标签 / 采集记录），与 common 同为底层
#   acquisition/ 串口采集链路：协议、原始环形缓冲、采集线程                 → common
#   algorithm/   嵌入式 Python 门面、算法线程、离线算法调用层               → common acquisition
#   bridge/      QML 门面(AcquisitionBridge) 与波形/地形图图像 provider     → common acquisition algorithm
#   analysis/    历史回放、后处理页、A4 报告导出                            → common algorithm
#
# 注意 acquisition 与 algorithm 之间是双向引用：algorithm 需要 acquisition 的
# ChunkSink 抽象接口，而 acquisition 的 .cpp 里残留了一个未使用的 algorithm 头 ——
# 后者清掉之后，整棵树就只剩「自下而上」的单向依赖。
qt_add_executable(appKSCEEGClient
    src/main.cpp
    # common/：各模块共用的数据结构、电极表、文件格式与配色表
    src/common/eegtypes.h
    src/common/eegmontage.h
    src/common/eegbinformat.h
    src/common/topographypalette.h
    # 无人值守自动退出：读 client-config.json 的阈值，应用级空闲超时后退出程序
    src/common/unattendedguard.h
    src/common/unattendedguard.cpp
    # 审计日志：登录/退出、账号增改、采集与后处理导出等事件的落盘记录
    src/common/auditlog.h
    src/common/auditlog.cpp
    # 授权校验：每次启动读取 exe 同级的 license.lic（OpenSSL 验证签名 + MAC 绑定 + 有效期）
    src/common/licensemanager.h
    src/common/licensemanager.cpp
    # storage/：账号 / 偏好 / 患者都用 Qt Sql 直接读写一个真正的 SQLite 文件
    # （不用 QML 的 LocalStorage，它把文件藏在 AppData 哈希目录里）
    # 目录名用 storage 而不是 data —— 仓库根的 .gitignore 里有一条 data/，
    # 叫 data 会让这层源码被 git 忽略
    src/storage/appdatabase.cpp
    src/storage/appdatabase.h
    # acquisition/：串口采集链路
    src/acquisition/serialprotocol.h
    src/acquisition/rawringbuffer.h
    src/acquisition/rawringbuffer.cpp
    src/acquisition/serialcollector.h
    src/acquisition/serialcollector.cpp
    # algorithm/：嵌入式 Python 解释器门面与算法线程
    src/algorithm/pythonengine.h
    src/algorithm/pythonengine.cpp
    src/algorithm/pythontypes.h
    src/algorithm/pythonworker.h
    src/algorithm/pythonworker.cpp
    # 后处理算法统一走 Python 离线接口的调用层（pybind11 只在这些翻译单元里出现）
    src/algorithm/offlinealgorithm.h
    src/algorithm/offlinealgorithm.cpp
    # bridge/：QML 门面与图像 provider
    src/bridge/acquisitionbridge.h
    src/bridge/acquisitionbridge.cpp
    src/bridge/bridgeimageproviders.h
    src/bridge/bridgeimageproviders.cpp
    # analysis/：历史记录回放、「数据分析与后处理」页、A4 报告导出
    src/analysis/recordingpreview.h
    src/analysis/recordingpreview.cpp
    src/analysis/postprocess.h
    src/analysis/postprocess.cpp
    src/analysis/recordreport.h
    src/analysis/recordreport.cpp
)

# Design.qml 是设计变量单例（画板尺寸、色板、字体名），需要在 QML 引擎里注册成 singleton，
# 否则同模块的页面 import 不到它。
set_source_files_properties(qml/Design.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
# Privacy.qml 是脱敏开关单例：患者姓名 / 病历号要在多个页面、多个弹窗里统一打码，
# 同 Design.qml 一样注册成 singleton
set_source_files_properties(qml/Privacy.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(appKSCEEGClient
    URI KSCEEGClient
    QML_FILES
        qml/Design.qml
        qml/Privacy.qml
        qml/DesignCanvas.qml
        qml/Main.qml
        qml/components/AppNavRail.qml
        qml/components/AppShell.qml
        qml/components/ChoiceField.qml
        qml/components/DialogFrame.qml
        qml/components/PanelDivider.qml
        qml/components/Pager.qml
        qml/components/SearchField.qml
        qml/components/SoftBlob.qml
        qml/components/TableRowButton.qml
        qml/components/Toast.qml
        qml/components/UserMenu.qml
        qml/dialogs/ChangePasswordDialog.qml
        qml/dialogs/ConfirmDialog.qml
        qml/dialogs/DeviceInfoDialog.qml
        qml/dialogs/EditPatientDialog.qml
        qml/dialogs/FilterDialog.qml
        qml/dialogs/LicenseAlertDialog.qml
        qml/dialogs/NewPatientDialog.qml
        qml/dialogs/NewTagDialog.qml
        qml/dialogs/PrecheckDialog.qml
        qml/dialogs/RecordPreviewDialog.qml
        qml/dialogs/ReportDialog.qml
        qml/dialogs/ResetPasswordDialog.qml
        qml/dialogs/SelectPatientDialog.qml
        qml/dialogs/UserDialog.qml
        qml/pages/AnalysisPage.qml
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
        qml/analysis/AnalysisControls.qml
        qml/analysis/WaveTab.qml
        qml/analysis/SpectrumTab.qml
        qml/analysis/ChannelTab.qml
        qml/analysis/StatsTab.qml
        qml/analysis/TopographyTab.qml
        qml/analysis/ReportTab.qml
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
        assets/icons/icon-check-login.svg
        assets/icons/icon-lock.svg
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

# 源码按模块分子目录存放。源码里用「模块/文件.h」形式互相包含，所以 src 必须在包含路径上；
# 而 QML 类型注册（appdatabase.h / recordreport.h）生成的代码里用的是 #include "appdatabase.h"
# 这种不带目录的形式，所以各模块子目录也要加进来
target_include_directories(appKSCEEGClient
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_SOURCE_DIR}/src/common
        ${CMAKE_CURRENT_SOURCE_DIR}/src/storage
        ${CMAKE_CURRENT_SOURCE_DIR}/src/acquisition
        ${CMAKE_CURRENT_SOURCE_DIR}/src/algorithm
        ${CMAKE_CURRENT_SOURCE_DIR}/src/bridge
        ${CMAKE_CURRENT_SOURCE_DIR}/src/analysis
        # 授权校验用的 nlohmann/json（纯头文件）。OpenSSL 的头文件由
        # OpenSSL::Crypto 这个 imported target 自己带出来，不必在这里再列
        ${NLOHMANN_JSON_INCLUDE_DIR}
)

# 把源码目录告诉程序：账号库文件放在代码目录里，清理 build 目录不会丢
target_compile_definitions(appKSCEEGClient
    PRIVATE KSCEEG_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    # Python 环境的三个路径：同样走「编译期宏 -> 运行时环境变量」的两级覆盖
    PRIVATE PYTHON_ROOT_DIR="${Python_ROOT_DIR}"
    PRIVATE PYTHON_VENV_DIR="${PYTHON_VENV_DIR}"
    PRIVATE EEG_ALGO_SRC_DIR="${EEG_ALGO_SRC_DIR}"
    PRIVATE EEG_BRIDGE_DIR="${EEG_BRIDGE_DIR}"
    # 构建配置给 QML 用：登录页的「记住密码」只在 Debug 构建里显示，打包发布（Release）
    # 不显示。生成器表达式按配置判定，单配置生成器（NMake Makefiles）依据 CMAKE_BUILD_TYPE
    PRIVATE $<$<CONFIG:Debug>:KSCEEG_DEBUG_BUILD=1>
)

target_link_libraries(appKSCEEGClient
    PRIVATE Qt6::Quick
    PRIVATE Qt6::Sql
    PRIVATE Qt6::SerialPort
    PRIVATE Qt6::Concurrent
    PRIVATE Qt6::Network
    PRIVATE OpenSSL::Crypto
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

# 授权验签链接的是 OpenSSL 的 libcrypto，运行期需要同版本的 dll 在 exe 旁边，
# 否则启动即 0xC0000135（找不到 libcrypto-3-x64.dll）
add_custom_command(TARGET appKSCEEGClient POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${OPENSSL_ROOT_DIR}/bin/libcrypto-3-x64.dll"
            "$<TARGET_FILE_DIR:appKSCEEGClient>"
    COMMENT "复制 libcrypto-3-x64.dll 到输出目录"
)

install(TARGETS appKSCEEGClient
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

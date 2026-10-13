pragma Singleton

import QtQuick

// 脱敏开关的全局状态：系统设置页写，所有展示患者姓名 / 病历号的地方读。
//
// 做成单例是因为「是否脱敏」影响的是一堆散落在各页面、各弹窗里的文本 ——
// 患者管理、历史记录、选患者弹窗、工作台、记录预览都得跟着一起变。
// 逐层传参既啰嗦又容易漏，漏一处就是一次隐私泄漏；用单例让所有展示点
// 共享同一份状态，改一处即全局生效。
//
// 真正落地有两条路：
//   1. 界面展示 —— 各页面的 Text 用 masked() 包一层；
//   2. 导出 —— AppDatabase.exportSession()（原始数据文件名 + 摘要 CSV）与
//      Main.exportRecordPdf()（PDF 报告）在写文件前把患者姓名 / 病历号换掉。
//      导出物一旦离开程序就不受界面开关约束，必须在写出的那一刻就脱敏。
//
// 只做展示层/导出层的替换，**不动数据源**：patients() 的 no / name 还被界面
// 当作过滤键、动作参数、编辑框初值用（findPatientRow、行内编辑按钮等），
// 在数据层打码会把「***」写回库，等于毁数据。
QtObject {
    id: privacy

    // 是否开启脱敏。由 Main.qml 在启动与登录后从 app_settings.data_mask 同步；
    // 系统设置页保存时会立即更新它，无需重启
    property bool enabled: false

    // 展示用：开启且文本非空时返回 "***"，否则原样返回。
    // 空串不替换 —— 把空模板也变成 *** 反而像是界面坏了
    function masked(text) {
        if (!enabled)
            return text
        if (text === undefined || text === null || text.length === 0)
            return text
        return "***"
    }
}

"""离线处理 API 完整使用示例（模拟数据）。

演示离线会话的完整生命周期：
创建会话 → 预处理 → 查询频谱/地形图/统计 → 质检检测（含子模块单独/组合与参数调整） → 查看状态 → 关闭。
"""

import numpy as np

from eeg_algorithm.api import create_api
from eeg_algorithm.types import (
    AbsoluteTimeRange,
    ArtifactDetectionConfig,
    ChannelLayout,
    ElectrodePosition,
    HighPassConfig,
    LowPassConfig,
    NotchConfig,
    OfflineAsrConfig,
    OfflineQualityQuery,
    OfflineReferenceConfig,
    OfflineSpectrumQuery,
    OfflineStatisticsQuery,
    OfflineTopographyQuery,
    PreprocessConfig,
    QualityControlConfig,
    ReferenceMethod,
    ResampleConfig,
    SignalBlock,
)

SAMPLE_RATE = 250.0
CHANNELS = ("F3", "F4", "P3", "P4")
DURATION_S = 10.0
TOTAL_SAMPLES = int(SAMPLE_RATE * DURATION_S)


def build_layout() -> ChannelLayout:
    """构造含电极坐标的布局（离线地形图查询必需）。"""
    positions = (
        ElectrodePosition("F3", -0.5, 0.6, 0.6, "unit_sphere"),
        ElectrodePosition("F4", 0.5, 0.6, 0.6, "unit_sphere"),
        ElectrodePosition("P3", -0.5, -0.6, 0.6, "unit_sphere"),
        ElectrodePosition("P4", 0.5, -0.6, 0.6, "unit_sphere"),
    )
    return ChannelLayout(CHANNELS, SAMPLE_RATE, positions)


def simulate_signal() -> SignalBlock:
    """模拟 4 通道、10 秒的 EEG 信号（10Hz alpha 波 + 白噪声）。"""
    t = np.arange(TOTAL_SAMPLES) / SAMPLE_RATE
    values = np.zeros((len(CHANNELS), TOTAL_SAMPLES), dtype=np.float32)
    for i in range(len(CHANNELS)):
        values[i] = (
            20.0 * np.sin(2.0 * np.pi * 10.0 * t + i * 0.4)  # 10Hz alpha
            + 3.0 * np.random.default_rng(i).normal(size=TOTAL_SAMPLES)  # 噪声
        ).astype(np.float32)
    timestamps = np.rint(t * 1e9).astype(np.int64)
    return SignalBlock(0, timestamps, values)


def main() -> None:
    api = create_api()
    layout = build_layout()
    raw = simulate_signal()

    # 1. 创建离线会话（原始信号会被复制保存）
    session_id = api.create_offline_session(layout, raw)
    print(f"离线会话已创建: {session_id}")

    # 2. 运行预处理
    config = PreprocessConfig(
        preprocess_version=1,
        high_pass=HighPassConfig(True, 1.0),                                   # 高通 1Hz
        low_pass=LowPassConfig(True, 30.0),                                    # 低通 30Hz（组合为带通 1-30Hz）
        notch=NotchConfig(True),                                               # 陷波 48-52Hz
        reference=OfflineReferenceConfig(True, ReferenceMethod.COMMON_AVERAGE),  # 平均参考
        asr=OfflineAsrConfig(True),                                           # 关闭 ASR
        artifact=ArtifactDetectionConfig(True),                                # 开启伪迹检测
        resample=ResampleConfig(True, 250.0),                                 # 不降采样
        quality_control=QualityControlConfig(
            null_weak_enabled=False,           # 空值 + 弱信号检测
            amplitude_outlier_enabled=False,   # 幅度范围外值检测
            low_correlation_enabled=False,     # 低相关性导联检测
            repair_enabled=False,              # 开启线性插值修复
        ),
    )
    result = api.run_preprocessing(session_id, config)
    version = result.preprocess_version
    print(f"预处理样本数: {result.sample_count}")
    print(f"已应用步骤: {result.applied_steps}")

    # 2.1 查看伪迹检测报告（异常段列表 + 逐样本掩码）
    artifact_report = result.artifact_report
    if artifact_report is not None:
        print(f"伪迹异常段数量: {len(artifact_report.segments)}")
        print(f"伪迹掩码形状: {artifact_report.artifact_mask.shape}")

    # 2.2 查看质检报告（异常段列表 + 逐样本掩码）
    report = result.quality_report
    if report is not None:
        print(f"质检异常段数量: {len(report.segments)}  已修复: {report.repaired}")
        print(f"异常掩码形状: {report.artifact_mask.shape}")

    # 3. 查询离线频谱（F3 导联，2-4 秒区间，alpha 频段）
    selected = AbsoluteTimeRange(2_000_000_000, 4_000_000_000)
    spectrum = api.query_offline_spectrum(
        session_id,
        OfflineSpectrumQuery(
            request_id=1,
            preprocess_version=version,
            channel_name="F3",
            selected_range=selected,
            frequency_range_hz=(4.0, 20.0),
        ),
    )
    print(f"离线频谱频点数: {spectrum.frequencies_hz.size}")

    # 4. 查询离线地形图（一次返回全频段 + δ/θ/α/β/γ 共 6 张，64x64 网格）
    topo = api.query_offline_topography(
        session_id,
        OfflineTopographyQuery(
            request_id=2,
            preprocess_version=version,
            selected_range=selected,
        ),
    )
    print(f"离线地形图频段: {topo.band_names}")
    print(f"离线地形图网格: {topo.grid_values.shape} (6 张)")

    # 5. 查询离线多通道统计指标（与频谱/地形图同级别的统计页面）
    stats = api.query_offline_statistics(
        session_id,
        OfflineStatisticsQuery(
            request_id=3,
            preprocess_version=version,
            selected_range=selected,
        ),
    )
    print(f"统计通道: {stats.channel_names}")
    print(f"统计均值(μV): {np.round(stats.mean, 3)}")
    print(f"统计标准差(μV): {np.round(stats.std, 3)}")
    print(f"统计RMS(μV): {np.round(stats.rms, 3)}")
    print(f"统计峰峰值(μV): {np.round(stats.peak_to_peak, 3)}")
    print(f"统计最小值(μV): {np.round(stats.min_value, 3)}")
    print(f"统计最大值(μV): {np.round(stats.max_value, 3)}")
    print(f"统计零交叉率(次/秒): {np.round(stats.zero_crossing_rate, 3)}")
    print(f"统计偏度: {np.round(stats.skewness, 3)}")
    print(f"统计峰度: {np.round(stats.kurtosis, 3)}")
    print(f"统计优势频带: {stats.dominant_band}")
    print(f"通道相关性矩阵:\n{np.round(stats.correlation_matrix, 3)}")
    print(f"频带名称: {stats.band_names}")
    print(f"各通道频带能量(PSD积分):\n{np.round(stats.band_energies, 3)}")

    # 6. 查询离线质检（在预处理后选段数据上独立检测，只检测不修改数据）
    quality = api.query_offline_quality(
        session_id,
        OfflineQualityQuery(
            request_id=4,
            preprocess_version=version,
            selected_range=selected,
            quality_control=QualityControlConfig(),
        ),
    )
    print(f"质检异常段数量: {len(quality.segments)}  修复: {quality.repaired}")

    # 6.1 质检检测子模块可单独/组合调用，检测参数也可独立调整。
    # 三个开关：null_weak_enabled（空值+弱信号）、amplitude_outlier_enabled（幅度范围外值）、
    #          low_correlation_enabled（低相关性导联）。

    # 只测「幅度范围外值」，并把幅度占比阈值从默认 0.1 调大到 0.2
    qc_amplitude_only = QualityControlConfig(
        null_weak_enabled=False,
        low_correlation_enabled=False,
        amplitude_ratio=0.2,
    )
    amp_report = api.query_offline_quality(
        session_id,
        OfflineQualityQuery(
            request_id=5,
            preprocess_version=version,
            selected_range=selected,
            quality_control=qc_amplitude_only,
        ),
    )
    amp_types = {s.artifact_type for s in amp_report.segments}
    print(f"只测幅度外值(占比0.2): {len(amp_report.segments)} 段, 类型={amp_types}")

    # 只测「低相关性导联」，并把相关性阈值从默认 0.1 调大到 0.5
    qc_corr_only = QualityControlConfig(
        null_weak_enabled=False,
        amplitude_outlier_enabled=False,
        correlation_threshold=0.5,
    )
    corr_report = api.query_offline_quality(
        session_id,
        OfflineQualityQuery(
            request_id=6,
            preprocess_version=version,
            selected_range=selected,
            quality_control=qc_corr_only,
        ),
    )
    corr_types = {s.artifact_type for s in corr_report.segments}
    print(f"只测低相关性(阈值0.5): {len(corr_report.segments)} 段, 类型={corr_types}")

    # 测「空值/弱信号 + 幅度范围外值」两个模块（关掉低相关性）
    qc_two = QualityControlConfig(low_correlation_enabled=False)
    two_report = api.query_offline_quality(
        session_id,
        OfflineQualityQuery(
            request_id=7,
            preprocess_version=version,
            selected_range=selected,
            quality_control=qc_two,
        ),
    )
    two_types = {s.artifact_type for s in two_report.segments}
    print(f"测空值/弱信号+幅度外值: {len(two_report.segments)} 段, 类型={two_types}")

    # 7. 查看离线会话状态
    status = api.get_offline_status(session_id)
    print(f"离线状态: {status.state.value}")

    # 8. 关闭
    api.close()
    print("已关闭 API")


if __name__ == "__main__":
    main()

"""在线 push_block 接口的完整使用示例（使用模拟 EEG 数据）。

演示流程：
1. 构造带电极位置的通道布局与在线处理配置
2. 创建在线会话
3. 分块连续推送模拟信号（模拟实时流式采集）
4. 查询 alpha 频段频谱与地形图
5. 查看会话状态并关闭
"""

from __future__ import annotations

import numpy as np

from eeg_algorithm.api import create_api
from eeg_algorithm.types import (
    AsrConfig,
    BandPreset,
    ChannelLayout,
    ElectrodePosition,
    FrequencyBand,
    OnlineConfig,
    OnlineProcessingConfig,
    PhaseModelConfig,
    ReferenceConfig,
    SignalBlock,
    SpectrumQuery,
    ToggleFilterConfig,
    TopographyQuery,
)

SAMPLE_RATE_HZ = 250.0
CHANNEL_NAMES = ("F3", "F4", "P3", "P4")
BLOCK_SECONDS = 1.0  # 每块时长（秒）
TOTAL_SECONDS = 10.0  # 总推送时长（秒）
BLOCK_SAMPLES = int(SAMPLE_RATE_HZ * BLOCK_SECONDS)  # 每块样本数


def build_layout() -> ChannelLayout:
    """构造包含电极位置的 4 通道布局（地形图查询需要电极位置）。"""
    positions = (
        ElectrodePosition("F3", -0.6, 0.6, 0.5, "unit_sphere"),
        ElectrodePosition("F4", 0.6, 0.6, 0.5, "unit_sphere"),
        ElectrodePosition("P3", -0.6, -0.6, 0.5, "unit_sphere"),
        ElectrodePosition("P4", 0.6, -0.6, 0.5, "unit_sphere"),
    )
    return ChannelLayout(CHANNEL_NAMES, SAMPLE_RATE_HZ, positions)


def build_config(layout: ChannelLayout) -> OnlineConfig:
    """构造在线处理配置：关闭所有滤波与 ASR，便于观察原始模拟信号。"""
    disabled = ToggleFilterConfig(False)
    processing = OnlineProcessingConfig(1, disabled, disabled, disabled, False)
    return OnlineConfig(
        layout=layout,
        processing=processing,
        reference=ReferenceConfig(),
        asr=AsrConfig(),
        phase=PhaseModelConfig(False, "", ()),
        rolling_window_s=5.0,
    )


def simulate_block(first_sequence_id: int, start_time_s: float) -> SignalBlock:
    """生成一段模拟 EEG：10Hz alpha 主波 + 20Hz beta 谐波 + 白噪声。"""
    n = BLOCK_SAMPLES
    t = start_time_s + np.arange(n, dtype=np.float64) / SAMPLE_RATE_HZ
    rng = np.random.default_rng(seed=first_sequence_id)
    # 每个通道使用不同相位，使通道间有所区分
    values = np.vstack(
        [
            np.sin(2 * np.pi * 10 * t + phase)
            + 0.5 * np.sin(2 * np.pi * 20 * t + phase)
            + 0.1 * rng.standard_normal(n)
            for phase in (0.0, 0.3, 1.2, 1.6)
        ]
    ).astype(np.float32)
    timestamps_ns = np.rint(t * 1_000_000_000).astype(np.int64)
    return SignalBlock(
        first_sequence_id,
        np.ascontiguousarray(timestamps_ns),
        np.ascontiguousarray(values),
    )


def main() -> None:
    api = create_api()
    layout = build_layout()
    session_id = api.create_online_session(build_config(layout))
    print(f"在线会话已创建: session_id={session_id}")

    # 分块连续推送，模拟流式采集；块间序号必须连续，否则会触发断点异常
    next_sequence = 0
    for block_index in range(int(TOTAL_SECONDS / BLOCK_SECONDS)):
        block = simulate_block(next_sequence, block_index * BLOCK_SECONDS)
        result = api.push_block(session_id, block)
        next_sequence += BLOCK_SAMPLES
        processed = result.processed_signal
        shape = processed.values.shape if processed is not None else None
        print(
            f"[block {block_index}] seq {block.first_sequence_id}.."
            f"{result.last_sequence_id} 处理后形状={shape}"
        )

    # 查询 alpha 频段（8-13Hz）频谱
    alpha = FrequencyBand(BandPreset.ALPHA, 8.0, 13.0)
    spectrum = api.query_online_spectrum(
        session_id, SpectrumQuery(1, "F3", alpha, window_s=2.0)
    )
    print("频谱请求ID:", spectrum.request_id)
    print("频谱频点数量:", spectrum.frequencies_hz.size)
    if spectrum.psd.size:
        peak_index = int(np.argmax(spectrum.psd))
        print(f"alpha 频段峰值频率: {spectrum.frequencies_hz[peak_index]:.2f} Hz")

    # 查询 alpha 频段地形图
    topography = api.query_online_topography(
        session_id, TopographyQuery(2, alpha, window_s=2.0)
    )
    print("地形图请求ID:", topography.request_id)
    print("地形图网格形状:", topography.grid_values.shape)

    # 查看会话状态
    status = api.get_online_status(session_id)
    print("会话状态:", status.state)
    print("最后处理序号:", status.last_processed_sequence_id)
    print(f"平均处理耗时: {status.average_processing_time_us:.1f} us")

    api.close()
    print("已关闭 API")


if __name__ == "__main__":
    main()

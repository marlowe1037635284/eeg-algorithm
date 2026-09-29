"""离线处理示例：创建会话、预处理、查询频谱与地形图。

运行方式（在 ``algorithm`` 目录下）：

    $env:PYTHONPATH = "src"
    python examples/offline_processing_demo.py
"""

from __future__ import annotations

import numpy as np

from eeg_algorithm import api
from eeg_algorithm.types import (
    AbsoluteTimeRange,
    BandPassConfig,
    BandPreset,
    BaselineConfig,
    ChannelLayout,
    ElectrodePosition,
    FrequencyBand,
    NotchConfig,
    OfflineAsrConfig,
    OfflineReferenceConfig,
    OfflineSpectrumQuery,
    OfflineTopographyQuery,
    PreprocessConfig,
    ReferenceMethod,
    ResampleConfig,
    SignalBlock,
)


def _make_layout() -> ChannelLayout:
    names = ("Fz", "Cz", "Pz", "Oz")
    positions = (
        ElectrodePosition("Fz", 0.0, 0.7, 0.0, "mni"),
        ElectrodePosition("Cz", 0.0, 0.0, 0.0, "mni"),
        ElectrodePosition("Pz", 0.0, -0.7, 0.0, "mni"),
        ElectrodePosition("Oz", 0.3, -1.1, 0.0, "mni"),
    )
    return ChannelLayout(channel_names=names, sample_rate_hz=250.0, positions=positions)


def main() -> None:
    layout = _make_layout()
    fs = int(layout.sample_rate_hz)
    total = fs * 10  # 10 秒
    t = np.arange(total, dtype=np.float64) / fs
    rng = np.random.default_rng(0)
    values = np.zeros((len(layout.channel_names), total), dtype=np.float32)
    for i in range(len(layout.channel_names)):
        values[i] = (
            20.0 * np.sin(2 * np.pi * 10.0 * t)
            + 5.0 * rng.standard_normal(total)
        ).astype(np.float32)
    stamps = (np.arange(total, dtype=np.int64) * int(1e9 / fs))
    raw = SignalBlock(first_sequence_id=0, timestamps_ns=stamps, values=values)

    alg = api.create_api()
    sid = alg.create_offline_session(layout, raw)
    print(f"created offline session {sid}")

    config = PreprocessConfig(
        preprocess_version=1,
        band_pass=BandPassConfig(enabled=True, low_cut_hz=0.5, high_cut_hz=30.0),
        notch=NotchConfig(enabled=True),
        reference=OfflineReferenceConfig(enabled=True, method=ReferenceMethod.COMMON_AVERAGE),
        asr=OfflineAsrConfig(enabled=False),
        resample=ResampleConfig(enabled=True, target_rate_hz=125.0),
        baseline=BaselineConfig(enabled=False),
    )
    result = alg.run_preprocessing(sid, config)
    print(
        f"preprocessed: version {result.preprocess_version}, samples {result.sample_count}, "
        f"steps {list(result.applied_steps)}, fs {result.layout.sample_rate_hz}Hz"
    )

    selected = AbsoluteTimeRange(start_timestamp_ns=int(2e9), end_timestamp_ns=int(4e9))
    spec = alg.query_offline_spectrum(
        sid,
        OfflineSpectrumQuery(
            request_id=1,
            preprocess_version=1,
            channel_name="Cz",
            selected_range=selected,
            frequency_range_hz=(8.0, 13.0),
        ),
    )
    print(f"offline spectrum: {spec.frequencies_hz.shape[0]} freq points")

    topo = alg.query_offline_topography(
        sid,
        OfflineTopographyQuery(
            request_id=2,
            preprocess_version=1,
            selected_range=selected,
            frequency_band=FrequencyBand(BandPreset.ALPHA, 8.0, 13.0),
        ),
    )
    print(f"offline topography: grid {topo.grid_values.shape}")

    status = alg.get_offline_status(sid)
    print(f"offline status: {status.state.value}")

    alg.close_offline_session(sid)
    alg.close()
    print("offline demo finished")


if __name__ == "__main__":
    main()

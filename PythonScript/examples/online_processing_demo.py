"""在线处理示例：创建会话、推送数据块、查询地形图与频谱。

运行方式（在 ``algorithm`` 目录下）：

    $env:PYTHONPATH = "src"
    python examples/online_processing_demo.py
"""

from __future__ import annotations

import numpy as np

from eeg_algorithm import api
from eeg_algorithm.types import (
    BandPreset,
    ChannelLayout,
    ElectrodePosition,
    FrequencyBand,
    OnlineConfig,
    OnlineProcessingConfig,
    PhaseModelConfig,
    ReferenceConfig,
    ReferenceMethod,
    SignalBlock,
    SpectrumQuery,
    AsrConfig,
    ToggleFilterConfig,
    TopographyQuery,
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
    config = OnlineConfig(
        layout=layout,
        processing=OnlineProcessingConfig(
            config_version=1,
            high_pass=ToggleFilterConfig(enabled=True, low_hz=0.5),
            low_pass=ToggleFilterConfig(enabled=True, high_hz=30.0),
            notch=ToggleFilterConfig(enabled=True, low_hz=48.0, high_hz=52.0),
            asr_enabled=False,
        ),
        reference=ReferenceConfig(method=ReferenceMethod.COMMON_AVERAGE),
        asr=AsrConfig(),
        phase=PhaseModelConfig(enabled=False, model_path="", target_channels=()),
        rolling_window_s=4.0,
    )

    alg = api.create_api()
    sid = alg.create_online_session(config)
    print(f"created online session {sid}")

    fs = int(layout.sample_rate_hz)
    t = np.arange(fs * 2, dtype=np.float64)
    noise = np.random.default_rng(0).standard_normal((len(layout.channel_names), t.size)).astype(np.float32)
    noise *= 10.0
    stamps = (np.arange(t.size, dtype=np.int64) * int(1e9 / fs))

    for start in range(0, t.size, fs):
        end = min(start + fs, t.size)
        block = SignalBlock(
            first_sequence_id=start,
            timestamps_ns=stamps[start:end],
            values=noise[:, start:end],
        )
        result = alg.push_block(sid, block)
        if start == 0:
            print(
                f"first block: seq {result.first_sequence_id}..{result.last_sequence_id}, "
                f"flags {[f.value for f in result.quality_flags]}"
            )

    status = alg.get_online_status(sid)
    print(f"online status: {status.state.value}, buffer={status.rolling_buffer_duration_s:.2f}s")

    topo = alg.query_online_topography(
        sid,
        TopographyQuery(request_id=1, band=FrequencyBand(BandPreset.ALPHA, 8.0, 13.0), window_s=2.0),
    )
    print(f"topography: grid {topo.grid_values.shape}, electrodes {len(topo.electrode_names)}")

    spec = alg.query_online_spectrum(
        sid,
        SpectrumQuery(request_id=2, channel_name="Cz", band=FrequencyBand(BandPreset.ALPHA, 8.0, 13.0), window_s=2.0),
    )
    print(f"spectrum: {spec.frequencies_hz.shape[0]} freq points, psd range {float(spec.psd.min()):.3f}..{float(spec.psd.max()):.3f}")

    alg.close_online_session(sid)
    alg.close()
    print("online demo finished")


if __name__ == "__main__":
    main()

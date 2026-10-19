"""宿主侧适配层：把 ``eeg_algorithm`` 的嵌套 DTO 压成扁平的基础类型。

为什么需要这一层，而不是让 C++ 直接构造 dataclass：

1. ``OnlineConfig`` 有五层嵌套（layout → positions、processing → 三个
   ``ToggleFilterConfig``、reference、asr、phase）。C++ 侧每加一个字段就要跟着改
   ``py::arg`` 列表，而关键字拼错只有运行期才报 TypeError —— 且只在用户恰好启用
   那个开关时才暴露。压平之后，新增字段在 Python 侧给个默认值，C++ 一行都不用动。
2. 枚举（``ReferenceMethod`` / ``BandPreset`` / ``SessionState``）是 Python Enum，
   C++ 侧只该传字符串，成员校验集中在这里做。
3. 错误投影集中在一处：``describe_error()`` 把 ``AlgorithmError`` 翻成扁平 dict，
   C++ 从此不必知道 ``AlgorithmErrorInfo`` 的字段名。

本模块只 import 接口文档允许的 ``eeg_algorithm.api`` / ``.types`` / ``.errors``，
不碰 ``eeg_algorithm.internal``（见《EEG在线与离线算法模块接口文档》第 7 节）。
"""

from __future__ import annotations

from typing import Any, Iterable, Mapping, Sequence

from eeg_algorithm import api
from eeg_algorithm.errors import (
    INVALID_ARGUMENT,
    NOT_INITIALIZED,
    SESSION_NOT_FOUND,
    algorithm_error,
)
from eeg_algorithm.types import (
    AbsoluteTimeRange,
    ArtifactDetectionConfig,
    AsrConfig,
    BandPreset,
    ChannelLayout,
    ElectrodePosition,
    FrequencyBand,
    GapInfo,
    HighPassConfig,
    LoggingConfig,
    LogLevel,
    LowPassConfig,
    NotchConfig,
    OfflineAsrConfig,
    OfflineReferenceConfig,
    OfflineSpectrumQuery,
    OfflineStatisticsQuery,
    OfflineTopographyQuery,
    OnlineConfig,
    OnlineProcessingConfig,
    PhaseModelConfig,
    PreprocessConfig,
    QualityControlConfig,
    ReferenceConfig,
    ReferenceMethod,
    ResampleConfig,
    SignalBlock,
    SpectrumQuery,
    ToggleFilterConfig,
    TopographyQuery,
)

# 在线滤波参数的默认值。C++ 启动时通过 processing_defaults() 取一份，
# 之后它就自己持有这份 POD；两边不必各写一份默认值然后慢慢漂移。
DEFAULT_PROCESSING: dict[str, Any] = {
    "high_pass_enabled": True,
    "high_pass_low_hz": 0.5,
    "high_pass_order": 4,
    "low_pass_enabled": True,
    "low_pass_high_hz": 45.0,
    "low_pass_order": 4,
    "notch_enabled": True,
    "notch_low_hz": 48.0,
    "notch_high_hz": 52.0,
    "notch_order": 4,
    "asr_enabled": False,
}

# 滤波参数的键集合，建 dict 时用来做一次「键名对不对」的自检。
# 少了这道检查，C++ 侧写错一个键名只会表现为「那个开关点了没反应」。
PROCESSING_KEYS: tuple[str, ...] = tuple(DEFAULT_PROCESSING.keys())

_api: Any = None

# 受支持的接口主版本。次版本（1.2、1.3 …）之间 DTO 字段与语义保持向后兼容，
# 主版本一变则可能整体不兼容 —— 那时继续建会话只会在运行期以难懂的
# TypeError / AttributeError 暴露。策略只在这里定义一处，C++ 侧不再各自比对
# 版本号（见 :func:`ensure_api_compatible`）。
SUPPORTED_API_MAJOR = 1

# 会话 id → 采样率。仅用于在适配层做频率范围校验（见 _validate_processing）。
# 算法侧的校验在滤波系数设计那一步才发生，那时抛的是 scipy 的裸 ValueError，
# 经 describe_error 会退化成 INTERNAL_ERROR —— 错误码不可分类，界面只能把它
# 当成「非预期错误」处理。在这里先拦一道，就能给出规范的 INVALID_ARGUMENT
# 和一句人看得懂的话。
_session_sample_rate: dict[int, float] = {}


def configure_logging(directory: str, enabled: bool = True, min_level: str = "INFO") -> None:
    """配置异步日志。必须在任何一次 ``create_api()`` 之前调用。

    接口约定「没有配置日志时模块只安装 NullHandler，不自行创建目录」，所以目录由
    C++ 传进来 —— 这里不做任何路径推断，也不去创建它（创建交给日志系统自己）。
    """
    api.configure_logging(
        LoggingConfig(
            enabled=bool(enabled),
            directory=str(directory),
            min_level=LogLevel(str(min_level).upper()),
        )
    )


def api_version() -> str:
    """返回接口版本字符串，不做任何校验。"""
    return api.get_api_version()


def ensure_api_compatible() -> str:
    """校验接口主版本，通过则返回完整版本号，否则抛结构化错误。

    这是版本策略的**唯一**落点：C++ 不再自己比对版本号，避免「C++ 认 1.x、
    适配层认别的」这种两处逻辑漂移。算法包升级到不兼容主版本时，这里把
    「接口不可用」变成一个带错误码的 ``AlgorithmError``，C++ 侧统一按
    ``NOT_INITIALIZED`` 处理，而不是在运行期撞上 `AttributeError`。
    """
    version = api.get_api_version()
    major_text = str(version).split(".", 1)[0]
    try:
        major = int(major_text)
    except ValueError as exc:
        raise algorithm_error(
            NOT_INITIALIZED,
            f"无法解析算法接口版本号: {version!r}",
            "ensure_api_compatible",
        ) from exc
    if major != SUPPORTED_API_MAJOR:
        raise algorithm_error(
            NOT_INITIALIZED,
            f"算法接口主版本不受支持：期望 {SUPPORTED_API_MAJOR}.x，实际 {version}",
            "ensure_api_compatible",
        )
    return str(version)


def processing_defaults() -> dict[str, Any]:
    """返回默认滤波参数的副本。"""
    return dict(DEFAULT_PROCESSING)


def open_api() -> None:
    """预热 API 门面。

    C++ 的算法线程在启动时调一次，把「导入失败 / 建门面失败」这类问题提前
    暴露在启动阶段，而不是等第一块数据到了才在那里报错 —— 那时报错会被
    「数据处理失败」的表象盖住，排查要从线程那头开始。

    顺带做一次主版本校验：门面可用但接口版本不兼容时同样属于「不可用」，
    应当在这里就失败，而不是等到第一次建会话。
    """
    ensure_api_compatible()
    _get_api()


def _get_api() -> Any:
    """进程内单例。推迟到第一次真正要用时才 ``create_api()``，
    这样 C++ 能先调 ``configure_logging()`` 与 ``api_version()``。"""
    global _api
    if _api is None:
        _api = api.create_api()
    return _api


def _require_str(name: str, value: Any) -> str:
    return str(value)


def _parse_processing(processing: Mapping[str, Any]) -> OnlineProcessingConfig:
    """扁平 dict → ``OnlineProcessingConfig``。

    ``config_version`` 由调用方单独传：它必须严格递增，而「谁持有那个计数器」
    这件事必须只有一个答案（C++ 的算法线程），不能在这里偷偷自己维护一份。
    见 :func:`update_processing_config`。
    """
    version = int(processing["config_version"])
    return OnlineProcessingConfig(
        config_version=version,
        high_pass=ToggleFilterConfig(
            enabled=bool(processing["high_pass_enabled"]),
            low_hz=float(processing["high_pass_low_hz"]),
            order=int(processing["high_pass_order"]),
        ),
        low_pass=ToggleFilterConfig(
            enabled=bool(processing["low_pass_enabled"]),
            high_hz=float(processing["low_pass_high_hz"]),
            order=int(processing["low_pass_order"]),
        ),
        notch=ToggleFilterConfig(
            enabled=bool(processing["notch_enabled"]),
            low_hz=float(processing["notch_low_hz"]),
            high_hz=float(processing["notch_high_hz"]),
            order=int(processing["notch_order"]),
        ),
        asr_enabled=bool(processing["asr_enabled"]),
    )


def _validate_processing(processing: Mapping[str, Any], sample_rate_hz: float, operation: str) -> None:
    """把非法滤波参数挡在算法之前。

    scipy 对越界频率抛的是裸 ``ValueError``（如「Digital filter critical
    frequencies must be 0 < Wn < fs/2」），既不是 ``AlgorithmError``，也就没有
    错误码 —— 界面只能归到 INTERNAL_ERROR，没法区分「用户填错了」和「算法真的坏了」。
    这里补一道显式校验，把前者变成规范的 INVALID_ARGUMENT。

    规则来自接口文档 5.2「滤波约定」：``0 < f < sample_rate_hz / 2``，
    v1 固定四阶。
    """
    nyquist = float(sample_rate_hz) / 2.0

    def require(condition: bool, message: str) -> None:
        if not condition:
            raise algorithm_error(INVALID_ARGUMENT, message, operation)

    for key in ("high_pass_order", "low_pass_order", "notch_order"):
        require(int(processing[key]) == 4, f"{key} 必须为 4（v1 固定四阶 Butterworth）")

    high_pass_on = bool(processing["high_pass_enabled"])
    low_pass_on = bool(processing["low_pass_enabled"])
    notch_on = bool(processing["notch_enabled"])

    if high_pass_on:
        low_hz = float(processing["high_pass_low_hz"])
        require(0.0 < low_hz < nyquist,
                f"高通截止频率 {low_hz:g} Hz 超出范围 (0, {nyquist:g}) Hz")

    if low_pass_on:
        high_hz = float(processing["low_pass_high_hz"])
        require(0.0 < high_hz < nyquist,
                f"低通截止频率 {high_hz:g} Hz 超出范围 (0, {nyquist:g}) Hz")

    if high_pass_on and low_pass_on:
        require(float(processing["high_pass_low_hz"]) < float(processing["low_pass_high_hz"]),
                "高通截止频率必须低于低通截止频率，否则通带为空")

    if notch_on:
        notch_low = float(processing["notch_low_hz"])
        notch_high = float(processing["notch_high_hz"])
        require(0.0 < notch_low < notch_high < nyquist,
                f"陷波阻带 {notch_low:g}–{notch_high:g} Hz 非法，"
                f"要求 0 < 下限 < 上限 < {nyquist:g} Hz")


def _parse_reference_method(value: Any) -> ReferenceMethod:
    """字符串 → 枚举。非法值在这里就抛，别让它跑到算法深处变成难懂的错误。"""
    text = str(value)
    try:
        return ReferenceMethod(text)
    except ValueError as exc:
        raise ValueError(f"未知的重参考方式: {text!r}") from exc


def _parse_band_preset(value: Any) -> BandPreset:
    text = str(value)
    try:
        return BandPreset(text)
    except ValueError as exc:
        raise ValueError(f"未知的频段预设: {text!r}") from exc


def create_online_session(
    channel_names: Sequence[str],
    sample_rate_hz: float,
    positions: Iterable[Sequence[Any]],
    coordinate_system: str,
    rolling_window_s: float,
    reference_method: str,
    mastoid_channels: Sequence[str],
    asr_cutoff: float,
    asr_window_s: float,
    asr_overlap_ratio: float,
    asr_reference_duration_s: float,
    processing: Mapping[str, Any],
) -> int:
    """建在线会话，返回 session_id。

    ``positions`` 是 ``[(name, x, y, z), ...]``，由 C++ 的电极表拍平后传进来；
    地形图插值要求至少 3 个电极带二维坐标。
    """
    _validate_processing(processing, sample_rate_hz, "create_online_session")

    layout = ChannelLayout(
        channel_names=tuple(_require_str("channel_name", n) for n in channel_names),
        sample_rate_hz=float(sample_rate_hz),
        positions=tuple(
            ElectrodePosition(
                channel_name=_require_str("channel_name", item[0]),
                x=float(item[1]),
                y=float(item[2]),
                z=float(item[3]),
                coordinate_system=str(coordinate_system),
            )
            for item in positions
        ),
    )

    config = OnlineConfig(
        layout=layout,
        processing=_parse_processing(processing),
        reference=ReferenceConfig(
            method=_parse_reference_method(reference_method),
            mastoid_channels=tuple(str(n) for n in mastoid_channels),
        ),
        asr=AsrConfig(
            cutoff=float(asr_cutoff),
            window_s=float(asr_window_s),
            overlap_ratio=float(asr_overlap_ratio),
            reference_duration_s=float(asr_reference_duration_s),
        ),
        # 相位模型本轮不启用：模型文件与 torch 依赖都不在部署范围里。
        # 置 enabled=False 时算法侧不会去加载模型。
        phase=PhaseModelConfig(enabled=False, model_path="", target_channels=()),
        rolling_window_s=float(rolling_window_s),
        return_processed_signal=True,
    )
    session_id = int(_get_api().create_online_session(config))
    _session_sample_rate[session_id] = float(sample_rate_hz)
    return session_id


def update_processing_config(
    session_id: int,
    processing: Mapping[str, Any],
) -> dict[str, Any]:
    """应用滤波/陷波/ASR 开关，返回扁平化的 ``ConfigUpdateResult``。

    版本号由 ``processing["config_version"]`` 带入，**必须是调用方递增的**：
    这个接口的契约是「严格递增」，而失败时不得推进任何状态 —— 如果把计数器
    放在这里自增，一次参数非法的调用就会白白吃掉一个版本号，之后的重试
    会永久撞上「必须更大」。
    """
    session_id = int(session_id)
    sample_rate_hz = _session_sample_rate.get(session_id)
    if sample_rate_hz is None:
        raise algorithm_error(SESSION_NOT_FOUND,
                              f"会话 {session_id} 不存在或已经关闭",
                              "update_processing_config")
    _validate_processing(processing, sample_rate_hz, "update_processing_config")

    result = _get_api().update_processing_config(session_id, _parse_processing(processing))
    return {
        "config_version": int(result.config_version),
        "effective_sequence_id": int(result.effective_sequence_id),
        "rolling_buffer_cleared": bool(result.rolling_buffer_cleared),
        "asr_refit_required": bool(result.asr_refit_required),
        "warmup_required": bool(result.warmup_required),
    }


def set_asr_reference(
    session_id: int,
    values: Any,
    first_sequence_id: int,
    timestamps_ns: Any,
) -> None:
    """用一段原始数据建立 ASR 参考。

    ``values`` 形状 ``[C,N]``、``timestamps_ns`` 形状 ``[N]``，都是 numpy 数组；
    C++ 传进来的是它自己那份 180 秒环形缓冲里摘出来的一段。
    """
    _get_api().set_asr_reference(
        int(session_id),
        SignalBlock(
            first_sequence_id=int(first_sequence_id),
            timestamps_ns=timestamps_ns,
            values=values,
        ),
    )


# ---- 故障注入：仅用于宿主侧自检，生产路径永远不触发 ----
#
# 为什么需要它：在线会话进入 ERROR 之后只允许 reset / get_online_status / close，
# 而「进 ERROR → 界面提示 → 重置会话 → 恢复」这条恢复路径**只能靠真的把会话
# 弄坏**才能走到。算法侧对输入有完整的结构化校验（形状、通道、频率、时间范围），
# 从 C++ 侧怎么喂都喂不出 ERROR —— 这本来是好事，但代价是这条路径没法验证，
# 而它恰恰是出问题时唯一的出路。
#
# 因此在这里留一个显式开关：让 push_block 在第 N 次调用时抛一个**非** AlgorithmError
# 的异常，算法侧就会把会话置为 ERROR（这正是真实故障的表现形式）。
# 默认 -1 表示不注入；只有自检会调 set_fault_injection()。
_fault_after_blocks = -1
_fault_block_count = 0


def set_fault_injection(after_blocks: int) -> None:
    """让 push_block 在第 ``after_blocks`` 次调用时失败。传 -1 关闭。

    **仅供自检使用**，生产代码不要调用。
    """
    global _fault_after_blocks, _fault_block_count
    _fault_after_blocks = int(after_blocks)
    _fault_block_count = 0


def push_block(
    session_id: int,
    first_sequence_id: int,
    values: Any,
    timestamps_ns: Any,
) -> dict[str, Any]:
    """热路径：每秒约 30 次。

    返回扁平 dict 而不是 ``OnlineResult`` 对象：C++ 只需要几个标量加一个数组，
    逐层 ``attr()`` 取要比 dict 多一倍以上的 pybind11 调用。

    ``processed_values`` 直接返回 numpy 数组**本身**（不拷贝）。C++ 必须在
    取 GIL 的那个作用域内把它 memcpy 出来 —— 数组一旦出了作用域，引用计数
    归零，指针就悬空了。
    """
    global _fault_block_count
    if _fault_after_blocks >= 0:
        _fault_block_count += 1
        if _fault_block_count > _fault_after_blocks:
            raise RuntimeError("故障注入：模拟算法内部异常（仅自检使用）")

    result = _get_api().push_block(
        int(session_id),
        SignalBlock(
            first_sequence_id=int(first_sequence_id),
            timestamps_ns=timestamps_ns,
            values=values,
        ),
    )
    processed = result.processed_signal
    return {
        "config_version": int(result.config_version),
        "first_sequence_id": int(result.first_sequence_id),
        "last_sequence_id": int(result.last_sequence_id),
        "processing_time_us": int(result.processing_time_us),
        "quality_flags": [flag.value for flag in result.quality_flags],
        "has_processed_signal": processed is not None,
        "processed_values": processed.values if processed is not None else None,
    }


def notify_gap(
    session_id: int,
    first_missing_sequence_id: int,
    last_missing_sequence_id: int,
    start_timestamp_ns: int,
    end_timestamp_ns: int,
    reason: str,
) -> None:
    """声明一段数据缺口。"""
    _get_api().notify_gap(
        int(session_id),
        GapInfo(
            first_missing_sequence_id=int(first_missing_sequence_id),
            last_missing_sequence_id=int(last_missing_sequence_id),
            start_timestamp_ns=int(start_timestamp_ns),
            end_timestamp_ns=int(end_timestamp_ns),
            reason=str(reason),
        ),
    )


def query_topography(
    session_id: int,
    request_id: int,
    band_preset: str,
    band_low_hz: float,
    band_high_hz: float,
    window_s: float,
    grid_width: int,
    grid_height: int,
) -> dict[str, Any]:
    """查询实时脑电地形图。``grid_values`` 是 numpy ``[H,W]``，同样必须在本作用域内拷走。"""
    result = _get_api().query_online_topography(
        int(session_id),
        TopographyQuery(
            request_id=int(request_id),
            band=FrequencyBand(
                preset=_parse_band_preset(band_preset),
                low_hz=float(band_low_hz),
                high_hz=float(band_high_hz),
            ),
            window_s=float(window_s),
            grid_width=int(grid_width),
            grid_height=int(grid_height),
        ),
    )
    return {
        "request_id": int(result.request_id),
        "config_version": int(result.config_version),
        "grid_values": result.grid_values,
        "head_mask": result.head_mask,
        "electrode_values": result.electrode_values,
        "electrode_names": [str(name) for name in result.electrode_names],
    }


def _peak_psd_or_nan(value: float | None) -> float:
    """频段峰值 PSD 允许为空（频段内没有频点），统一用 NaN 表示缺值。"""
    return float(value) if value is not None else float("nan")


def query_spectrum(
    session_id: int,
    request_id: int,
    channel_name: str,
    band_preset: str,
    band_low_hz: float,
    band_high_hz: float,
    window_s: float,
) -> dict[str, Any]:
    """查询单导联实时频谱。"""
    result = _get_api().query_online_spectrum(
        int(session_id),
        SpectrumQuery(
            request_id=int(request_id),
            channel_name=str(channel_name),
            band=FrequencyBand(
                preset=_parse_band_preset(band_preset),
                low_hz=float(band_low_hz),
                high_hz=float(band_high_hz),
            ),
            window_s=float(window_s),
        ),
    )
    return {
        "request_id": int(result.request_id),
        "config_version": int(result.config_version),
        "channel_name": str(result.channel_name),
        "frequencies_hz": result.frequencies_hz,
        "psd": result.psd,
        # 五个频段的峰值 PSD，顺序固定 δ θ α β γ。频段内没有频点时接口给
        # None，这里统一转成 NaN，由 C++ 侧显示成「—」
        "delta_peak_psd": _peak_psd_or_nan(result.delta_peak_psd),
        "theta_peak_psd": _peak_psd_or_nan(result.theta_peak_psd),
        "alpha_peak_psd": _peak_psd_or_nan(result.alpha_peak_psd),
        "beta_peak_psd": _peak_psd_or_nan(result.beta_peak_psd),
        "gamma_peak_psd": _peak_psd_or_nan(result.gamma_peak_psd),
    }


def online_status(session_id: int) -> dict[str, Any]:
    """查会话状态。C++ 靠这里的 ``state`` 判断「会话是不是真的坏了」，
    而不是去维护一份「哪些错误码会让会话进 ERROR」的名单 —— 那份名单会随
    算法包版本漂移，猜错的方向都很糟。"""
    status = _get_api().get_online_status(int(session_id))
    last_error = status.last_error
    return {
        "state": status.state.value,
        "config_version": int(status.config_version),
        "last_processed_sequence_id": (
            int(status.last_processed_sequence_id)
            if status.last_processed_sequence_id is not None
            else -1
        ),
        "rolling_buffer_duration_s": float(status.rolling_buffer_duration_s),
        "gap_count": int(status.gap_count),
        "warmup_remaining_samples": int(status.warmup_remaining_samples),
        "average_processing_time_us": float(status.average_processing_time_us),
        "p99_processing_time_us": float(status.p99_processing_time_us),
        "max_processing_time_us": int(status.max_processing_time_us),
        "last_error_code": str(last_error.code) if last_error is not None else "",
        "last_error_message": str(last_error.message) if last_error is not None else "",
    }


def reset_session(session_id: int) -> None:
    """清空流式状态，保留配置与模型。会话处于 ERROR 时这是唯一的恢复入口。"""
    _get_api().reset_online_session(int(session_id))


def close_session(session_id: int) -> None:
    session_id = int(session_id)
    _get_api().close_online_session(session_id)
    _session_sample_rate.pop(session_id, None)


# ---- 离线（后处理）通路 ----
#
# 离线与在线的差别只有两点，但都会影响扁平化方式：
#
# 1. 离线是「整段一次性处理」：先 create_offline_session 送原始信号，再
#    run_preprocessing 得到 PreprocessResult，之后的查询靠 session_id +
#    preprocess_version 定位那份预处理结果。preprocess_version 必须原样带回，
#    否则算法侧会视为查询过期数据而拒绝。
# 2. 查询用绝对时间范围 AbsoluteTimeRange（纳秒）选中片段，而不是在线那种
#    「最近 N 秒」。
#
# 预处理配置有五层嵌套（high_pass/low_pass/notch/reference/asr/artifact/
# resample/quality_control），压成一个扁平 dict 后 C++ 每加一个字段不必改
# py::arg 列表 —— 与在线处理的处理方式一致（见本模块顶部说明）。


def _parse_preprocess_config(config: Mapping[str, Any]) -> PreprocessConfig:
    """扁平 dict → ``PreprocessConfig``。"""
    return PreprocessConfig(
        preprocess_version=int(config["preprocess_version"]),
        high_pass=HighPassConfig(
            enabled=bool(config["high_pass_enabled"]),
            cutoff_hz=float(config["high_pass_cutoff_hz"]),
        ),
        low_pass=LowPassConfig(
            enabled=bool(config["low_pass_enabled"]),
            cutoff_hz=float(config["low_pass_cutoff_hz"]),
        ),
        notch=NotchConfig(
            enabled=bool(config["notch_enabled"]),
            stop_low_hz=float(config["notch_stop_low_hz"]),
            stop_high_hz=float(config["notch_stop_high_hz"]),
        ),
        reference=OfflineReferenceConfig(
            enabled=bool(config["reference_enabled"]),
            method=_parse_reference_method(config["reference_method"]),
            mastoid_channels=tuple(str(name) for name in config.get("mastoid_channels", ())),
        ),
        asr=OfflineAsrConfig(
            enabled=bool(config["asr_enabled"]),
            cutoff=float(config["asr_cutoff"]),
        ),
        artifact=ArtifactDetectionConfig(
            enabled=bool(config["artifact_enabled"]),
            jump_ratio=float(config["artifact_jump_ratio"]),
            high_freq_hz=float(config["artifact_high_freq_hz"]),
            high_freq_ratio=float(config["artifact_high_freq_ratio"]),
        ),
        resample=ResampleConfig(
            enabled=bool(config["resample_enabled"]),
            target_rate_hz=float(config["resample_target_rate_hz"]),
        ),
        quality_control=QualityControlConfig(
            null_weak_enabled=bool(config["qc_null_weak_enabled"]),
            amplitude_outlier_enabled=bool(config["qc_amplitude_outlier_enabled"]),
            low_correlation_enabled=bool(config["qc_low_correlation_enabled"]),
            repair_enabled=bool(config["qc_repair_enabled"]),
            # 字段名对齐 types/offline.py 的 QualityControlConfig：
            # 幅度占比 → abnormal_ratio_threshold，弱信号幅值 → weak_std_threshold
            abnormal_ratio_threshold=float(config["qc_amplitude_ratio"]),
            correlation_threshold=float(config["qc_correlation_threshold"]),
            weak_std_threshold=float(config["qc_weak_signal_threshold_uv"]),
        ),
        return_processed_signal=bool(config["return_processed_signal"]),
    )


def _flatten_artifact_segments(segments: Iterable[Any]) -> list[dict[str, Any]]:
    return [
        {
            "channel_name": str(segment.channel_name),
            "artifact_type": str(segment.artifact_type),
            "start_sample": int(segment.start_sample),
            "end_sample": int(segment.end_sample),
            "start_timestamp_ns": int(segment.start_timestamp_ns),
            "end_timestamp_ns": int(segment.end_timestamp_ns),
        }
        for segment in segments
    ]


def _flatten_artifact_report(report: Any) -> dict[str, Any] | None:
    if report is None:
        return None
    return {
        "segments": _flatten_artifact_segments(report.segments),
        # numpy bool 掩码，C++ 必须在取 GIL 的作用域内拷走。
        "artifact_mask": report.artifact_mask,
    }


def _flatten_quality_report(report: Any) -> dict[str, Any] | None:
    if report is None:
        return None
    return {
        "repaired": bool(report.repaired),
        "segments": _flatten_artifact_segments(report.segments),
        "artifact_mask": report.artifact_mask,
    }


def create_offline_session(
    channel_names: Sequence[str],
    sample_rate_hz: float,
    positions: Iterable[Sequence[Any]],
    coordinate_system: str,
    first_sequence_id: int,
    timestamps_ns: Any,
    values: Any,
) -> int:
    """建离线会话，返回 session_id。

    ``positions`` 与在线一致：``[(name, x, y, z), ...]``，地形图插值要求至少
    3 个电极带二维坐标。
    ``values`` 形状 ``[C,N]``、``timestamps_ns`` 形状 ``[N]``，都是 numpy 数组；
    会话内部会复制保存，返回后内存即可复用。
    """
    layout = ChannelLayout(
        channel_names=tuple(_require_str("channel_name", n) for n in channel_names),
        sample_rate_hz=float(sample_rate_hz),
        positions=tuple(
            ElectrodePosition(
                channel_name=_require_str("channel_name", item[0]),
                x=float(item[1]),
                y=float(item[2]),
                z=float(item[3]),
                coordinate_system=str(coordinate_system),
            )
            for item in positions
        ),
    )
    raw_signal = SignalBlock(
        first_sequence_id=int(first_sequence_id),
        timestamps_ns=timestamps_ns,
        values=values,
    )
    return int(_get_api().create_offline_session(layout, raw_signal))


def run_preprocessing(session_id: int, config: Mapping[str, Any]) -> dict[str, Any]:
    """运行离线预处理，返回扁平化 ``PreprocessResult``。

    ``processed_values`` 直接返回 numpy 数组本身（不拷贝），C++ 必须在本作用域
    内取走；形状 ``[C,N]``、帧序与 ``processed_timestamps_ns`` 对齐。
    """
    result = _get_api().run_preprocessing(int(session_id), _parse_preprocess_config(config))
    processed = result.processed_signal
    time_range = result.actual_time_range
    return {
        "preprocess_version": int(result.preprocess_version),
        "sample_count": int(result.sample_count),
        "sample_rate_hz": float(result.layout.sample_rate_hz),
        "channel_names": [str(name) for name in result.layout.channel_names],
        "start_timestamp_ns": int(time_range.start_timestamp_ns),
        "end_timestamp_ns": int(time_range.end_timestamp_ns),
        "applied_steps": [str(step) for step in result.applied_steps],
        "warnings": [str(warning) for warning in result.warnings],
        "has_processed_signal": processed is not None,
        "processed_values": processed.values if processed is not None else None,
        "processed_timestamps_ns": processed.timestamps_ns if processed is not None else None,
        "processed_first_sequence_id": (
            int(processed.first_sequence_id) if processed is not None else -1
        ),
        "quality": _flatten_quality_report(result.quality_report),
        "artifact": _flatten_artifact_report(result.artifact_report),
    }


def query_offline_spectrum(
    session_id: int,
    request_id: int,
    preprocess_version: int,
    channel_name: str,
    start_timestamp_ns: int,
    end_timestamp_ns: int,
    frequency_range_hz: Any,
) -> dict[str, Any]:
    """查询离线单导联频谱。``frequency_range_hz`` 传 ``None`` 或 ``(low, high)``。"""
    selected_range = AbsoluteTimeRange(int(start_timestamp_ns), int(end_timestamp_ns))
    frequency_range: tuple[float, float] | None = None
    if frequency_range_hz is not None:
        frequency_range = (float(frequency_range_hz[0]), float(frequency_range_hz[1]))

    result = _get_api().query_offline_spectrum(
        int(session_id),
        OfflineSpectrumQuery(
            request_id=int(request_id),
            preprocess_version=int(preprocess_version),
            channel_name=str(channel_name),
            selected_range=selected_range,
            frequency_range_hz=frequency_range,
        ),
    )
    return {
        "request_id": int(result.request_id),
        "preprocess_version": int(result.preprocess_version),
        "channel_name": str(result.channel_name),
        "frequencies_hz": result.frequencies_hz,
        "psd": result.psd,
    }


def query_offline_topography(
    session_id: int,
    request_id: int,
    preprocess_version: int,
    start_timestamp_ns: int,
    end_timestamp_ns: int,
    grid_width: int,
    grid_height: int,
) -> dict[str, Any]:
    """查询离线地形图（一次返回全频段 + δ/θ/α/β/γ 共 6 张）。

    ``grid_values`` 形状 ``[6,H,W]``、``electrode_values`` 形状 ``[6,C]``，
    都是 numpy 数组，必须在本作用域内拷走。
    """
    result = _get_api().query_offline_topography(
        int(session_id),
        OfflineTopographyQuery(
            request_id=int(request_id),
            preprocess_version=int(preprocess_version),
            selected_range=AbsoluteTimeRange(int(start_timestamp_ns), int(end_timestamp_ns)),
            grid_width=int(grid_width),
            grid_height=int(grid_height),
        ),
    )
    return {
        "request_id": int(result.request_id),
        "preprocess_version": int(result.preprocess_version),
        "band_names": [str(name) for name in result.band_names],
        "grid_x": result.grid_x,
        "grid_y": result.grid_y,
        "grid_values": result.grid_values,
        "head_mask": result.head_mask,
        "electrode_values": result.electrode_values,
        "electrode_names": [str(name) for name in result.electrode_names],
    }


def query_offline_statistics(
    session_id: int,
    request_id: int,
    preprocess_version: int,
    start_timestamp_ns: int,
    end_timestamp_ns: int,
) -> dict[str, Any]:
    """查询离线多通道统计指标。除名称外各字段都是长度 ``C`` 的数组，
    ``correlation_matrix`` 为 ``[C,C]``、``band_energies`` 为 ``[C,5]``。"""
    result = _get_api().query_offline_statistics(
        int(session_id),
        OfflineStatisticsQuery(
            request_id=int(request_id),
            preprocess_version=int(preprocess_version),
            selected_range=AbsoluteTimeRange(int(start_timestamp_ns), int(end_timestamp_ns)),
        ),
    )
    return {
        "request_id": int(result.request_id),
        "preprocess_version": int(result.preprocess_version),
        "channel_names": [str(name) for name in result.channel_names],
        "mean": result.mean,
        "std": result.std,
        "rms": result.rms,
        "peak_to_peak": result.peak_to_peak,
        "min_value": result.min_value,
        "max_value": result.max_value,
        "zero_crossing_rate": result.zero_crossing_rate,
        "skewness": result.skewness,
        "kurtosis": result.kurtosis,
        "dominant_band": [str(name) for name in result.dominant_band],
        "correlation_matrix": result.correlation_matrix,
        "band_names": [str(name) for name in result.band_names],
        "band_energies": result.band_energies,
    }


def get_preprocessed_data(session_id: int) -> dict[str, Any]:
    """取整段预处理数据集。``values`` 形状 ``[C,N]``，必须在本作用域内拷走。"""
    dataset = _get_api().get_preprocessed_data(int(session_id))
    time_range = dataset.actual_time_range
    return {
        "preprocess_version": int(dataset.preprocess_version),
        "sample_rate_hz": float(dataset.layout.sample_rate_hz),
        "channel_names": [str(name) for name in dataset.layout.channel_names],
        "first_sequence_id": int(dataset.signal.first_sequence_id),
        "start_timestamp_ns": int(time_range.start_timestamp_ns),
        "end_timestamp_ns": int(time_range.end_timestamp_ns),
        "applied_steps": [str(step) for step in dataset.applied_steps],
        "values": dataset.signal.values,
        "timestamps_ns": dataset.signal.timestamps_ns,
    }


def offline_status(session_id: int) -> dict[str, Any]:
    """查离线会话状态。``state`` 用于判断「这份预处理结果还能不能用」。"""
    status = _get_api().get_offline_status(int(session_id))
    last_error = status.last_error
    preprocessed = status.preprocessed_time_range
    return {
        "state": status.state.value,
        "preprocess_version": (
            int(status.preprocess_version) if status.preprocess_version is not None else -1
        ),
        "raw_start_timestamp_ns": int(status.raw_time_range.start_timestamp_ns),
        "raw_end_timestamp_ns": int(status.raw_time_range.end_timestamp_ns),
        "has_preprocessed_range": preprocessed is not None,
        "preprocessed_start_timestamp_ns": (
            int(preprocessed.start_timestamp_ns) if preprocessed is not None else -1
        ),
        "preprocessed_end_timestamp_ns": (
            int(preprocessed.end_timestamp_ns) if preprocessed is not None else -1
        ),
        "raw_sample_count": int(status.raw_sample_count),
        "preprocessed_sample_count": (
            int(status.preprocessed_sample_count)
            if status.preprocessed_sample_count is not None
            else -1
        ),
        "last_error_code": str(last_error.code) if last_error is not None else "",
        "last_error_message": str(last_error.message) if last_error is not None else "",
    }


def close_offline_session(session_id: int) -> None:
    """关闭离线会话，释放原始信号与预处理结果。"""
    _get_api().close_offline_session(int(session_id))


def drain_log_events(max_items: int = 100) -> list[dict[str, Any]]:
    """拉取待转发的告警事件。C++ 每隔 200~500ms 调一次。"""
    return [
        {
            "timestamp_utc_ns": int(event.timestamp_utc_ns),
            "level": event.level.value,
            "code": str(event.code),
            "message": str(event.message),
            "operation": str(event.operation) if event.operation is not None else "",
            "session_id": int(event.session_id) if event.session_id is not None else -1,
            "sequence_id": int(event.sequence_id) if event.sequence_id is not None else -1,
            "duration_ms": float(event.duration_ms) if event.duration_ms is not None else -1.0,
        }
        for event in _get_api().drain_log_events(int(max_items))
    ]


def close_api() -> None:
    """关闭全部会话并刷新日志。调用之后本模块不可再用。"""
    global _api
    if _api is not None:
        _api.close()
        _api = None
    _session_sample_rate.clear()


def describe_error(exc: BaseException) -> dict[str, Any]:
    """把异常投影成扁平 dict。

    ``AlgorithmError`` 带结构化的 ``.info``；其余异常（包括 pybind11 传过来的
    各种转换错误）走兜底分支 —— C++ 拿到的仍然是结构化的 dict，不必去解析
    traceback 猜错误码。
    """
    info = getattr(exc, "info", None)
    if info is None:
        return {
            "code": "INTERNAL_ERROR",
            "message": str(exc),
            "operation": "",
            "session_id": -1,
            "sequence_id": -1,
        }
    return {
        "code": str(info.code),
        "message": str(info.message),
        "operation": str(info.operation),
        "session_id": int(info.session_id) if info.session_id is not None else -1,
        "sequence_id": int(info.sequence_id) if info.sequence_id is not None else -1,
    }


__all__ = [
    "PROCESSING_KEYS",
    "api_version",
    "close_api",
    "close_offline_session",
    "close_session",
    "configure_logging",
    "create_offline_session",
    "create_online_session",
    "describe_error",
    "drain_log_events",
    "ensure_api_compatible",
    "get_preprocessed_data",
    "notify_gap",
    "offline_status",
    "online_status",
    "open_api",
    "processing_defaults",
    "push_block",
    "query_offline_spectrum",
    "query_offline_statistics",
    "query_offline_topography",
    "query_spectrum",
    "query_topography",
    "reset_session",
    "run_preprocessing",
    "set_fault_injection",
    "set_asr_reference",
    "update_processing_config",
]

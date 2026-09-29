"""EEG 在线与离线算法包。

公共入口：
- ``eeg_algorithm.api``：C++ 唯一业务入口。
- ``eeg_algorithm.types``：跨语言 DTO 与枚举。
- ``eeg_algorithm.errors``：错误码与异常。

其余实现统一位于 ``eeg_algorithm.internal``，C++ 不得直接导入。
"""

from eeg_algorithm.version import API_VERSION

__all__ = ["API_VERSION"]

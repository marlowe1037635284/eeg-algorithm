"""EEG algorithm package public surface."""

from logging import NullHandler, getLogger

from .version import API_VERSION, __version__

getLogger("eeg_algorithm").addHandler(NullHandler())

__all__ = ["API_VERSION", "__version__"]


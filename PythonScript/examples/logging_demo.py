import os
import tempfile
from pathlib import Path

from eeg_algorithm.api import configure_logging, create_api
from eeg_algorithm.types import LoggingConfig

log_dir = Path(os.environ.get("EEG_ALGORITHM_LOG_DIR", Path(tempfile.gettempdir()) / "eeg_algorithm_logs"))
configure_logging(LoggingConfig(directory=str(log_dir)))
api = create_api()
print("log file:", api.get_logging_status().active_log_file)
print(api.drain_log_events())
api.close()

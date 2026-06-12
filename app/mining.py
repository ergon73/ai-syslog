"""Выделение шаблонов сообщений (Drain3): из потока повторов — уникальные кластеры."""

from drain3 import TemplateMiner
from drain3.file_persistence import FilePersistence
from drain3.template_miner_config import TemplateMinerConfig

from . import config

_config = TemplateMinerConfig()
_config.drain_sim_th = 0.5
_config.drain_depth = 4

_miner = TemplateMiner(
    FilePersistence(str(config.DRAIN_STATE_PATH)), _config
)


def add_message(message: str) -> tuple[int, str]:
    """Возвращает (cluster_id, template) для строки лога."""
    result = _miner.add_log_message(message)
    return result["cluster_id"], result["template_mined"]

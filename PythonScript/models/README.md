# Phase model assets

大型模型文件不直接提交到源码包。部署时由 C++ 使用 `PhaseModelConfig.model_path` 传入绝对路径，并根据 `manifest.json` 校验模型版本和哈希。


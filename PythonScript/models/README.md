# 相位解码模型资源

本目录用于存放实时相位解码所需的 PyTorch 模型文件，路径通过
`PhaseModelConfig.model_path` 由 C++ 传入。

- 模型文件不随 Python 源码包提交。
- `manifest.json` 记录模型的版本、目标通道与设备信息，供联调与发布核对。

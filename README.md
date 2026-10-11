# Strata Windows Vulkan vision encoder builder

在 GitHub Actions 的 Windows runner 编译 `strata-vision.exe`，本机无需安装 MSVC、CMake 或 Vulkan SDK。
这是 community build，不是 Strata 官方 release。

## 固定版本

- Strata `v0.1.41`：`fb58e0dbc8399662c0e47c76578c6e878b14f6cf`。
- llama.cpp：`3cf03257f219afbe7334045ff7c6a06ac68c627d`，与该版 Strata setup.py 一致。
- Vulkan SDK：`1.4.363.0`，使用 LunarG 官方下载并校验 SHA-256。
- Windows x64、AVX2 baseline、static MSVC runtime、static llama.cpp/ggml、Vulkan ON、CUDA/HIP OFF。

## 构建与下载

修改 main 上的构建文件会触发 Actions；也可在 Actions → Windows Vulkan vision encoder → Run workflow 手动运行。
运行成功后下载 artifact `strata-vision-windows-x64-vulkan-v0.1.41`，里面包含可分发 ZIP 和 ZIP SHA-256。
另外保存 14 天的 diagnostics；成品 artifact 保存 30 天。这里不自动创建 Release。

`build.ps1` 只允许在 GitHub Actions 运行。它在云端安装 SDK，不要在自己的电脑运行。
构建只下载源码和工具链，不下载或上传任何模型、Token 或本机配置。

## 使用条件与验证范围

本机需 Windows 10/11 x64、支持 AVX2 的 CPU 和可用的 Vulkan graphics driver。
还需匹配模型的 mmproj GGUF 以及文本模型的第一个 GGUF shard；此仓库不包含权重。
Vulkan loader 使用现有显卡 driver 提供的 `vulkan-1.dll`，构建包不覆盖系统 driver。

云端检查 source pin、CMake flags、PE x64 和 DLL imports，并验证无参数启动输出 usage（退出码 2）。
Windows runner 上没有本机 RX 7900 XTX，因此这些检查不代表图片识别、显存占用或 GPU 性能已验证。
先在独立目录测试 encoder，再接入现有 Strata；升级 encoder 前保留现有配置和成品。

源码许可随成品附带：[Strata](https://github.com/Niko1221/Strata)、[llama.cpp](https://github.com/ggml-org/llama.cpp)。

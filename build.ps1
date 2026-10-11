# Run ONLY on the GitHub Actions Windows runner. This script installs an SDK there.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Cloud build only: run this script through GitHub Actions.' }

$root = $PSScriptRoot
$source = Join-Path $root 'source/strata'
$llama = Join-Path $root 'source/llama.cpp'
$build = Join-Path $root 'build-vision'
$package = Join-Path $root 'package'
$output = Join-Path $root 'output'
$diagnostics = Join-Path $root 'diagnostics'
New-Item -ItemType Directory -Force -Path $package, $output, $diagnostics | Out-Null

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments, [string]$Log)
    & $Program @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $diagnostics $Log)
    if ($LASTEXITCODE -ne 0) { throw "$Program failed, exit code $LASTEXITCODE" }
}

# Verify the source pin agrees with the Strata setup script.
$setup = Get-Content (Join-Path $source 'setup.py') -Raw
if ($setup -notmatch ('LLAMA_CPP_COMMIT = "' + [regex]::Escape($env:LLAMA_COMMIT) + '"')) {
    throw 'llama.cpp pin differs from Strata setup.py'
}
foreach ($entry in @(@($source, $env:STRATA_COMMIT), @($llama, $env:LLAMA_COMMIT))) {
    $head = (& git -C $entry[0] rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne $entry[1]) { throw "Unexpected source revision: $head" }
}

# Download only on the runner, verify the official SDK hash, then install silently.
$installer = Join-Path $env:RUNNER_TEMP 'vulkan-sdk.exe'
$sdk = Join-Path $env:RUNNER_TEMP ('VulkanSDK/' + $env:VULKAN_VERSION)
$url = 'https://sdk.lunarg.com/sdk/download/' + $env:VULKAN_VERSION + '/windows/vulkan_sdk.exe'
& curl.exe --fail --location --retry 4 --retry-delay 5 --output $installer $url
if ($LASTEXITCODE -ne 0) { throw 'Vulkan SDK download failed' }
$sdkHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sdkHash -ne $env:VULKAN_INSTALLER_SHA256) { throw 'Vulkan SDK SHA-256 mismatch' }
$installation = Start-Process -FilePath $installer -ArgumentList @('--root', $sdk, '--accept-licenses', '--default-answer', '--confirm-command', 'install') -WindowStyle Hidden -Wait -PassThru
if ($installation.ExitCode -ne 0) { throw "Vulkan SDK installation failed: $($installation.ExitCode)" }
$env:VULKAN_SDK = $sdk
$env:PATH = (Join-Path $sdk 'Bin') + ';' + $env:PATH
if (-not (Test-Path (Join-Path $sdk 'Bin/glslc.exe'))) { throw 'Missing glslc.exe' }

$configureArgs = @('-S', (Join-Path $source 'tools/vision'), '-B', $build,
    '-G', 'Visual Studio 17 2022', '-A', 'x64',
    "-DLLAMA_DIR=$llama", "-DCMAKE_PREFIX_PATH=$sdk",
    '-DSTRATA_PORTABLE=ON', '-DSTRATA_VISION_CUDA=OFF', '-DGGML_VULKAN=ON',
    '-DGGML_HIP=OFF', '-DGGML_SYCL=OFF', '-DGGML_NATIVE=OFF',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded')
Invoke-Checked 'cmake' $configureArgs 'configure.log'
Copy-Item (Join-Path $build 'CMakeCache.txt') (Join-Path $diagnostics 'CMakeCache.txt')
$cache = Get-Content (Join-Path $build 'CMakeCache.txt') -Raw
foreach ($flag in @('STRATA_PORTABLE', 'GGML_VULKAN')) {
    if ($cache -notmatch "(?m)^${flag}:BOOL=ON\r?$") { throw "Expected $flag=ON" }
}
foreach ($flag in @('STRATA_VISION_CUDA', 'GGML_CUDA', 'GGML_HIP', 'GGML_NATIVE', 'GGML_OPENMP', 'BUILD_SHARED_LIBS', 'GGML_BACKEND_DL', 'GGML_AVX512')) {
    if ($cache -notmatch "(?m)^${flag}:BOOL=OFF\r?$") { throw "Expected $flag=OFF" }
}
Invoke-Checked 'cmake' @('--build', $build, '--config', 'Release', '--target', 'strata-vision', '--parallel', '4') 'build.log'
$exe = Join-Path $build 'bin/Release/strata-vision.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Encoder output not found' }
Copy-Item -LiteralPath $exe -Destination (Join-Path $package 'strata-vision.exe')

# Static CRT and static ggml/llama: reject unexpected DLL dependencies.
# Vulkan's loader comes from the user's existing graphics driver; do not replace it.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vs) { throw 'Visual Studio build tools not found on runner' }
$msvc = Get-ChildItem (Join-Path $vs 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$dumpbin = Join-Path $msvc.FullName 'bin/Hostx64/x64/dumpbin.exe'
$dump = & $dumpbin /dependents (Join-Path $package 'strata-vision.exe') 2>&1
if ($LASTEXITCODE -ne 0) { throw 'dumpbin dependency check failed' }
$dump | Set-Content (Join-Path $diagnostics 'dependencies.txt') -Encoding utf8
$dependencies = @($dump | ForEach-Object { if ($_ -match '^\s+([\w.-]+\.dll)\s*$') { $Matches[1] } } | Sort-Object -Unique)
if ($dependencies.Count -eq 0 -or 'vulkan-1.dll' -notin $dependencies) { throw 'Vulkan DLL import not found' }
$systemDlls = @('KERNEL32.dll', 'USER32.dll', 'ADVAPI32.dll', 'SHELL32.dll', 'OLE32.dll', 'OLEAUT32.dll', 'WS2_32.dll', 'GDI32.dll', 'COMDLG32.dll', 'SHLWAPI.dll', 'CRYPT32.dll', 'BCRYPT.dll', 'NTDLL.dll', 'RPCRT4.dll', 'VERSION.dll', 'WINMM.dll', 'vulkan-1.dll')
foreach ($dll in $dependencies) {
    if ($dll -notin $systemDlls -and $dll -notmatch '^(api-ms-win-|ext-ms-win-)') { throw "Unexpected runtime DLL: $dll" }
}
$headers = & $dumpbin /headers (Join-Path $package 'strata-vision.exe') 2>&1
if ($LASTEXITCODE -ne 0 -or ($headers -join "`n") -notmatch '8664 machine \(x64\)') { throw 'Expected x64 executable' }
$headers | Set-Content (Join-Path $diagnostics 'pe-headers.txt') -Encoding utf8

# Missing arguments must print usage and exit 2. This checks PE loading, not GPU inference.
$savedPath = $env:PATH
try {
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    $usage = & (Join-Path $package 'strata-vision.exe') 2>&1
    $code = $LASTEXITCODE
} finally { $env:PATH = $savedPath }
$usage | Set-Content (Join-Path $diagnostics 'startup-smoke.txt') -Encoding utf8
if ($code -ne 2 -or ($usage -join "`n") -notmatch 'usage: strata-vision') { throw "Encoder startup smoke failed: $code" }

Copy-Item (Join-Path $source 'LICENSE') (Join-Path $package 'Strata-LICENSE.txt')
Copy-Item (Join-Path $llama 'LICENSE') (Join-Path $package 'llama.cpp-LICENSE.txt')
$info = [ordered]@{
    source = 'community-github-actions'; backend = 'vulkan'; platform = 'windows-x64'; strata_version = '0.1.41'
    strata_commit = $env:STRATA_COMMIT; llama_commit = $env:LLAMA_COMMIT
    vulkan_sdk = $env:VULKAN_VERSION; vulkan_sdk_installer_sha256 = $sdkHash
    portable = $true; cpu_baseline = 'AVX2'; msvc_runtime = 'static'; dependencies = $dependencies
    built_at_utc = [DateTime]::UtcNow.ToString('o'); workflow_run = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    validation = @{ source_pins = 'passed'; cmake_flags = 'passed'; pe_dependencies = 'passed'; startup_usage = 'passed'; gpu_image_encoding = 'not-tested' }
    cmake = (& cmake --version | Select-Object -First 1); msvc_tools = $msvc.Name
}
$info | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $package 'BUILD.json') -Encoding utf8
@'
Strata v0.1.41 Windows x64 Vulkan vision encoder (community build).
CPU baseline: AVX2. Static MSVC CRT, llama.cpp and ggml libraries.
Requires Windows 10/11 x64 and a working Vulkan graphics driver.
No local compiler or Vulkan SDK is needed. No graphics driver is included.
Needs a matching mmproj GGUF plus the first text-model GGUF shard.
This encoder opens the text GGUF vocab-only; model weights are not shipped here.
Typical arguments: --mmproj <mmproj.gguf> --model <first-shard.gguf> --gpu
Run without arguments for usage (exit code 2, by design).
Cloud checks: source pins, compiler flags, x64 imports, startup usage.
GPU image encoding and recognition quality have NOT been tested on the cloud runner.
Keep your existing Strata server/config/model separate until local validation succeeds.
'@ | Set-Content (Join-Path $package 'README.txt') -Encoding utf8
Copy-Item (Join-Path $diagnostics 'dependencies.txt') (Join-Path $package 'DEPENDENCIES.txt')
$checksumLines = Get-ChildItem $package -File | Sort-Object Name | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
}
$checksumLines | Set-Content (Join-Path $package 'SHA256SUMS.txt') -Encoding ascii
$zip = Join-Path $output 'strata-vision-windows-x64-vulkan-v0.1.41.zip'
Compress-Archive -Path (Join-Path $package '*') -DestinationPath $zip -CompressionLevel Optimal
((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + (Split-Path $zip -Leaf)) | Set-Content ($zip + '.sha256') -Encoding ascii
@"
### Portable Vulkan encoder built
- Strata: $env:STRATA_COMMIT
- llama.cpp: $env:LLAMA_COMMIT
- CPU: AVX2; MSVC runtime: static
- Download the encoder artifact below (contains ZIP + SHA-256).
- Build/startup checks passed. GPU image encoding still needs a local test.
"@ | Add-Content $env:GITHUB_STEP_SUMMARY

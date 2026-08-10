# RustDesk-Herbin CLI 使用指南

本指南说明 macOS 控制端的 RDH headless terminal 与 native file-transfer
命令。`rdh` 是可选的 shell 包装器；它必须把参数原样转发给当前安装的
`RustDesk-Herbin` 可执行文件。

## 使用前检查

先确认实际运行的版本和能力：

```bash
rdh --version
rdh --capabilities
```

支持本文全部命令的构建应输出类似：

```text
RustDesk-Herbin 1.4.9-rdh.20
```

以及：

```text
headless-terminal
headless-file-transfer
```

RDH revision 是构建标识，不改变与 RDO peer 协商使用的 upstream
应用版本。如果 `--version` 只输出 upstream 版本，或者
`--capabilities` 打开 GUI、无响应或不包含所需能力，当前安装的是旧构建；
不要继续尝试缺失的 headless 命令。

不依赖 `rdh` 包装器时，可直接执行：

```bash
/Applications/RustDesk-Herbin.app/Contents/MacOS/RustDesk-Herbin --version
```

候选 App 必须通过它自己的绝对路径运行。不要因为候选产物存在，就假定
`rdh` 已经指向该候选或当前安装已经更新。

## 内置帮助

```bash
rdh --help
rdh --help terminal
rdh --help file-transfer
```

这些命令以及 `--version`、`--capabilities` 都在 AppKit/Flutter 启动前
处理。未知 help topic 或不受支持的 headless 组合只向 stderr 输出诊断，
返回状态 2，不打开 GUI。

## Headless terminal

```bash
rdh --terminal --headless <peer-id>
```

可选参数：

- `--relay`：强制使用 relay transport。
- `--persistent`：本地分离后保留远端 terminal service，以便稍后复用。

peer ID 必须去掉 UI 为阅读而添加的分组空格。例如 UI 显示
`123 456 789` 时，CLI 参数应写成 `123456789`。

terminal 要求 stdin 和 stdout 都是交互式 TTY。`Ctrl+]` 用于本地分离；
未使用 `--persistent` 时也会关闭远端 terminal，使用后则只关闭本地连接。
远端执行 `exit` 始终关闭该 terminal。

远端 terminal 字节只写 stdout；本地提示、连接诊断和错误只写 stderr。
普通的 `--terminal <peer-id>` 不属于 headless CLI，仍保留 RDO Flutter
窗口行为。

## Headless file transfer

### Push

```bash
rdh --file-transfer --headless [--relay] [--overwrite] \
  <peer-id> push <local-file> <remote-file>
```

示例：

```bash
rdh --file-transfer --headless 123456789 push \
  "/local/path/package.zip" 'C:\Users\user\Downloads\package.zip'
```

### Pull

```bash
rdh --file-transfer --headless [--relay] [--overwrite] \
  <peer-id> pull <remote-file> <local-file>
```

示例：

```bash
rdh --file-transfer --headless 123456789 pull \
  'C:\Users\user\Downloads\result.zip' "/local/path/result.zip"
```

`--relay` 和 `--overwrite` 必须放在 peer ID 前。一次调用只传输一个普通
文件，不支持目录、symlink、通配符、resume、retry 或 reconnect。

默认不覆盖目标；目标已存在时返回状态 7。显式添加 `--overwrite` 后，
传输从 offset block 0 重新开始，不续传旧内容。

成功时 stdout 只包含目标路径和换行。进度、提示和诊断只写 stderr。
native completion 是命令成功条件；正式验收仍应在两端独立计算 SHA-256，
确认字节完全一致。

## 凭据与安全

两个 headless 命令都使用现有的 saved peer credential。只有实际需要
password 或 2FA 时才会安全提示；password 输入关闭回显。

不要使用 `--password`，也不要把明文凭据放入 argv、环境变量、日志或
脚本。CLI 会拒绝 `--password`。

## 退出状态

共同的主要状态：

- `0`：成功或正常结束。
- `2`：命令格式或参数错误。
- `3`：本地 TTY、文件或路径前置条件失败。
- `4`：认证取消或失败。
- `5`：连接、transport 或 protocol 失败。
- `130`：`Ctrl+C` / SIGINT。

file transfer 还使用：

- `6`：transfer job、远端文件、权限或文件系统失败。
- `7`：目标已存在且没有 `--overwrite`。
- `143`：SIGTERM。

terminal 可以原样返回 `1` 到 `125` 范围内的远端退出状态。

## Agent / 自动化操作清单

每次连接或传输都按以下顺序执行：

1. 解析 `rdh` 实际指向的二进制；候选版使用明确的绝对路径。
2. 运行 `--version` 和 `--capabilities`，确认 revision 与所需能力。
3. 去掉 peer ID 的显示分组空格，不记录 saved credential。
4. 用相应的 `--help` 子命令做无网络、无远端副作用的参数预检。
5. 执行 terminal 或一次文件传输。
6. 文件传输后独立核对两端路径、大小和 SHA-256。
7. 只把当前实际验证过的层级报告为成功；候选可用不等于已经安装。

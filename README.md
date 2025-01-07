# ziget

Zig-Get - downloads and installs the latest version of zig master and zls master.

## Installation

Paradoxically, requires an existing version of `zig` which can be downloaded from <https://ziglang.org/download/>

Then, in repo directory:
```bash
zig build -Doptimize=ReleaseSafe              #  installs to ./zig-out/bin/ziget
# or
zig build -Doptimize=ReleaseSafe  -p ~/.local #  installs to ~/.local/bin/ziget
```


## Usage

To simply install the native version of zig to your `~/.local/lib/zig` and `~/.local/bin/zig` directories, just call  
`ziget` 

By default, Ziget will download the zig distribution it was compiled on, to set the distribution to download, set the environment variable `ZIGET_DISTRIBUTION`

```bash
ZIGET_DISTRIBUTION=x86_64-linux ziget
```

By default, Ziget will install into the `~/.local` prefix. To set a custom prefix set the `ZIGET_ROOT_DIR` environment variable.  
Note that this is not the directory that the `zig` bin is installed to, it is the directory that contains the `bin` folder that `zig` is installed to.

```bash
ZIGET_ROOT_DIR=/ ziget
```

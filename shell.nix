with import <nixpkgs> {};
let
  unstable = import
    (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/3b5257d01b155496e77aeec29a4a538b0b41513d.tar.gz")
    # reuse the current configuration
    { config = config; };
in

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    unstable.zls
    unstable.zig_0_12
    gdb
    zlib
    valgrind
    # For linter script on push hook
    python3
    nodePackages.typescript-language-server
    vscode-langservers-extracted
    nodePackages.prettier
  ];
}

